import Foundation
import CoreGraphics
import RealityKit
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
            result.append(entry(for: mesh, partID: part.id, pickTag: part.pickTag, layer: part.layer))
        }
        return result
    }

    /// Pure: the pick entry of a model's world-space mesh (off main).
    ///
    /// Builds a `MeshBVH` over `mesh` (the builder leaves out triangles with an out-of-range
    /// index); `nearestHit` reports `partID` and `pickTag` for it while `layer` is visible.
    /// O(n log n) in the triangle count, so call it off the main actor.
    static func entry(for mesh: TriangleMesh, partID: String, pickTag: ViewerPickTag?, layer: ViewerLayer) -> ViewerPickEntry {
        ViewerPickEntry(partID: partID, pickTag: pickTag, layer: layer, bvh: MeshBVH(mesh: mesh))
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

/// Picking and label projection on the main actor.
@MainActor extension ViewerModel {
    /// Nearest visible pickable triangle under a point of the attached view (points): the
    /// view's `ray(through:)`, then `MeshBVH.raycast` over the pickable parts and the pick
    /// meshes of models added by `loadModel`. Nil while nothing pickable is loaded (the
    /// content's entries arrive when `load` finishes) or when nothing is hit.
    func hitTest(_ point: CGPoint) -> ViewerHit? {
        let modelEntries = models.entries
        guard !pickEntries.isEmpty || !modelEntries.isEmpty else { return nil }
        let pickRay: Ray?
        if let view = arView, let viewRay = view.ray(through: point) {
            pickRay = Ray(origin: viewRay.origin, direction: viewRay.direction)
        } else {
            pickRay = ViewerOrbitMath.ray(through: point, cameraToWorld: orbitState.cameraToWorld,
                                          verticalFieldOfViewDegrees: ViewerModel.fieldOfView, viewSize: viewSize)
        }
        guard let ray = pickRay else { return nil }
        return ViewerPicking.nearestHit(ray, entries: pickEntries + modelEntries, visibleLayers: visibleLayers)
    }

    /// Screen point (view points) of a world point for SwiftUI label overlays; nil behind the
    /// camera. Refresh labels when `cameraRevision` changes.
    func project(_ world: SIMD3<Float>) -> CGPoint? {
        let pose = orbitState.cameraToWorld
        let forward = -SIMD3<Float>(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
        let eye = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        guard simd_dot(world - eye, forward) > ViewerModel.nearPlane else { return nil }
        if let view = arView {
            return view.project(world)
        }
        return ViewerOrbitMath.project(world, cameraToWorld: pose, verticalFieldOfViewDegrees: ViewerModel.fieldOfView,
                                       viewSize: viewSize)
    }
}
