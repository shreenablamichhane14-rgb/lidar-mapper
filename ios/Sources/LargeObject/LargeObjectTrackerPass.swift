import Foundation
import simd

// The tracker's 1 Hz pass as a pure function (docs/MODULES.md 3.39, step 3 of the flow): regrow
// the box from the current faces around the fixed seed, move the sector coverage to the new box,
// feed it the camera poses copied since the last pass and the face states inside the box, and
// decide the object message. No ARKit, no clock, no locks: the tracker runs it on its own queue
// ("mapper.largeobject") and the self-test calls it directly.

/// One camera pose copied from a frame (at most 10 a second).
struct LargeObjectPose {
    /// `ARCamera.transform`.
    var cameraToWorld: simd_float4x4
    /// Seconds this pose stands for (time since the previous pose, capped).
    var seconds: Double
    /// `ARCamera.trackingState` was `.normal`.
    var trackingNormal: Bool

    /// Camera position (the translation column).
    var position: SIMD3<Float> {
        SIMD3<Float>(cameraToWorld.columns.3.x, cameraToWorld.columns.3.y, cameraToWorld.columns.3.z)
    }
}

/// What one pass starts from (copied under the tracker's lock).
struct LargeObjectPassInput {
    /// The fixed seed.
    var seed: SIMD3<Float>
    /// Floor height found at the tap, if any.
    var seedFloorY: Float?
    /// Camera position at the tap (the front of the sectors).
    var front: SIMD3<Float>?
    /// Sector coverage so far (nil before the first box of this seed).
    var sectors: SectorCoverage?
    /// Floor height and box of the previous pass.
    var lastFloorY: Float?
    var lastBox: OrientedBox?
    /// Poses copied since the previous pass, oldest first.
    var poses: [LargeObjectPose]
    /// The latest camera transform before these poses.
    var lastCamera: simd_float4x4?
}

/// What one pass produced.
struct LargeObjectPassOutput {
    /// Updated sector coverage (nil while no box exists).
    var sectors: SectorCoverage?
    /// The box (the previous one when this pass grew none).
    var box: OrientedBox?
    /// Floor height in use.
    var floorY: Float?
    /// The object message for now.
    var decision: GuidanceKind?
    /// The latest camera transform.
    var camera: simd_float4x4?
    /// Samples near the seed, grown points and faces scored (for the log).
    var sampleCount: Int
    var grownPoints: Int
    var scoredFaces: Int
    /// True when this pass grew a new box.
    var grewBox: Bool
}

/// The pure 1 Hz pass.
enum LargeObjectPass {
    /// One pass over the live faces (see the file comment). Samples, floor, growth and box come
    /// from `LargeObjectSeed`; when the growth finds nothing the previous box stays.
    static func run(_ input: LargeObjectPassInput, anchors: [CoverageAnchorFaces]) -> LargeObjectPassOutput {
        let samples = LargeObjectSeed.samples(from: anchors, near: input.seed)
        let floorY = LargeObjectSeed.floorHeight(seed: input.seed, samples: samples) ?? input.lastFloorY ?? input.seedFloorY
        var box = input.lastBox
        var grown = 0
        var grewBox = false
        if let floorY {
            let points = LargeObjectSeed.grow(seed: input.seed, samples: samples, floorY: floorY)
            grown = points.count
            if let fresh = LargeObjectSeed.box(points: points, floorY: floorY) {
                box = fresh
                grewBox = true
            }
        }
        var camera = input.lastCamera
        if let last = input.poses.last { camera = last.cameraToWorld }
        guard let currentBox = box else {
            return LargeObjectPassOutput(sectors: nil, box: nil, floorY: floorY, decision: nil, camera: camera,
                                         sampleCount: samples.count, grownPoints: grown, scoredFaces: 0, grewBox: false)
        }
        let boxFloor = floorY ?? (currentBox.center.y - currentBox.halfExtents.y)
        var sectors: SectorCoverage
        if var existing = input.sectors {
            existing.updateBox(currentBox, floorY: boxFloor)
            sectors = existing
        } else {
            let firstCamera = input.front ?? input.poses.first?.position
                ?? (currentBox.center + SIMD3<Float>(0, 0, 1))
            sectors = SectorCoverage(box: currentBox, floorY: boxFloor, firstCamera: firstCamera)
        }
        for pose in input.poses {
            sectors.observe(cameraToWorld: pose.cameraToWorld, seconds: pose.seconds, trackingNormal: pose.trackingNormal)
        }
        let faces = sectorFaces(anchors, box: currentBox)
        sectors.updateFaces(faces)
        let decision = camera.flatMap { sectors.guidance(cameraToWorld: $0) }
        return LargeObjectPassOutput(sectors: sectors, box: currentBox, floorY: floorY, decision: decision, camera: camera,
                                     sampleCount: samples.count, grownPoints: grown, scoredFaces: faces.count,
                                     grewBox: grewBox)
    }

    /// The faces of `anchors` inside `box` grown by `SectorCoverage.faceBoxGrowth`, with their live
    /// states (gray when an anchor's state list is short). Anchors whose bounds miss the box are skipped.
    static func sectorFaces(_ anchors: [CoverageAnchorFaces], box: OrientedBox) -> [SectorFace] {
        let growth = SectorCoverage.faceBoxGrowth
        let grown = OrientedBox(center: box.center, axes: box.axes,
                                halfExtents: box.halfExtents + SIMD3<Float>(repeating: growth))
        let bounds = AABB3(points: grown.corners)
        var out: [SectorFace] = []
        for anchor in anchors where overlaps(anchor, bounds) {
            let states = anchor.states
            for (index, face) in anchor.faces.enumerated() where face.area > 0 && grown.contains(face.centroid) {
                let state = index < states.count ? states[index] : CoverageState.gray
                out.append(SectorFace(centroid: face.centroid, normal: face.normal, area: face.area, state: state))
            }
        }
        return out
    }

    /// True when the anchor's world bounds overlap `bounds`.
    static func overlaps(_ anchor: CoverageAnchorFaces, _ bounds: AABB3) -> Bool {
        guard !bounds.isEmpty else { return false }
        let low = anchor.boundsMin
        let high = anchor.boundsMax
        return all(low .<= bounds.max) && all(high .>= bounds.min)
    }
}
