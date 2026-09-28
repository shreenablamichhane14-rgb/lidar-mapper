import Foundation
import simd

// Synthetic geometry of the Demo Mode room (docs/MODULES.md 3.24): the room shell as a
// classified triangle mesh (what the LiDAR mesh of an empty room looks like) and a camera walk
// through it (pose samples and keyframe records) for the quality evaluation. The walk follows
// Quality's own self-test recipe: a circuit of looks from the room center alternating down and
// up, a ring of steeper looks, and one look each at the floor and the ceiling, with the phone
// held in portrait. Pure and deterministic.

/// One camera of the demo walk.
struct DemoCameraPose: Equatable, Sendable {
    /// Heading in degrees on the floor plane: 0 looks toward world +x, 90 toward world +z.
    var heading: Float
    /// Degrees above (positive) or below (negative) the horizon.
    var pitch: Float
    /// Camera position, world meters.
    var position: SIMD3<Float>
}

/// Mesh and walk builders of the demo room.
enum DemoProjectGeometry {
    /// ARMeshClassification raw values used for the shell faces.
    static let wallClass: UInt8 = 1, floorClass: UInt8 = 2, ceilingClass: UInt8 = 3
    /// The keyframe camera: a 1920 x 1440 frame with a typical wide-camera focal length.
    static let intrinsics = Intrinsics(fx: 1440, fy: 1440, cx: 960, cy: 720, width: 1920, height: 1440)
    /// Seconds between two walk poses.
    static let poseInterval: Double = 0.5

    // MARK: - Mesh

    /// The room shell (plan x in 0...width, plan y in 0...depth, floor at world y 0) as a
    /// world-space mesh cut into `cell` squares, every face wound toward the inside of the room,
    /// with face classes wall 1, floor 2 and ceiling 3.
    static func shellMesh(width: Float, depth: Float, height: Float, cell: Float) -> MeshWithAttributes {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var classes: [UInt8] = []
        let corners: [SIMD2<Float>] = [SIMD2<Float>(0, 0), SIMD2<Float>(width, 0),
                                       SIMD2<Float>(width, depth), SIMD2<Float>(0, depth)]
        let up = SIMD3<Float>(0, height, 0)
        for i in 0..<corners.count {
            let a = corners[i]
            let b = corners[(i + 1) % corners.count]
            let planDirection = simd_normalize(b - a)
            // Room on the left of a counter-clockwise loop: plan normal (-dy, dx), world (x, 0, -y).
            let inward = SIMD3<Float>(-planDirection.y, 0, -planDirection.x)
            let origin = PlanAxes.toWorld(a, y: 0)
            let along = PlanAxes.toWorld(b, y: 0) - origin
            appendRect(origin: origin, u: along, v: up, cell: cell, normal: inward, surface: wallClass,
                       positions: &positions, indices: &indices, classes: &classes)
        }
        let across = SIMD3<Float>(width, 0, 0)
        let deep = PlanAxes.toWorld(SIMD2<Float>(0, depth), y: 0)
        appendRect(origin: .zero, u: across, v: deep, cell: cell, normal: SIMD3<Float>(0, 1, 0), surface: floorClass,
                   positions: &positions, indices: &indices, classes: &classes)
        appendRect(origin: up, u: across, v: deep, cell: cell, normal: SIMD3<Float>(0, -1, 0), surface: ceilingClass,
                   positions: &positions, indices: &indices, classes: &classes)
        return MeshWithAttributes(mesh: TriangleMesh(positions: positions, indices: indices), faceClass: classes)
    }

    /// Number of cells along a side of `length` meters (at least 1).
    static func cellCount(length: Float, cell: Float) -> Int {
        guard length.isFinite, cell.isFinite, cell > 0 else { return 1 }
        let raw = (length / cell - 0.001).rounded(.up)
        return Swift.max(1, Int(raw))
    }

