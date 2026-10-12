import CoreGraphics
import Foundation
import ImageIO

/// A rectangle in normalized Web Mercator space: x and y run 0…1 across the world, y downward.
public struct WorldRect: Equatable, Hashable, Sendable {
    public var minX, minY, width, height: Double

    public init(minX: Double, minY: Double, width: Double, height: Double) {
        self.minX = minX; self.minY = minY; self.width = width; self.height = height
    }

    public static func point(_ c: Coordinate) -> (x: Double, y: Double) {
        let lat = max(min(c.latitude, 85.05112878), -85.05112878) * .pi / 180
        let x = (c.longitude + 180) / 360
        let y = (1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2
        return (x, y)
    }

    public static func latitude(y: Double) -> Double {
        atan(sinh(.pi * (1 - 2 * y))) * 180 / .pi
    }

    /// Square area whose half-width is `halfWidthMeters` at the center's latitude.
    public static func around(_ c: Coordinate, halfWidthMeters: Double) -> WorldRect {
        let p = point(c)
        let worldMeters = 2 * Double.pi * 6_378_137 * cos(c.latitude * .pi / 180)
        let half = halfWidthMeters / worldMeters
        return WorldRect(minX: p.x - half, minY: p.y - half, width: half * 2, height: half * 2)
    }
}

/// One 256×256 elevation tile in meters.
public struct ElevationTile: Sendable {
    public static let size = 256
    public let elevations: [Float]

    public init(elevations: [Float]) { self.elevations = elevations }

    /// Decodes a Mapzen "terrarium" PNG: meters = R·256 + G + B/256 − 32768.
    public static func decodeTerrarium(_ data: Data) -> ElevationTile? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              img.width == size, img.height == size else { return nil }
        var px = [UInt8](repeating: 0, count: size * size * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard ok else { return nil }
        var e = [Float](repeating: 0, count: size * size)
        for i in 0..<(size * size) {
            let r = Float(px[i * 4]), g = Float(px[i * 4 + 1]), b = Float(px[i * 4 + 2])
            e[i] = r * 256 + g + b / 256 - 32768
        }
        return ElevationTile(elevations: e)
    }
}

public struct TileKey: Hashable, Sendable {
    public var z, x, y: Int
    public init(z: Int, x: Int, y: Int) { self.z = z; self.x = x; self.y = y }
}

/// Fetches AWS Terrain Tiles (public dataset, no key) with a memory and disk cache.
public actor TerrainTileSource {
    private let session: URLSession
    private let base: String
    private let cacheDir: URL?
    private var memory: [TileKey: ElevationTile] = [:]
    private var order: [TileKey] = []
    private var inFlight: [TileKey: Task<ElevationTile?, Never>] = [:]

    public init(session: URLSession = .shared,
                base: String = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium",
                cacheDir: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                    .appendingPathComponent("HeadsUp/terrain", isDirectory: true)) {
        self.session = session
        self.base = base
        self.cacheDir = cacheDir
    }

    public func tile(_ k: TileKey) async -> ElevationTile? {
        if let t = memory[k] { return t }
        if let t = inFlight[k] { return await t.value }
        let task = Task { await self.load(k) }
        inFlight[k] = task
        let t = await task.value
        inFlight[k] = nil
        if let t { remember(k, t) }
        return t
    }

    private func remember(_ k: TileKey, _ t: ElevationTile) {
        memory[k] = t
        order.append(k)
        if order.count > 96 { memory[order.removeFirst()] = nil }
    }

    private func load(_ k: TileKey) async -> ElevationTile? {
        let file = cacheDir?.appendingPathComponent("\(k.z)/\(k.x)/\(k.y).png")
        if let file, let data = try? Data(contentsOf: file), let t = ElevationTile.decodeTerrarium(data) { return t }
        guard let url = URL(string: "\(base)/\(k.z)/\(k.x)/\(k.y).png") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let t = ElevationTile.decodeTerrarium(data) else { return nil }
        if let file {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file)
        }
        return t
    }
}

/// Renders real elevation data as layered "paper-cut" contour terraces.
public enum TerrainRenderer {
    public struct RGBA: Sendable { public var r, g, b, a: Double
        public init(_ hex: UInt32, _ a: Double = 1) {
            r = Double((hex >> 16) & 0xFF) / 255; g = Double((hex >> 8) & 0xFF) / 255; b = Double(hex & 0xFF) / 255; self.a = a
        }
    }

    public struct Style: Sendable {
        public var paperLow: RGBA, paperHigh: RGBA
        public var water: RGBA, shore: RGBA
        public var majorLine: RGBA, minorLine: RGBA
        public var shadow: RGBA, highlight: RGBA
        public var grid: RGBA
        public var river: RGBA = RGBA(0x5B97BD)

