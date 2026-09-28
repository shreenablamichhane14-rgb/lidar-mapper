import Foundation
import simd

// Synthetic fixtures for CoverageSelfTest, matching the numpy prototype of the coverage engine:
// a 4 x 5 x 2.5 m box room, a triangle mesh of its shell, the camera intrinsics of a 1920 x 1440
// frame, the 11-pose camera path from the room center (sees walls 0 and 3 and part of the floor,
// only thin corner strips of walls 1 and 2 and low-quality strips of the ceiling), and a
// guidance trace runner on a fixed 0.25 s tick (exact in binary floating point).

/// Room, mesh, camera and guidance fixtures used by `CoverageSelfTest`.
enum CoverageSelfTestFixtures {
    /// Test mesh: faces plus the element id of each face (wall index >= 0, -1 floor, -2 ceiling).
    struct Mesh {
        /// Faces in the order wall 0, wall 1, wall 2, wall 3, floor, ceiling; per rectangle
        /// rows (j) outer, columns (i) inner, two triangles per cell.
        var faces: [CoverageFace]
        /// Element id parallel to `faces`.
        var element: [Int]
    }

    /// Camera orientation in degrees: yaw 0 looks toward -Z, yaw 90 toward -X; pitch > 0 looks up.
    struct PoseAngles {
        /// Rotation about +Y in degrees.
        var yaw: Float
        /// Rotation about the camera X axis in degrees.
        var pitch: Float
    }

    /// Camera position of the test path: room center at 1.4 m eye height.
    static let eye = SIMD3<Float>(2, 1.4, 2.5)

    /// One pass of the prototype camera path: a level sweep 2 degrees up (wall tops), a sweep
    /// 40 degrees down (wall bottoms and floor), and one look at the feet.
    static let passPoses: [PoseAngles] = [
        PoseAngles(yaw: -5, pitch: 2), PoseAngles(yaw: 20, pitch: 2), PoseAngles(yaw: 50, pitch: 2),
        PoseAngles(yaw: 80, pitch: 2), PoseAngles(yaw: 110, pitch: 2),
        PoseAngles(yaw: 110, pitch: -40), PoseAngles(yaw: 80, pitch: -40), PoseAngles(yaw: 50, pitch: -40),
        PoseAngles(yaw: 20, pitch: -40), PoseAngles(yaw: -5, pitch: -40),
        PoseAngles(yaw: 45, pitch: -80),
    ]

    /// Image size of the synthetic camera, pixels.
    static let resolution = SIMD2<Float>(1920, 1440)

    /// Pinhole intrinsics fx = fy = 1440, cx = 960, cy = 720 (column-major like ARKit).
    static let intrinsics = simd_float3x3(columns: (SIMD3<Float>(1440, 0, 0),
                                                    SIMD3<Float>(0, 1440, 0),
                                                    SIMD3<Float>(960, 720, 1)))

    /// The 4 x 5 x 2.5 m box room: floor polygon (0,0),(4,0),(4,5),(0,5) in (x, z), walls in
    /// that order (wall 0 on z = 0, wall 1 on x = 4, wall 2 on z = 5, wall 3 on x = 0).
    static func boxRoom() -> CoverageRoomBoundary {
        let polygon: [SIMD2<Float>] = [SIMD2<Float>(0, 0), SIMD2<Float>(4, 0),
                                       SIMD2<Float>(4, 5), SIMD2<Float>(0, 5)]
        var walls: [CoverageWall] = []
        for i in 0..<polygon.count {
            walls.append(CoverageWall(start: polygon[i], end: polygon[(i + 1) % polygon.count],
                                      baseY: 0, height: 2.5))
        }
        return CoverageRoomBoundary(walls: walls, floorPolygon: polygon, floorY: 0,
                                    ceilingPolygon: [], ceilingY: 2.5)
    }