    /// Appends one rectangle `origin + s * u + t * v` as a grid of cells, two triangles each,
    /// wound so the cross product of each triangle points along `normal`.
    static func appendRect(origin: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>, cell: Float, normal: SIMD3<Float>,
                           surface: UInt8, positions: inout [SIMD3<Float>], indices: inout [UInt32],
                           classes: inout [UInt8]) {
        let nu = cellCount(length: simd_length(u), cell: cell)
        let nv = cellCount(length: simd_length(v), cell: cell)
        let du = u / Float(nu)
        let dv = v / Float(nv)
        let base = UInt32(positions.count)
        for j in 0...nv {
            for i in 0...nu {
                let offset = du * Float(i) + dv * Float(j)
                positions.append(origin + offset)
            }
        }
        let alongNormal = simd_dot(simd_cross(du, dv), normal) >= 0
        let row = UInt32(nu + 1)
        for j in 0..<nv {
            for i in 0..<nu {
                let p00 = base + UInt32(j) * row + UInt32(i)
                let p10 = p00 + 1
                let p01 = p00 + row
                let p11 = p01 + 1
                if alongNormal {
                    indices.append(contentsOf: [p00, p10, p11, p00, p11, p01])
                } else {
                    indices.append(contentsOf: [p00, p11, p10, p00, p01, p11])
                }
                classes.append(surface)
                classes.append(surface)
            }
        }
    }

    // MARK: - Walk

    /// The 34-pose walk around plan point `center` at `eyeHeight`: 16 looks from the center
    /// (every 22.5 degrees, alternating 40 degrees down and 30 up), 8 looks 60 degrees down and 8
    /// looks 60 degrees up from a 1.2 m ring, then one look at the floor and one at the ceiling.
    static func walk(center: SIMD2<Float>, eyeHeight: Float) -> [DemoCameraPose] {
        let eye = PlanAxes.toWorld(center, y: eyeHeight)
        var out: [DemoCameraPose] = []
        for k in 0..<16 {
            let pitch: Float = k % 2 == 0 ? -40 : 30
            out.append(DemoCameraPose(heading: 22.5 * Float(k), pitch: pitch, position: eye))
        }
        for k in 0..<8 {
            let azimuth = 45 * Float(k)
            out.append(DemoCameraPose(heading: azimuth, pitch: -60, position: ring(eye, azimuth: azimuth)))
        }
        for k in 0..<8 {
            let azimuth = 45 * Float(k) + 22.5
            out.append(DemoCameraPose(heading: azimuth, pitch: 60, position: ring(eye, azimuth: azimuth)))
        }
        out.append(DemoCameraPose(heading: 0, pitch: -80, position: eye))
        out.append(DemoCameraPose(heading: 180, pitch: 80, position: eye))
        return out
    }

    /// The point 1.2 m from `eye` toward `azimuth` degrees on the floor plane.
    static func ring(_ eye: SIMD3<Float>, azimuth: Float) -> SIMD3<Float> {
        let a = Double(azimuth) * Double.pi / 180
        let offset = SIMD3<Float>(Float(1.2 * cos(a)), 0, Float(1.2 * sin(a)))
        return eye + offset
    }

    /// Camera to world of a pose held in portrait: the camera looks down its local -Z along the
    /// heading and pitch, local +X points down along the image's long side.
    static func transform(_ pose: DemoCameraPose) -> simd_float4x4 {
        let h = Double(pose.heading) * Double.pi / 180
        let t = Double(pose.pitch) * Double.pi / 180
        let forward = SIMD3<Float>(Float(cos(h) * cos(t)), Float(sin(t)), Float(sin(h) * cos(t)))
        let up = SIMD3<Float>(0, 1, 0)
        let upInView = simd_normalize(up - forward * simd_dot(up, forward))
        let x = -upInView
        let z = -forward
        let y = simd_cross(z, x)
        return simd_float4x4(columns: (SIMD4<Float>(x, 0), SIMD4<Float>(y, 0), SIMD4<Float>(z, 0),
                                       SIMD4<Float>(pose.position, 1)))
    }

    /// One pose sample per walk pose, `poseInterval` apart, normal tracking.
    static func poses(_ walk: [DemoCameraPose]) -> [PoseSample] {
        walk.enumerated().map { item in
            PoseSample(timestamp: Double(item.offset) * poseInterval, transform: transform(item.element), tracking: 2,
                       thermal: 0, exposureDuration: 1.0 / 60)
        }
    }

    /// One keyframe record per walk pose in normal light (records only; no image is written).
    static func keyframes(_ walk: [DemoCameraPose]) -> [KeyframeRecord] {
        walk.enumerated().map { item in
            KeyframeRecord(index: item.offset, timestamp: Double(item.offset) * poseInterval,
                           transform: Transform4(transform(item.element)), intrinsics: intrinsics,
                           imageFile: RawScanFolder.keyframeImagePath(item.offset), depthFile: nil,
                           exposureDuration: 1.0 / 60, exposureOffset: 0, ambientIntensity: 1000, angularSpeed: 0,
                           trackingNormal: true)
        }
    }
}