        public static let light = Style(
            paperLow: RGBA(0xF0ECE3), paperHigh: RGBA(0xFFFFFF),
            water: RGBA(0xC4DCE7), shore: RGBA(0x5E97B8, 0.85),
            majorLine: RGBA(0x8A6B4F, 0.7), minorLine: RGBA(0xA88B6E, 0.32),
            shadow: RGBA(0x3A2A18, 0.5), highlight: RGBA(0xFFFFFF, 0.55),
            grid: RGBA(0xAFC0D6, 0.35))

        public static let dark = Style(
            paperLow: RGBA(0x1A222B), paperHigh: RGBA(0x3A4654),
            water: RGBA(0x0E2536), shore: RGBA(0x5B93B8, 0.8),
            majorLine: RGBA(0xE8DCC8, 0.42), minorLine: RGBA(0xE8DCC8, 0.14),
            shadow: RGBA(0x000000, 0.62), highlight: RGBA(0xFFFFFF, 0.08),
            grid: RGBA(0x8FA6C0, 0.12), river: RGBA(0x4C88AE))
    }

    /// Tile zoom whose resolution roughly matches the output.
    public static func zoom(for rect: WorldRect, pixels: Int) -> Int {
        let want = Double(min(pixels, 1024)) * 0.6
        for z in 3...12 where rect.width * 256 * pow(2, Double(z)) >= want { return z }
        return 12
    }

    public static func tiles(for rect: WorldRect, zoom z: Int) -> [TileKey] {
        let n = Int(pow(2, Double(z)))
        let x0 = Int(floor(rect.minX * Double(n))), x1 = Int(floor((rect.minX + rect.width) * Double(n)))
        let y0 = max(0, Int(floor(rect.minY * Double(n)))), y1 = min(n - 1, Int(floor((rect.minY + rect.height) * Double(n))))
        var out: [TileKey] = []
        for y in y0...max(y0, y1) { for x in x0...max(x0, x1) { out.append(TileKey(z: z, x: ((x % n) + n) % n, y: y)) } }
        return out
    }

