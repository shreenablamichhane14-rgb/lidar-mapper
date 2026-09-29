import Foundation
import simd

// Synthetic fixtures of the LargeObject self-test: camera poses, a 1 m box on the floor with its
// sector coverage, cube faces for the scores, face samples of a cube beside a wall column, and
// small anchors for the ray pick. Deterministic, no ARKit.

extension LargeObjectSelfTest {
    // MARK: - Poses

    /// A camera at `eye` looking at `target` (ARKit convention: the camera looks down its -Z).
    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
        let forward = simd_normalize(target - eye)
        let back = -forward
        var up = SIMD3<Float>(0, 1, 0)
        if abs(simd_dot(up, back)) > 0.999 { up = SIMD3<Float>(0, 0, -1) }
        let right = simd_normalize(simd_cross(up, back))
        let cameraUp = simd_cross(back, right)
        return simd_float4x4(columns: (SIMD4<Float>(right, 0), SIMD4<Float>(cameraUp, 0),
                                       SIMD4<Float>(back, 0), SIMD4<Float>(eye, 1)))
    }

    /// A camera `distance` meters from the box center at `azimuth` degrees (0 front = +Z, +90 right
    /// = +X), at the center's height, looking at the center.
    static func orbitCamera(azimuth: Float, distance: Float, center: SIMD3<Float> = SIMD3<Float>(0, 0.5, 0)) -> simd_float4x4 {
        let radians = azimuth * Float.pi / 180
        let eye = center + SIMD3<Float>(sin(radians), 0, cos(radians)) * distance
        return lookAt(eye: eye, target: center)
    }

    /// Feeds `count` poses of 0.1 s from `camera` (tracking normal).
    static func observe(_ sectors: inout SectorCoverage, _ camera: simd_float4x4, count: Int) {
        for _ in 0..<count {
            sectors.observe(cameraToWorld: camera, seconds: 0.1, trackingNormal: true)
        }
    }

    /// Covers every listed side by 2 s of viewing from 2 m, and the top when `top` is true.
    static func cover(_ sectors: inout SectorCoverage, sides: [Int], top: Bool = false) {
        for side in sides {
            observe(&sectors, orbitCamera(azimuth: Float(side) * 45, distance: 2), count: 20)
        }
        if top {
            observe(&sectors, lookAt(eye: SIMD3<Float>(0, 2, 0.01), target: SIMD3<Float>(0, 1, 0)), count: 20)
        }
    }

    // MARK: - Boxes

    /// A 1 m cube standing on the floor at the origin (axis aligned).
    static let unitBox = OrientedBox(center: SIMD3<Float>(0, 0.5, 0), axes: matrix_identity_float3x3,
                                     halfExtents: SIMD3<Float>(0.5, 0.5, 0.5))

    /// Fresh sectors of `unitBox` with the first camera at +Z.
    static func freshSectors(_ box: OrientedBox = LargeObjectSelfTest.unitBox) -> SectorCoverage {
        SectorCoverage(box: box, floorY: 0, firstCamera: SIMD3<Float>(0, 0.5, 3))
    }

    // MARK: - Faces

    /// Patches of 0.25 m on the six faces of a 1 m cube centered at (0, 0.5, 0), normals outward
    /// (or inward when `inward`), all in `state`.
    static func cubeFaces(state: CoverageState, inward: Bool = false) -> [SectorFace] {
        let normals: [SIMD3<Float>] = [SIMD3<Float>(1, 0, 0), SIMD3<Float>(-1, 0, 0), SIMD3<Float>(0, 1, 0),
                                       SIMD3<Float>(0, -1, 0), SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 0, -1)]
        let center = SIMD3<Float>(0, 0.5, 0)
        var out: [SectorFace] = []
        for normal in normals {
            let (u, v) = tangents(of: normal)
            for i in 0..<4 {
                for j in 0..<4 {
                    let a = (Float(i) + 0.5) * 0.25 - 0.5
                    let b = (Float(j) + 0.5) * 0.25 - 0.5
                    let centroid = center + normal * 0.5 + u * a + v * b
                    out.append(SectorFace(centroid: centroid, normal: inward ? -normal : normal, area: 0.0625, state: state))
                }
            }
        }
        return out
    }

    /// Only the +Z (front) patches of `cubeFaces`.
    static func frontFaces(state: CoverageState) -> [SectorFace] {
        cubeFaces(state: state).filter { $0.normal.z > 0.9 }
    }

    /// Two unit vectors perpendicular to an axis-aligned `normal`.
    static func tangents(of normal: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        if abs(normal.x) > 0.5 { return (SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)) }
        if abs(normal.y) > 0.5 { return (SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, 1)) }
        return (SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0))
    }

    // MARK: - Growth samples

    /// Surface samples every 0.05 m of a 1 m cube spanning x and z in [-0.49, 0.51], y in [0, 1]
    /// (class none), with no sample exactly on a voxel boundary in x or z.
    static func cubeSamples() -> [LargeObjectSample] {
        var out: [LargeObjectSample] = []
        let steps = 20
        for i in 0...steps {
            for j in 0...steps {
                let a = -0.49 + Float(i) * 0.05
                let b = -0.49 + Float(j) * 0.05
                let y = Float(j) * 0.05
                out.append(LargeObjectSample(position: SIMD3<Float>(-0.49, y, a), surface: .none))
                out.append(LargeObjectSample(position: SIMD3<Float>(0.51, y, a), surface: .none))
                out.append(LargeObjectSample(position: SIMD3<Float>(a, y, -0.49), surface: .none))
                out.append(LargeObjectSample(position: SIMD3<Float>(a, y, 0.51), surface: .none))
                out.append(LargeObjectSample(position: SIMD3<Float>(a, 1.0, b), surface: .none))
                out.append(LargeObjectSample(position: SIMD3<Float>(a, 0.0, b), surface: .none))
            }
        }
        return out
    }

    /// A 3 m tall wall-classified column of samples at x = 0.65 (the voxel next to the cube's +X face).
    static func wallSamples() -> [LargeObjectSample] {
        var out: [LargeObjectSample] = []
        for i in 0...20 {
            for k in 0...60 {
                let z = -0.49 + Float(i) * 0.05
                let y = Float(k) * 0.05
                out.append(LargeObjectSample(position: SIMD3<Float>(0.65, y, z), surface: .wall))
            }
        }
        return out
    }

    /// Floor-classified samples around the cube at y = 0 (a 3 m square, every 0.1 m).
    static func floorSamples() -> [LargeObjectSample] {
        var out: [LargeObjectSample] = []
        for i in 0...30 {
            for j in 0...30 {
                let x = -1.5 + Float(i) * 0.1
                let z = -1.5 + Float(j) * 0.1
                out.append(LargeObjectSample(position: SIMD3<Float>(x, 0, z), surface: .floor))
            }
        }
        return out
    }

    /// Cube, wall column and floor together.
    static func sceneSamples() -> [LargeObjectSample] {
        cubeSamples() + wallSamples() + floorSamples()
    }

    // MARK: - Anchors

    /// One anchor holding the given local quad (two triangles), placed by `transform`; faces and
    /// states are filled like CoverageLive's (world centroids, gray, area 0.5 each).
    static func quadAnchor(id: UInt8, transform: simd_float4x4, corners: [SIMD3<Float>],
                           surface: SurfaceClass = .none) -> CoverageAnchorFaces {
        let world = corners.map { p -> SIMD3<Float> in
            let h = simd_mul(transform, SIMD4<Float>(p, 1))
            return SIMD3<Float>(h.x, h.y, h.z)
        }
        let indices: [UInt32] = [0, 1, 2, 0, 2, 3]
        var faces: [CoverageFace] = []
        for t in 0..<2 {
            let a = world[Int(indices[3 * t])]
            let b = world[Int(indices[3 * t + 1])]
            let c = world[Int(indices[3 * t + 2])]
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            let normal = length > 0 ? cross / length : SIMD3<Float>(0, 0, 1)
            faces.append(CoverageFace(centroid: (a + b + c) / 3, normal: normal, area: 0.5 * length, surface: surface))
        }
        var low = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        for p in world {
            low = simd_min(low, p)
            high = simd_max(high, p)
        }
        return CoverageAnchorFaces(anchorID: fixedID(id), updateCount: 1, transform: transform, localPositions: corners,
                                   localNormals: [], indices: indices, faces: faces,
                                   states: [CoverageState.gray, CoverageState.gray], boundsMin: low, boundsMax: high,
                                   revision: 1)
    }

    /// A 1 m quad in its local z = 0 plane.
    static let unitQuad: [SIMD3<Float>] = [SIMD3<Float>(-0.5, -0.5, 0), SIMD3<Float>(0.5, -0.5, 0),
                                          SIMD3<Float>(0.5, 0.5, 0), SIMD3<Float>(-0.5, 0.5, 0)]

    /// A translation matrix.
    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t, 1)
        return m
    }

    /// A fixed UUID whose last byte is `n`.
    static func fixedID(_ n: UInt8) -> UUID {
        UUID(uuid: (0x4C, 0x4F, 0x42, 0x4A, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, n))
    }
}
