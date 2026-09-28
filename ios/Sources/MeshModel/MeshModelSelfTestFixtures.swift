import Foundation
import simd

/// Deterministic test scenes for `MeshModelSelfTest`: fixed ids, transforms, a unit cube split
/// into two overlapping anchor-local halves, grid patches (with an optional hole), a floater
/// scene, a 20,000 triangle sphere and temporary folders.
extension MeshModelSelfTest {
    /// A fixed UUID whose last byte is `n` (no randomness in the self-test).
    static func fixedID(_ n: UInt8) -> UUID {
        UUID(uuid: (0x4D, 0x4D, 0x53, 0x54, 0x00, 0x00, 0x40, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, n))
    }

    /// Translation matrix.
    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t, 1)
        return m
    }

    /// Rotation about +Y by `angle` radians.
    static func rotationY(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle)
        let s = sin(angle)
        return simd_float4x4(columns: (SIMD4<Float>(c, 0, -s, 0), SIMD4<Float>(0, 1, 0, 0),
                                       SIMD4<Float>(s, 0, c, 0), SIMD4<Float>(0, 0, 0, 1)))
    }

    /// A chunk whose anchor-local positions are `world` moved by the inverse of `transform`, so
    /// `transform` brings them back to `world`.
    static func chunk(id: UUID, transform: simd_float4x4, world: [SIMD3<Float>], indices: [UInt32],
                      classes: [UInt8] = [], updateCount: UInt32 = 1) -> MeshChunk {
        let inverse = simd_inverse(transform)
        let local = world.map { p -> SIMD3<Float> in
            let h = simd_mul(inverse, SIMD4<Float>(p, 1))
            return SIMD3<Float>(h.x, h.y, h.z)
        }
        return MeshChunk(anchorID: id, transform: transform, updateCount: updateCount, positions: local,
                         indices: indices, classes: classes)
    }

    // MARK: - Cube

    /// World offset of the test cube's minimum corner.
    static let cubeOffset = SIMD3<Float>(2, 0.5, -1)

    /// The 8 corners of the unit cube at `cubeOffset`.
    static func cubeCorners() -> [SIMD3<Float>] {
        let unit: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(1, 1, 0), SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 0, 1), SIMD3<Float>(1, 1, 1), SIMD3<Float>(0, 1, 1)
        ]
        return unit.map { $0 + cubeOffset }
    }

    /// The 12 outward counter-clockwise faces of the cube, 3 indices each, in the order
    /// z = 0, z = 1, y = 0, y = 1, x = 0, x = 1 (two faces per side).
    static let cubeFaces: [UInt32] = [
        0, 2, 1, 0, 3, 2,
        4, 5, 6, 4, 6, 7,
        0, 1, 5, 0, 5, 4,
        3, 7, 6, 3, 6, 2,
        0, 4, 7, 0, 7, 3,
        1, 2, 6, 1, 6, 5
    ]

    /// Transform of cube half A (translation only).
    static let cubeTransformA = MeshModelSelfTest.translation(SIMD3<Float>(0.5, 1, -0.25))
    /// Transform of cube half B (quarter turn about Y, then a translation).
    static let cubeTransformB = simd_mul(MeshModelSelfTest.translation(SIMD3<Float>(-1, 0.5, 2)),
                                         MeshModelSelfTest.rotationY(Float.pi / 2))

    /// Half A: faces 0..<8 (z and y sides), class 1 (wall). Half B: faces 4..<12 (y and x
    /// sides), class 2 (floor). The y sides are in both, so 4 faces overlap; A comes first and
    /// wins them. Each half keeps all 8 corners in its own anchor frame.
    static func cubeHalves() -> [MeshChunk] {
        let corners = cubeCorners()
        let a = Array(cubeFaces[0..<24])
        let b = Array(cubeFaces[12..<36])
        return [
            chunk(id: fixedID(1), transform: cubeTransformA, world: corners, indices: a,
                  classes: [UInt8](repeating: 1, count: 8)),
            chunk(id: fixedID(2), transform: cubeTransformB, world: corners, indices: b,
                  classes: [UInt8](repeating: 2, count: 8))
        ]
    }

    // MARK: - Grids

    /// Grid patch: vertex (i, j) at `origin + u * i / nu + v * j / nv`; cell (i, j) gives two
    /// faces facing along cross(u, v) unless `skip` contains it. Returns world positions and
    /// indices (vertices of skipped cells stay in the list).
    static func grid(origin: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>, nu: Int, nv: Int,
                     skip: Set<SIMD2<Int32>> = []) -> (positions: [SIMD3<Float>], indices: [UInt32]) {
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity((nu + 1) * (nv + 1))
        for i in 0...nu {
            let s = Float(i) / Float(nu)
            for j in 0...nv {
                let t = Float(j) / Float(nv)
                let p: SIMD3<Float> = origin + s * u + t * v
                positions.append(p)
            }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(6 * nu * nv)
        for i in 0..<nu {
            for j in 0..<nv where !skip.contains(SIMD2<Int32>(Int32(i), Int32(j))) {
                let a = UInt32(i * (nv + 1) + j)
                let b = UInt32((i + 1) * (nv + 1) + j)
                indices.append(contentsOf: [a, b, b + 1, a, b + 1, a + 1])
            }
        }
        return (positions, indices)
    }

    /// A 1 m by 1 m wall patch in the XY plane (20 by 20 cells of 5 cm, 800 faces, class 1)
    /// with the 2 by 2 cells in the middle missing: a 10 cm square hole spanning world x and y
    /// 0.45 to 0.55, perimeter 0.4 m. One chunk with a translation (world positions as listed).
    static func holeChunk() -> MeshChunk {
        let skip: Set<SIMD2<Int32>> = [SIMD2<Int32>(9, 9), SIMD2<Int32>(9, 10), SIMD2<Int32>(10, 9), SIMD2<Int32>(10, 10)]
        let patch = grid(origin: .zero, u: SIMD3<Float>(1, 0, 0), v: SIMD3<Float>(0, 1, 0), nu: 20, nv: 20, skip: skip)
        let faces = patch.indices.count / 3
        return chunk(id: fixedID(3), transform: translation(SIMD3<Float>(0.3, -0.2, 0.1)), world: patch.positions,
                     indices: patch.indices, classes: [UInt8](repeating: 1, count: faces))
    }

    /// A full 1 m wall patch of 20 by 20 cells (800 faces) as one chunk.
    static func fullGridChunk() -> MeshChunk {
        let patch = grid(origin: .zero, u: SIMD3<Float>(1, 0, 0), v: SIMD3<Float>(0, 1, 0), nu: 20, nv: 20)
        return chunk(id: fixedID(4), transform: translation(SIMD3<Float>(0, 0, 0.5)), world: patch.positions,
                     indices: patch.indices)
    }

    /// A 1 m floor patch (10 by 10 cells, 200 faces) in one chunk and a 0.5 m by 0.3 m patch
    /// (5 by 3 cells, 30 faces) 3 m away in another: the second is a floater.
    static func floaterChunks() -> [MeshChunk] {
        let main = grid(origin: .zero, u: SIMD3<Float>(0, 0, 1), v: SIMD3<Float>(1, 0, 0), nu: 10, nv: 10)
        let island = grid(origin: SIMD3<Float>(3, 0.4, 0), u: SIMD3<Float>(0, 0, 0.5), v: SIMD3<Float>(0.3, 0, 0),
                          nu: 5, nv: 3)
        return [
            chunk(id: fixedID(5), transform: translation(SIMD3<Float>(1, 0, 0)), world: main.positions,
                  indices: main.indices, classes: [UInt8](repeating: 2, count: main.indices.count / 3)),
            chunk(id: fixedID(6), transform: translation(SIMD3<Float>(3, 0, 0)), world: island.positions,
                  indices: island.indices, classes: [UInt8](repeating: 4, count: island.indices.count / 3))
        ]
    }

    // MARK: - Sphere

    /// Closed UV sphere of radius 4 m with 100 segments and 101 bands: 20,000 outward faces
    /// (pole fans plus quads), one chunk with identity transform. The radius keeps the closest
    /// vertices (next to the poles) about 8 mm apart, above the 5 mm weld tolerance.
    static func sphereChunk() -> MeshChunk {
        let segments = 100
        let bands = 101
        let radius: Float = 4
        var positions: [SIMD3<Float>] = [SIMD3<Float>(0, radius, 0)]
        for ring in 1..<bands {
            let theta = Float.pi * Float(ring) / Float(bands)
            let y = radius * cos(theta)
            let r = radius * sin(theta)
            for j in 0..<segments {
                let phi = 2 * Float.pi * Float(j) / Float(segments)
                positions.append(SIMD3<Float>(r * cos(phi), y, r * sin(phi)))
            }
        }
        positions.append(SIMD3<Float>(0, -radius, 0))
        let south = UInt32(positions.count - 1)
        func ringVertex(_ ring: Int, _ j: Int) -> UInt32 {
            UInt32(1 + (ring - 1) * segments + (j % segments))
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(6 * segments * bands)
        for j in 0..<segments {
            indices.append(contentsOf: [0, ringVertex(1, j + 1), ringVertex(1, j)])
        }
        for ring in 1..<(bands - 1) {
            for j in 0..<segments {
                let a = ringVertex(ring, j)
                let b = ringVertex(ring, j + 1)
                let c = ringVertex(ring + 1, j)
                let d = ringVertex(ring + 1, j + 1)
                indices.append(contentsOf: [a, d, c, a, b, d])
            }
        }
        for j in 0..<segments {
            indices.append(contentsOf: [ringVertex(bands - 1, j), ringVertex(bands - 1, j + 1), south])
        }
        return MeshChunk(anchorID: fixedID(7), transform: matrix_identity_float4x4, updateCount: 1,
                         positions: positions, indices: indices)
    }

    // MARK: - Helpers

    /// A fresh, empty temporary folder for this self-test (any leftover is removed first).
    static func makeTemporaryFolder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a chunk as `mesh/<fileName>` inside a raw scan folder, creating `mesh/`.
    static func writeChunk(_ chunk: MeshChunk, into folder: RawScanFolder, fileName: String) throws {
        try FileManager.default.createDirectory(at: folder.meshURL, withIntermediateDirectories: true)
        let url = folder.meshURL.appendingPathComponent(fileName, isDirectory: false)
        try MeshChunkFile.encode(chunk).write(to: url, options: .atomic)
    }

    /// True when a face centroid of `mesh` lies strictly inside the square hole of `holeChunk`
    /// (world x and y between 0.46 and 0.54).
    static func hasFaceInHole(_ mesh: MeshWithAttributes) -> Bool {
        for t in 0..<mesh.triangleCount {
            guard let corners = mesh.mesh.triangle(t) else { continue }
            let c = (corners.0 + corners.1 + corners.2) / 3
            if c.x > 0.46 && c.x < 0.54 && c.y > 0.46 && c.y < 0.54 { return true }
        }
        return false
    }
}
