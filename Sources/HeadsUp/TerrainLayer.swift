import HeadsUpCore
import MapKit
import SwiftUI

/// Loads elevation tiles and renders the paper-cut contour map for the current view.
@MainActor
final class TerrainModel: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var imageRect: WorldRect?
    /// True when the last render had to do without some or all tiles.
    @Published private(set) var incomplete = false
    @Published private(set) var loading = false

    private let source: TerrainTileSource
    private var task: Task<Void, Never>?
    private var key: Key?

    struct Key: Equatable {
        var center: Coordinate
        var radiusKm: Double
        var pixels: Int
        var dark: Bool
    }

    init(source: TerrainTileSource = TerrainTileSource()) { self.source = source }

    func request(center: Coordinate, radiusKm: Double, pixels: Int, dark: Bool) {
        let k = Key(center: center, radiusKm: radiusKm, pixels: min(max(pixels, 200), 1600), dark: dark)
        guard k != key else { return }
        key = k
        task?.cancel()
        loading = true
        task = Task { [source] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            if Task.isCancelled { return }
            let rect = WorldRect.around(k.center, halfWidthMeters: k.radiusKm * 1000 / Projector.ringFraction)
            let zoom = TerrainRenderer.zoom(for: rect, pixels: k.pixels)
            let keys = TerrainRenderer.tiles(for: rect, zoom: zoom)
            let tiles = await withTaskGroup(of: (TileKey, ElevationTile?).self) { group in
                for t in keys { group.addTask { (t, await source.tile(t)) } }
                var out: [TileKey: ElevationTile] = [:]
                for await (t, tile) in group { if let tile { out[t] = tile } }
                return out
            }
            if Task.isCancelled { return }
            let style: TerrainRenderer.Style = k.dark ? .dark : .light
            let n = k.pixels
            let img: CGImage? = tiles.isEmpty ? nil : await Task.detached(priority: .utility) {
                let e = TerrainRenderer.sample(rect: rect, n: n, zoom: zoom, tiles: tiles)
                return TerrainRenderer.render(elevation: e, n: n, pixelScale: 2, rect: rect, style: style)
            }.value
            if Task.isCancelled { return }
            self.loading = false
            self.incomplete = tiles.count < keys.count
            if let img {
                self.image = img
                self.imageRect = rect
            } else {
                // Leave the previous map up, but allow a retry on the next request.
                self.key = nil
            }
        }
    }

    /// Forget the current request so the next `request` re-renders (e.g. after network returns).
    func invalidate() { key = nil }
}

struct TerrainLayer: View {
    @ObservedObject var terrain: TerrainModel
    let projector: Projector

    var body: some View {
        if let img = terrain.image, let r = terrain.imageRect {
            let a = projector.point(worldX: r.minX, worldY: r.minY)
            let b = projector.point(worldX: r.minX + r.width, worldY: r.minY + r.height)
            Image(decorative: img, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: b.x - a.x, height: b.y - a.y)
                .position(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                .transition(.opacity)
        }
    }
}

extension Projector {
    /// Point for normalized Web Mercator coordinates (0…1 across the world).
    func point(worldX: Double, worldY: Double) -> CGPoint {
        let w = MKMapSize.world.width, h = MKMapSize.world.height
        return CGPoint(x: (worldX * w - rect.minX) / rect.width * side,
                       y: (worldY * h - rect.minY) / rect.height * side)
    }
}