    /// Triangulates the room shell: each rectangle is cut into ceil(L / cell - 0.001) equal
    /// cells per axis, two triangles per cell with centroids at cell coordinates
    /// (i + 2/3, j + 1/3) and (i + 1/3, j + 2/3). Wall normals point into the room.
    static func boxMesh(room: CoverageRoomBoundary, cell: Float) -> Mesh {
        var mesh = Mesh(faces: [], element: [])
        for (index, wall) in room.walls.enumerated() {
            guard let n2 = ExpectedSurfaces.inwardNormal(of: wall, polygon: room.floorPolygon) else { continue }
            let d = wall.end - wall.start
            let length = simd_length(d)
            appendRect(origin: SIMD3<Float>(wall.start.x, wall.baseY, wall.start.y),
                       u: SIMD3<Float>(d.x, 0, d.y), v: SIMD3<Float>(0, wall.height, 0),
                       nu: ExpectedSurfaces.cellCount(length: length, spacing: cell),
                       nv: ExpectedSurfaces.cellCount(length: wall.height, spacing: cell),
                       normal: SIMD3<Float>(n2.x, 0, n2.y), surface: .wall, element: index, into: &mesh)
        }
        guard let first = room.floorPolygon.first else { return mesh }
        var lo = first
        var hi = first
        for p in room.floorPolygon {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        let size = hi - lo
        let nx = ExpectedSurfaces.cellCount(length: size.x, spacing: cell)
        let nz = ExpectedSurfaces.cellCount(length: size.y, spacing: cell)
        appendRect(origin: SIMD3<Float>(lo.x, room.floorY, lo.y), u: SIMD3<Float>(size.x, 0, 0),
                   v: SIMD3<Float>(0, 0, size.y), nu: nx, nv: nz, normal: SIMD3<Float>(0, 1, 0),
                   surface: .floor, element: -1, into: &mesh)
        appendRect(origin: SIMD3<Float>(lo.x, room.ceilingY, lo.y), u: SIMD3<Float>(size.x, 0, 0),
                   v: SIMD3<Float>(0, 0, size.y), nu: nx, nv: nz, normal: SIMD3<Float>(0, -1, 0),
                   surface: .ceiling, element: -2, into: &mesh)
        return mesh
    }

    /// Appends nu x nv cells of origin + s * u + t * v as two triangles each.
    private static func appendRect(origin: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>, nu: Int, nv: Int,
                                   normal: SIMD3<Float>, surface: SurfaceClass, element: Int,
                                   into mesh: inout Mesh) {
        guard nu > 0, nv > 0 else { return }
        let du = u / Float(nu)
        let dv = v / Float(nv)
        let half = simd_length(simd_cross(du, dv)) * 0.5
        let third: Float = 1.0 / 3.0
        let twoThirds: Float = 2.0 / 3.0
        for j in 0..<nv {
            for i in 0..<nu {
                let fi = Float(i)
                let fj = Float(j)
                let c1 = origin + du * (fi + twoThirds) + dv * (fj + third)
                let c2 = origin + du * (fi + third) + dv * (fj + twoThirds)
                mesh.faces.append(CoverageFace(centroid: c1, normal: normal, area: half, surface: surface))
                mesh.faces.append(CoverageFace(centroid: c2, normal: normal, area: half, surface: surface))
                mesh.element.append(element)
                mesh.element.append(element)
            }
        }
    }

    /// Camera-to-world transform R = Ry(yaw) * Rx(pitch) at `position` (camera looks down -Z).
    static func pose(yaw: Float, pitch: Float, at position: SIMD3<Float>) -> simd_float4x4 {
        let y = Double(yaw) * Double.pi / 180
        let p = Double(pitch) * Double.pi / 180
        let cy = Float(cos(y)), sy = Float(sin(y))
        let cp = Float(cos(p)), sp = Float(sin(p))
        return simd_float4x4(columns: (SIMD4<Float>(cy, 0, -sy, 0),
                                       SIMD4<Float>(sy * sp, cp, cy * sp, 0),
                                       SIMD4<Float>(sy * cp, -sp, cy * cp, 0),
                                       SIMD4<Float>(position.x, position.y, position.z, 1)))
    }

    /// One observation with the fixture intrinsics and resolution.
    static func observation(_ cameraToWorld: simd_float4x4, confidence: Float?, tracking: Bool = true,
                            time: Double = 0) -> CoverageObservation {
        CoverageObservation(cameraToWorld: cameraToWorld, intrinsics: intrinsics, imageResolution: resolution,
                            trackingNormal: tracking, depthConfidenceMean: confidence, timestamp: time)
    }

    /// Outputs of a fresh `GuidanceEngine` fed one input per 0.25 s tick from t = 0.
    struct GuidanceTrace {
        /// Tick length in seconds (exact in binary, so all tick times are exact).
        static let step: Double = 0.25
        /// Output of tick i (time i * step).
        var outputs: [GuidanceOutput]

        /// Runs `ticks` ticks, asking `input` for the signals at each tick time.
        init(ticks: Int, input: (Double) -> GuidanceInput) {
            var engine = GuidanceEngine()
            var out: [GuidanceOutput] = []
            out.reserveCapacity(max(ticks, 0))
            for i in 0..<max(ticks, 0) {
                out.append(engine.update(input(Double(i) * GuidanceTrace.step)))
            }
            outputs = out
        }

        /// Output at tick time `t` (nearest tick); an empty output outside the trace.
        func at(_ t: Double) -> GuidanceOutput {
            let i = Int((t / GuidanceTrace.step).rounded())
            guard i >= 0, i < outputs.count else { return GuidanceOutput(message: nil, fireHaptic: false) }
            return outputs[i]
        }

        /// Message shown at tick time `t`.
        func message(at t: Double) -> GuidanceKind? {
            at(t).message
        }

        /// Number of ticks that fired a haptic.
        var hapticCount: Int {
            outputs.filter { $0.fireHaptic }.count
        }

        /// Number of ticks whose message differs from the previous tick (the first tick is
        /// compared with no message).
        var changeCount: Int {
            var n = 0
            var previous: GuidanceKind?
            for o in outputs {
                if o.message != previous { n += 1 }
                previous = o.message
            }
            return n
        }

        /// Number of times a message newly appeared at a tick earlier than `t`.
        func appearances(before t: Double) -> Int {
            var n = 0
            var previous: GuidanceKind?
            for (i, o) in outputs.enumerated() {
                if Double(i) * GuidanceTrace.step >= t { break }
                if let m = o.message, m != previous { n += 1 }
                previous = o.message
            }
            return n
        }
    }
}

/// Counts checks and collects failure lines.
struct CoverageSelfTestChecker {
    /// Failure lines so far.
    var failures: [String] = []
    /// Number of checks run.
    var count = 0

    /// Records one boolean check.
    mutating func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        count += 1
        if !ok {
            let d = detail()
            failures.append(d.isEmpty ? "\(name): failed" : "\(name): \(d)")
        }
    }

    /// Records |actual - expected| <= tolerance (NaN fails).
    mutating func near(_ name: String, _ actual: Float, _ expected: Float, _ tolerance: Float) {
        check(name, abs(actual - expected) <= tolerance, "expected \(expected) +/- \(tolerance), got \(actual)")
    }

    /// Records lower <= actual <= upper (NaN fails).
    mutating func between(_ name: String, _ actual: Float, _ lower: Float, _ upper: Float) {
        check(name, actual >= lower && actual <= upper, "expected \(lower)...\(upper), got \(actual)")
    }

    /// Records every component of `actual` within `tolerance` of `expected`.
    mutating func nearVec(_ name: String, _ actual: SIMD3<Float>, _ expected: SIMD3<Float>, _ tolerance: Float) {
        let d = actual - expected
        check(name, abs(d.x) <= tolerance && abs(d.y) <= tolerance && abs(d.z) <= tolerance,
              "expected \(expected) +/- \(tolerance), got \(actual)")
    }
}