    /// Samples an elevation grid of `n`×`n` covering `rect`. NaN where no tile is available.
    public static func sample(rect: WorldRect, n: Int, zoom z: Int, tiles: [TileKey: ElevationTile]) -> [Float] {
        let world = pow(2, Double(z)) * Double(ElevationTile.size)
        let size = ElevationTile.size
        let tilesPerSide = Int(pow(2, Double(z)))
        var out = [Float](repeating: .nan, count: n * n)
        for j in 0..<n {
            let py = (rect.minY + (Double(j) + 0.5) / Double(n) * rect.height) * world - 0.5
            for i in 0..<n {
                let px = (rect.minX + (Double(i) + 0.5) / Double(n) * rect.width) * world - 0.5
                func at(_ gx: Int, _ gy: Int) -> Float {
                    let tx = Int(floor(Double(gx) / Double(size))), ty = Int(floor(Double(gy) / Double(size)))
                    guard ty >= 0, ty < tilesPerSide,
                          let t = tiles[TileKey(z: z, x: ((tx % tilesPerSide) + tilesPerSide) % tilesPerSide, y: ty)] else { return .nan }
                    let lx = gx - tx * size, ly = gy - ty * size
                    return t.elevations[ly * size + lx]
                }
                let x0 = Int(floor(px)), y0 = Int(floor(py))
                let fx = Float(px - Double(x0)), fy = Float(py - Double(y0))
                let a = at(x0, y0), b = at(x0 + 1, y0), c = at(x0, y0 + 1), d = at(x0 + 1, y0 + 1)
                out[j * n + i] = (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
            }
        }
        return out
    }

    /// Picks a contour step giving roughly 6–14 terraces across the land relief in view.
    public static func contourStep(min lo: Float, max hi: Float) -> Double {
        let range = Double(max(hi - lo, 0))
        // Never finer than 5 m: below that, DEM noise and buildings turn flat land into speckle.
        let steps: [Double] = [5, 10, 20, 25, 50, 100, 200, 250, 500, 1000]
        return steps.first { range / $0 <= 9 } ?? 1000
    }

    /// Renders an RGBA image of `n`×`n` pixels. `pixelScale` is pixels per point (for line widths).
    public static func render(elevation input: [Float], n: Int, pixelScale: Double, rect: WorldRect, style: Style,
                              water: WaterFeatures? = nil) -> CGImage? {
        guard input.count == n * n, n > 4 else { return nil }
        var e = input
        // Two box-blur passes soften DEM noise so the contours read as clean paper edges.
        let radius = max(2, Int((Double(n) / 180).rounded()))
        for _ in 0..<3 { boxBlur(&e, n: n, r: radius) }

        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        for v in e where v.isFinite && v > 0.5 { lo = min(lo, v); hi = max(hi, v) }
        if lo > hi { lo = 0; hi = 0 }
        if hi - lo < 60 {
            // Plains: the little relief there is is mostly noise and buildings, so smooth harder.
            for _ in 0..<3 { boxBlur(&e, n: n, r: radius * 2) }
        }
        let major = contourStep(min: lo, max: hi)
        let minor = major / (major == 25 || major == 250 || major == 5 || major == 50 || major == 500 ? 5 : 4)

        // Terrace level per pixel; water is -1, missing data -2.
        var level = [Int32](repeating: -2, count: n * n)
        var minorLevel = [Int32](repeating: 0, count: n * n)
        var maxLevel: Int32 = 0, minLevel: Int32 = .max
        for i in 0..<(n * n) {
            let v = e[i]
            guard v.isFinite else { continue }
            if v <= 0 { level[i] = -1; continue }
            let l = Int32(floor(Double(v) / major))
            level[i] = l
            minorLevel[i] = Int32(floor(Double(v) / minor))
            maxLevel = max(maxLevel, l); minLevel = min(minLevel, l)
        }
        if minLevel == .max { minLevel = 0 }

        var buf = [UInt8](repeating: 0, count: n * n * 4)
        let shadowReach = max(3, Int((6 * pixelScale).rounded()))
        let line = max(1, Int(pixelScale.rounded() / 2))

        @inline(__always) func lv(_ x: Int, _ y: Int) -> Int32 {
            let cx = min(max(x, 0), n - 1), cy = min(max(y, 0), n - 1)
            return level[cy * n + cx]
        }

        // Graticule lines at a "nice" step for the area shown.
        let lonSpan = rect.width * 360
        let gridStep = [0.01, 0.02, 0.05, 0.1, 0.2, 0.25, 0.5, 1, 2, 5].first { lonSpan / $0 <= 7 } ?? 10
        var gridCol = [Bool](repeating: false, count: n), gridRow = [Bool](repeating: false, count: n)
        for i in 0..<(n - 1) {
            let a = (rect.minX + Double(i) / Double(n) * rect.width) * 360 - 180
            let b = (rect.minX + Double(i + 1) / Double(n) * rect.width) * 360 - 180
            gridCol[i] = floor(a / gridStep) != floor(b / gridStep)
            let la = WorldRect.latitude(y: rect.minY + Double(i) / Double(n) * rect.height)
            let lb = WorldRect.latitude(y: rect.minY + Double(i + 1) / Double(n) * rect.height)
            gridRow[i] = floor(la / gridStep) != floor(lb / gridStep)
        }

        let span = Double(max(1, maxLevel - minLevel))
        for y in 0..<n {
            for x in 0..<n {
                let i = y * n + x
                let l = level[i]
                var c: RGBA
                if l == -1 {
                    c = style.water
                } else if l == -2 {
                    c = style.paperLow
                } else {
                    let t = Double(l - minLevel) / span
                    c = mix(style.paperLow, style.paperHigh, t * t * 0.4 + t * 0.6)
                }
                if gridCol[x] || gridRow[y] { c = over(c, style.grid) }

                // Minor contours inside a terrace.
                if l >= 0 {
                    let m = minorLevel[i]
                    let r = x + line < n ? minorLevel[i + line] : m
                    let d = y + line < n ? minorLevel[i + line * n] : m
                    let sameR = x + line < n ? level[i + line] == l : true
                    let sameD = y + line < n ? level[i + line * n] == l : true
                    if (r != m && sameR) || (d != m && sameD) { c = over(c, style.minorLine) }
                }

                // Cast shadow from higher terraces up and to the left.
                if l >= -1 {
                    var amount = 0.0
                    for k in 1...shadowReach {
                        let h = lv(x - k, y - k)
                        if h > l {
                            let falloff = 1 - Double(k - 1) / Double(shadowReach)
                            amount = falloff * falloff * min(1, 0.6 + 0.2 * Double(h - l))
                            break
                        }
                    }
                    if amount > 0 {
                        var sh = style.shadow
                        sh.a *= amount
                        c = over(c, sh)
                    }
                    // A thin lit rim on the upper-left edge of each terrace.
                    if l >= 0 && lv(x - line, y - line) < l && amount == 0 { c = over(c, style.highlight) }
                }

                // Terrace edges and the coastline.
                let right = lv(x + line, y), down = lv(x, y + line), left = lv(x - line, y), up = lv(x, y - line)
                if l >= 0 && (right < l || down < l || left < l || up < l) {
                    let edgeToWater = right == -1 || down == -1 || left == -1 || up == -1
                    c = over(c, edgeToWater ? style.shore : style.majorLine)
                }

                let o = i * 4
                buf[o] = UInt8(max(0, min(255, c.r * 255)))
                buf[o + 1] = UInt8(max(0, min(255, c.g * 255)))
                buf[o + 2] = UInt8(max(0, min(255, c.b * 255)))
                buf[o + 3] = 255
            }
        }
        if let water { drawWater(water, into: &buf, n: n, pixelScale: pixelScale, rect: rect, style: style) }
        let data = Data(buf) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Paints lakes, sea and rivers from OpenStreetMap over the relief.
    static func drawWater(_ w: WaterFeatures, into buf: inout [UInt8], n: Int, pixelScale: Double, rect: WorldRect, style: Style) {
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            // Row 0 of the buffer is the top of the map.
            ctx.translateBy(x: 0, y: CGFloat(n))
            ctx.scaleBy(x: 1, y: -1)
            func pt(_ p: WorldPoint) -> CGPoint {
                CGPoint(x: (p.x - rect.minX) / rect.width * Double(n), y: (p.y - rect.minY) / rect.height * Double(n))
            }
            func cg(_ c: RGBA) -> CGColor { CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }
            let view = CGRect(x: -20, y: -20, width: n + 40, height: n + 40)

            // Rivers, canals and streams first: where a river widens into a mapped water body,
            // the body's fill covers its centerline.
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            // Plains crossed by dense canal networks (e.g. the Yangtze delta) get finer, lighter lines.
            var length = 0.0
            for line in w.lines {
                let p = line.points.map(pt)
                for j in 1..<max(1, p.count) where j < p.count { length += hypot(p[j].x - p[j - 1].x, p[j].y - p[j - 1].y) }
            }
            let density = length / Double(n) / Double(n) * 100 / pixelScale
            let thin = density > 3 ? 0.65 : 1.0
            for kind in [WaterFeatures.LineKind.stream, .canal, .river] {
                let width: Double, alpha: Double
                switch kind {
                case .river: (width, alpha) = (1.2 * thin, thin < 1 ? 0.75 : 1)
                case .canal: (width, alpha) = (0.7 * thin, 0.6)
                case .stream: (width, alpha) = (0.55 * thin, 0.5)
                }
                var c = style.river
                c.a *= alpha
                ctx.setStrokeColor(cg(c))
                ctx.setLineWidth(width * pixelScale)
                for line in w.lines where line.kind == kind {
                    let path = CGMutablePath()
                    path.addLines(between: line.points.map(pt))
                    guard path.boundingBox.intersects(view) else { continue }
                    ctx.addPath(path)
                }
                ctx.strokePath()
            }

            // Water bodies: fill, then outline only real shores (not tile clip edges).
            ctx.setFillColor(cg(style.water))
            for area in w.areas {
                let path = CGMutablePath()
                for ring in area.rings { path.addLines(between: ring.map(pt)); path.closeSubpath() }
                guard path.boundingBox.intersects(view) else { continue }
                ctx.addPath(path)
                ctx.fillPath(using: .evenOdd)
            }
            ctx.setStrokeColor(cg(style.shore))
            ctx.setLineWidth(max(1, 0.6 * pixelScale))
            for area in w.areas {
                for (ring, clipped) in zip(area.rings, area.clipped) {
                    let pts = ring.map(pt)
                    let path = CGMutablePath()
                    for j in 0..<pts.count where !clipped[j] {
                        path.move(to: pts[j])
                        path.addLine(to: pts[(j + 1) % pts.count])
                    }
                    guard path.boundingBox.intersects(view) else { continue }
                    ctx.addPath(path)
                }
            }
            ctx.strokePath()
        }
    }

    private static func mix(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
        var c = a
        c.r = a.r + (b.r - a.r) * t; c.g = a.g + (b.g - a.g) * t; c.b = a.b + (b.b - a.b) * t; c.a = 1
        return c
    }

    private static func over(_ base: RGBA, _ top: RGBA) -> RGBA {
        var c = base
        c.r = base.r * (1 - top.a) + top.r * top.a
        c.g = base.g * (1 - top.a) + top.g * top.a
        c.b = base.b * (1 - top.a) + top.b * top.a
        return c
    }

    private static func boxBlur(_ e: inout [Float], n: Int, r: Int) {
        var tmp = e
        for y in 0..<n {
            for x in 0..<n {
                var sum: Float = 0, cnt: Float = 0
                for k in -r...r {
                    let v = e[y * n + min(max(x + k, 0), n - 1)]
                    if v.isFinite { sum += v; cnt += 1 }
                }
                tmp[y * n + x] = cnt > 0 ? sum / cnt : .nan
            }
        }
        for y in 0..<n {
            for x in 0..<n {
                var sum: Float = 0, cnt: Float = 0
                for k in -r...r {
                    let v = tmp[min(max(y + k, 0), n - 1) * n + x]
                    if v.isFinite { sum += v; cnt += 1 }
                }
                e[y * n + x] = cnt > 0 ? sum / cnt : .nan
            }
        }
    }
}

