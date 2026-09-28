import Foundation
import simd

/// One pickable part: its bounding volume hierarchy plus what a hit reports. `MeshBVH` is
/// immutable after init and safe to query from any thread, so entries built off the main
/// actor can be handed to it.
struct ViewerPickEntry: @unchecked Sendable {
    /// `ViewerPart.id`.
    let partID: String
    /// The part's pick tag.
    let pickTag: ViewerPickTag?
    /// The part's layer; hidden layers are not pickable.
    let layer: ViewerLayer
    /// Hierarchy over the part's triangles (same triangle order as the part).
    let bvh: MeshBVH
}

/// CPU picking with `MeshBVH` (ARCHITECTURE 7.4): no collision components, no async shape
/// generation, and the triangle index comes straight from the hierarchy. Pure, any queue.
enum ViewerPicking {
    /// Longest pick distance in meters.
    static let maxDistance: Float = 1000

    /// A hierarchy per pickable part: parts with a pick tag that are renderable. Runs in
    /// O(n log n) per part; call it off the main actor.
    static func entries(for parts: [ViewerPart]) -> [ViewerPickEntry] {
        var result: [ViewerPickEntry] = []
        for part in parts where part.pickTag != nil && ViewerRenderMesh.isRenderable(part) {
            let mesh = TriangleMesh(positions: part.positions, indices: part.indices)
            result.append(ViewerPickEntry(partID: part.id, pickTag: part.pickTag, layer: part.layer,
                                          bvh: MeshBVH(mesh: mesh)))
        }
        return result
    }

    /// Nearest hit of `ray` over the entries whose layer is visible, within `maxDistance`.
    /// The reported normal is the triangle's unit normal turned to face the ray origin (LiDAR
    /// winding is inconsistent). On equal distances the earlier entry wins.
    static func nearestHit(_ ray: Ray, entries: [ViewerPickEntry], visibleLayers: Set<ViewerLayer>,
                           maxDistance: Float = ViewerPicking.maxDistance) -> ViewerHit? {
        var best: ViewerHit?
        var bestDistance = maxDistance
        for entry in entries where visibleLayers.contains(entry.layer) {
            guard let hit = entry.bvh.raycast(ray, maxDistance: bestDistance) else { continue }
            if best != nil && !(hit.distance < bestDistance) { continue }
            var normal = hit.normal
            if simd_dot(normal, ray.direction) > 0 {
                normal = -normal
            }
            bestDistance = hit.distance
            best = ViewerHit(position: hit.point, normal: normal, partID: entry.partID,
                             triangle: hit.triangle, pickTag: entry.pickTag)
        }
        return best
    }
}
