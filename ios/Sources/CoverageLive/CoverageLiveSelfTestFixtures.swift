import Foundation
import simd

// Fixtures of CoverageLiveSelfTest: synthetic mesh chunks, cameras and RoomPlan-like rooms. All
// values are fixed (no clock, no randomness); world meters, +Y up, cameras look down their -Z.

extension CoverageLiveSelfTest {
    /// Failure lines and the number of checks run.
    final class Checks {
        /// Failure lines.
        private(set) var failures: [String] = []
        /// Checks run so far.
        private(set) var count = 0

        /// Records a failure when `condition` is false.
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            count += 1
            if !condition { failures.append(detail.isEmpty ? name : "\(name): \(detail)") }
        }
    }

    /// Profile of every test recording.
    static let profile = ScanProfile(mode: .room, settings: ScanSettings.defaults(for: .room))

    /// A fixed anchor or surface identifier.
    static func fixedID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012ld", n)) ?? UUID()
    }

    // MARK: Chunks

    /// A 1 m square in the local xy plane (normal +z): 4 vertices with normals (0, 0, 1), 2 faces
    /// with classes wall and floor; `degenerate` adds a third, zero-area triangle.
    static func square(anchor: Int, transform: simd_float4x4 = matrix_identity_float4x4,
                       degenerate: Bool = false) -> MeshChunk {
        let positions: [SIMD3<Float>] = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0),
                                         SIMD3<Float>(1, 1, 0), SIMD3<Float>(0, 1, 0)]
        let normals = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 1), count: 4)
        var indices: [UInt32] = [0, 1, 2, 0, 2, 3]
        var classes: [UInt8] = [1, 2]
        if degenerate {
            indices.append(contentsOf: [0, 1, 1])
            classes.append(1)
        }
        return MeshChunk(anchorID: fixedID(anchor), transform: transform, updateCount: 0, positions: positions,
                         normals: normals, indices: indices, classes: classes)
    }

    /// One triangle wound clockwise seen from +z (cross product -z) with the given vertex normals.
    static func reversedTriangle(normals: [SIMD3<Float>]) -> MeshChunk {
        let positions: [SIMD3<Float>] = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(1, 0, 0)]
        return MeshChunk(anchorID: fixedID(50), transform: matrix_identity_float4x4, updateCount: 0,
                         positions: positions, normals: normals, indices: [0, 1, 2])
    }

    /// A pure translation.
    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }

    // MARK: Cameras

    /// Camera to world at `position` looking along `forward` (+Y up; straight up or down uses
    /// world +x as the image right).
    static func camera(at position: SIMD3<Float>, looking forward: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(forward)
        let up = SIMD3<Float>(0, 1, 0)
        let right = abs(simd_dot(f, up)) > 0.99 ? SIMD3<Float>(1, 0, 0) : simd_normalize(simd_cross(f, up))
        let back = -f
        let top = simd_cross(back, right)
        return simd_float4x4(columns: (SIMD4<Float>(right, 0), SIMD4<Float>(top, 0), SIMD4<Float>(back, 0),
                                       SIMD4<Float>(position, 1)))
    }

    /// Pinhole intrinsics for a 1920 x 1440 image with the principal point at the center.
    static func intrinsics(focal: Float) -> simd_float3x3 {
        simd_float3x3(columns: (SIMD3<Float>(focal, 0, 0), SIMD3<Float>(0, focal, 0), SIMD3<Float>(960, 720, 1)))
    }

    /// One normal-tracking observation without depth confidence (confidence term 0.8).
    static func observation(at position: SIMD3<Float>, looking forward: SIMD3<Float>, time: Double,
                            focal: Float = 1000) -> CoverageObservation {
        CoverageObservation(cameraToWorld: camera(at: position, looking: forward), intrinsics: intrinsics(focal: focal),
                            imageResolution: SIMD2<Float>(1920, 1440), trackingNormal: true,
                            depthConfidenceMean: nil, timestamp: time)
    }

    // MARK: Rooms

    /// A RoomPlan-like surface from world (x, z) `a` to `b`: columns.0 along it, columns.1 up,
    /// center at `baseY + height / 2`.
    static func surface(_ id: Int, kind: SurfaceKind, from a: SIMD2<Float>, to b: SIMD2<Float>,
                        baseY: Float, height: Float) -> SurfaceInput {
        let d = b - a
        let length = simd_length(d)
        let along = SIMD3<Float>(d.x / length, 0, d.y / length)
        let up = SIMD3<Float>(0, 1, 0)
        let normal = simd_cross(along, up)
        let mid = (a + b) * 0.5
        let matrix = simd_float4x4(columns: (SIMD4<Float>(along, 0), SIMD4<Float>(up, 0), SIMD4<Float>(normal, 0),
                                             SIMD4<Float>(mid.x, baseY + height * 0.5, mid.y, 1)))
        return SurfaceInput(identifier: fixedID(id), parentIdentifier: nil, kind: kind, transform: Transform4(matrix),
                            dimensions: Vec3(x: length, y: height, z: 0), confidence: .high, completedEdges: 4,
                            curve: nil, polygonCorners: [], story: 0)
    }

    /// Corners of the 4 x 5 m test room in world (x, z): x from -2 to 2, z from -2.5 to 2.5.
    static let roomCorners: [SIMD2<Float>] = [SIMD2<Float>(-2, -2.5), SIMD2<Float>(2, -2.5),
                                             SIMD2<Float>(2, 2.5), SIMD2<Float>(-2, 2.5)]

    /// A 4 x 5 m room with 4 walls of 2.5 m on the floor y = 0, the given openings and an
    /// optional floor surface whose plan y runs from -2 to 3 (world z from 2 to -3).
    static func room(openings: [SurfaceInput] = [], withFloor: Bool = false) -> RoomInput {
        var walls: [SurfaceInput] = []
        for i in 0..<4 {
            walls.append(surface(i + 1, kind: .wall, from: roomCorners[i], to: roomCorners[(i + 1) % 4],
                                 baseY: 0, height: 2.5))
        }
        var floors: [SurfaceInput] = []
        if withFloor {
            // Floor frame: columns.0 world +x, columns.1 world -z (plan +y), columns.2 world up.
            let matrix = simd_float4x4(columns: (SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 0, -1, 0),
                                                 SIMD4<Float>(0, 1, 0, 0), SIMD4<Float>(0, 0, 0, 1)))
            let corners = [Vec3(x: -2, y: -2, z: 0), Vec3(x: 2, y: -2, z: 0), Vec3(x: 2, y: 3, z: 0), Vec3(x: -2, y: 3, z: 0)]
            floors.append(SurfaceInput(identifier: fixedID(20), parentIdentifier: nil, kind: .floor,
                                       transform: Transform4(matrix), dimensions: Vec3(x: 4, y: 5, z: 0),
                                       confidence: .high, completedEdges: 4, curve: nil, polygonCorners: corners, story: 0))
        }
        return RoomInput(identifier: fixedID(30), walls: walls, openings: openings, floors: floors, objects: [],
                         sections: [], story: 0)
    }

    /// A 1 x 1 m window on the z = -2.5 wall, x from -0.45 to 0.55, y from 1 to 2 (so no 0.2 m
    /// sample column sits on its edge: exactly 5 x 5 wall samples fall inside).
    static func window() -> SurfaceInput {
        surface(40, kind: .window, from: SIMD2<Float>(-0.45, -2.5), to: SIMD2<Float>(0.55, -2.5), baseY: 1, height: 1)
    }

    /// A door on the x = 2 wall and an opening on the x = -2 wall.
    static func doorAndOpening() -> [SurfaceInput] {
        [surface(41, kind: .door, from: SIMD2<Float>(2, 0), to: SIMD2<Float>(2, 0.9), baseY: 0, height: 2.1),
         surface(42, kind: .opening, from: SIMD2<Float>(-2, 1), to: SIMD2<Float>(-2, 0), baseY: 0, height: 2.2)]
    }

    /// A missing area fixture.
    static func area(_ centroid: SIMD3<Float>, surface: SurfaceClass = .wall, size: Float = 0.5) -> MissingArea {
        MissingArea(centroid: centroid, normal: SIMD3<Float>(0, 0, 1), area: size, surface: surface,
                    suggestedViewpoint: centroid)
    }

    // MARK: Small helpers

    /// True when `a` and `b` differ by at most `tolerance` in every component.
    static func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float = 1e-4) -> Bool {
        simd_length(a - b) <= tolerance
    }

    /// Smallest absolute difference between two angles, radians.
    static func angleDifference(_ a: Float, _ b: Float) -> Float {
        let d = abs(a - b).truncatingRemainder(dividingBy: 2 * .pi)
        return min(d, 2 * .pi - d)
    }

    /// Calls `finishRecording` and waits (at most 5 s) for its completion.
    static func finish(_ recorder: ScanRecorder) -> Bool {
        let done = DispatchSemaphore(value: 0)
        recorder.finishRecording { done.signal() }
        return done.wait(timeout: .now() + 5) == .success
    }
}
