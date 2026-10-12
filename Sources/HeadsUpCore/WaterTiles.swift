import Foundation

/// A point in normalized Web Mercator space (0…1 across the world, y downward).
public struct WorldPoint: Equatable, Sendable {
    public var x, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Rivers, lakes and sea from OpenStreetMap (OpenMapTiles schema), for drawing on the paper map.
public struct WaterFeatures: Sendable {
    public enum LineKind: Int, Sendable { case river, canal, stream }

    public struct Area: Sendable {
        /// Rings of one feature; drawn with the even-odd rule so islands stay dry.
        public var rings: [[WorldPoint]]
        /// For each ring segment, whether it lies on a tile's clip edge (and so is not a real shore).
        public var clipped: [[Bool]]
    }

    public struct Line: Sendable {
        public var kind: LineKind
        public var points: [WorldPoint]
    }

    public var areas: [Area] = []
    public var lines: [Line] = []

    public init(areas: [Area] = [], lines: [Line] = []) { self.areas = areas; self.lines = lines }

    public mutating func append(_ other: WaterFeatures) {
        areas += other.areas
        lines += other.lines
    }
}

/// Minimal Mapbox Vector Tile decoder, reading only the `water` and `waterway` layers.
public enum VectorTileDecoder {
    struct Reader {
        let bytes: [UInt8]
        var pos: Int
        let end: Int

        init(_ bytes: [UInt8], _ start: Int = 0, _ end: Int? = nil) {
            self.bytes = bytes; pos = start; self.end = end ?? bytes.count
        }

        var atEnd: Bool { pos >= end }

        mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0, shift: UInt64 = 0
            while true {
                guard pos < end, shift < 64 else { throw DecodeError.truncated }
                let b = bytes[pos]; pos += 1
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
            }
        }

        /// Returns (field number, wire type).
        mutating func key() throws -> (Int, Int) {
            let k = try varint()
            return (Int(k >> 3), Int(k & 7))
        }

        mutating func lengthDelimited() throws -> (Int, Int) {
            let len = Int(try varint())
            guard len >= 0, pos + len <= end else { throw DecodeError.truncated }
            let start = pos
            pos += len
            return (start, pos)
        }

        mutating func skip(_ wire: Int) throws {
            switch wire {
            case 0: _ = try varint()
            case 1: pos += 8
            case 2: _ = try lengthDelimited()
            case 5: pos += 4
            default: throw DecodeError.badWireType
            }
            guard pos <= end else { throw DecodeError.truncated }
        }

        func string(_ r: (Int, Int)) -> String {
            String(decoding: bytes[r.0..<r.1], as: UTF8.self)
        }
    }

    enum DecodeError: Error { case truncated, badWireType }

    static let skippedWaterClasses: Set<String> = ["swimming_pool"]

    /// Decodes tile `z/x/y`, converting geometry to world coordinates.
    public static func decode(_ data: Data, z: Int, x: Int, y: Int) throws -> WaterFeatures {
        let bytes = [UInt8](data)
        var r = Reader(bytes)
        var out = WaterFeatures()
        while !r.atEnd {
            let (field, wire) = try r.key()
            if field == 3 && wire == 2 {
                let range = try r.lengthDelimited()
                try decodeLayer(bytes, range, z: z, x: x, y: y, into: &out)
            } else {
                try r.skip(wire)
            }
        }
        return out
    }

    private enum Value { case string(String), other }

    private static func decodeLayer(_ bytes: [UInt8], _ range: (Int, Int), z: Int, x: Int, y: Int, into out: inout WaterFeatures) throws {
        var r = Reader(bytes, range.0, range.1)
        var name = ""
        var extent = 4096.0
        var keys: [String] = []
        var values: [Value] = []
        var featureRanges: [(Int, Int)] = []
        while !r.atEnd {
            let (field, wire) = try r.key()
            switch (field, wire) {
            case (1, 2): name = r.string(try r.lengthDelimited())
            case (2, 2): featureRanges.append(try r.lengthDelimited())
            case (3, 2): keys.append(r.string(try r.lengthDelimited()))
            case (4, 2):
                let vr = try r.lengthDelimited()
                var v = Reader(bytes, vr.0, vr.1)
                var value = Value.other
                while !v.atEnd {
                    let (f, w) = try v.key()
                    if f == 1 && w == 2 { value = .string(v.string(try v.lengthDelimited())) } else { try v.skip(w) }
                }
                values.append(value)
            case (5, 0): extent = Double(try r.varint())
            default: try r.skip(wire)
            }
            // Stop early for layers we don't draw.
            if !name.isEmpty && name != "water" && name != "waterway" { return }
        }
        guard name == "water" || name == "waterway" else { return }

        let scale = pow(2.0, Double(z))
        func world(_ px: Int, _ py: Int) -> WorldPoint {
            WorldPoint(x: (Double(x) + Double(px) / extent) / scale, y: (Double(y) + Double(py) / extent) / scale)
        }

        for fr in featureRanges {
            var f = Reader(bytes, fr.0, fr.1)
            var tags: [Int] = []
            var type = 0
            var geometry: [UInt32] = []
            while !f.atEnd {
                let (field, wire) = try f.key()
                switch (field, wire) {
                case (2, 2):
                    let tr = try f.lengthDelimited()
                    var t = Reader(bytes, tr.0, tr.1)
                    while !t.atEnd { tags.append(Int(try t.varint())) }
                case (3, 0): type = Int(try f.varint())
                case (4, 2):
                    let gr = try f.lengthDelimited()
                    var g = Reader(bytes, gr.0, gr.1)
                    while !g.atEnd { geometry.append(UInt32(truncatingIfNeeded: try g.varint())) }
                default: try f.skip(wire)
                }
            }
            var props: [String: String] = [:]
            var i = 0
            while i + 1 < tags.count {
                let k = tags[i], v = tags[i + 1]
                if k < keys.count, v < values.count, case .string(let s) = values[v] { props[keys[k]] = s }
                i += 2
            }
            let parts = decodeGeometry(geometry)
            if name == "water", type == 3 {
                if let cls = props["class"], skippedWaterClasses.contains(cls) { continue }
                let e = Int(extent)
                var area = WaterFeatures.Area(rings: [], clipped: [])
                for ring in parts where ring.count >= 3 {
                    area.rings.append(ring.map { world($0.0, $0.1) })
                    var flags: [Bool] = []
                    for j in 0..<ring.count {
                        let a = ring[j], b = ring[(j + 1) % ring.count]
                        let onEdge = (a.0 <= 0 && b.0 <= 0) || (a.0 >= e && b.0 >= e) || (a.1 <= 0 && b.1 <= 0) || (a.1 >= e && b.1 >= e)
                        flags.append(onEdge)
                    }
                    area.clipped.append(flags)
                }
                if !area.rings.isEmpty { out.areas.append(area) }
            } else if name == "waterway", type == 2 {
                if props["brunnel"] == "tunnel" { continue }
                let kind: WaterFeatures.LineKind
                switch props["class"] {
                case "river": kind = .river
                case "canal": kind = .canal
                case "stream": kind = .stream
                default: continue
                }
                for line in parts where line.count >= 2 {
                    out.lines.append(.init(kind: kind, points: line.map { world($0.0, $0.1) }))
                }
            }
        }
    }

    /// Splits command-encoded geometry into parts (lines or rings) of tile coordinates.
    static func decodeGeometry(_ g: [UInt32]) -> [[(Int, Int)]] {
        var parts: [[(Int, Int)]] = []
        var current: [(Int, Int)] = []
        var cx = 0, cy = 0
        var i = 0
        func zigzag(_ v: UInt32) -> Int { Int(Int32(bitPattern: (v >> 1) ^ (0 &- (v & 1)))) }
        while i < g.count {
            let cmd = g[i] & 7, count = Int(g[i] >> 3)
            i += 1
            switch cmd {
            case 1, 2:
                for _ in 0..<count {
                    guard i + 1 < g.count else { break }
                    cx += zigzag(g[i]); cy += zigzag(g[i + 1]); i += 2
                    if cmd == 1 {
                        if !current.isEmpty { parts.append(current) }
                        current = [(cx, cy)]
                    } else {
                        current.append((cx, cy))
                    }
                }
            case 7:
                break   // ClosePath: rings are treated as closed when drawn.
            default:
                i = g.count
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}

/// Fetches OpenFreeMap vector tiles (OpenMapTiles schema, no key) with memory and disk caches.
public actor WaterTileSource {
    private let session: URLSession
    private let tileJSON: URL
    private let cacheDir: URL?
    private var template: String?
    private var memory: [TileKey: WaterFeatures] = [:]
    private var order: [TileKey] = []

    public init(session: URLSession = .shared,
                tileJSON: URL = URL(string: "https://tiles.openfreemap.org/planet")!,
                cacheDir: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                    .appendingPathComponent("HeadsUp/water", isDirectory: true)) {
        self.session = session
        self.tileJSON = tileJSON
        self.cacheDir = cacheDir
    }

    /// Zoom giving about three tiles across the view (OpenMapTiles stops at 14).
    public static func zoom(for rect: WorldRect) -> Int {
        let z = Int(floor(log2(3 / max(rect.width, 1e-9))))
        return min(max(z, 4), 14)
    }

    public func tile(_ k: TileKey) async -> WaterFeatures? {
        if let t = memory[k] { return t }
        let file = cacheDir?.appendingPathComponent("\(k.z)/\(k.x)/\(k.y).pbf")
        var data: Data?
        if let file { data = try? Data(contentsOf: file) }
        if data == nil {
            guard let url = await tileURL(k) else { return nil }
            var req = URLRequest(url: url)
            req.timeoutInterval = 15
            req.setValue("HeadsUp/1.0 (macOS desktop aircraft widget)", forHTTPHeaderField: "User-Agent")
            guard let (d, resp) = try? await session.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            data = d
            if let file {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? d.write(to: file)
            }
        }
        guard let data, let features = try? VectorTileDecoder.decode(data, z: k.z, x: k.x, y: k.y) else { return nil }
        memory[k] = features
        order.append(k)
        if order.count > 64 { memory[order.removeFirst()] = nil }
        return features
    }

    /// The tile URL template changes with each OpenFreeMap release, so read it from the TileJSON.
    private func tileURL(_ k: TileKey) async -> URL? {
        if template == nil {
            var req = URLRequest(url: tileJSON)
            req.timeoutInterval = 10
            if let (d, _) = try? await session.data(for: req),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let t = (obj["tiles"] as? [String])?.first {
                template = t
            }
        }
        guard let t = template else { return nil }
        return URL(string: t.replacingOccurrences(of: "{z}", with: "\(k.z)")
            .replacingOccurrences(of: "{x}", with: "\(k.x)")
            .replacingOccurrences(of: "{y}", with: "\(k.y)"))
    }
}
