import CoreGraphics
import Foundation
import simd

/// Synthetic scenes, cameras and ground-truth renderings for `TexturingSelfTest`.
///
/// The main scene matches the numpy prototype: a unit cube centered at (0, 0, -2) with every
/// side split 2 x 2 (8 triangles per side, outward counter-clockwise winding, sides in the
/// order +x, -x, +y, -y, +z, -z) followed by a 4 x 5 m floor at y = -0.5 split 8 x 8.
/// Every surface point has a known color: a 0.1 m checkerboard (offset 0.05 m so no cube side
/// lies on a checker plane) times a tint that depends on the side's normal direction.
enum TXTestScenes {
    /// Synthetic image width in pixels.
    static let width: Int = 320
    /// Synthetic image height in pixels.
    static let height: Int = 240
    /// Focal length in pixels (both axes).
    static let focal: Float = 200
    /// Principal point u in pixels.
    static let cx: Float = 160
    /// Principal point v in pixels.
    static let cy: Float = 120
    /// Center of the cube; every camera looks at it.
    static let cubeCenter = SIMD3<Float>(0, 0, -2)
    /// Half the cube's side length in meters.
    static let cubeHalf: Float = 0.5
    /// Triangles per cube side (2 x 2 quads, 2 triangles each).
    static let trianglesPerSide: Int = 8
    /// Checker cell size in meters.
    static let checker: Float = 0.1
    /// Checker offset in meters, keeps cube sides away from checker planes.
    static let checkerOffset: Float = 0.05

    /// Camera centers: front, right, left, back, top (keyframes 0 to 4).
    static let eyes: [SIMD3<Float>] = [
        SIMD3<Float>(0, 0.9, 0.6), SIMD3<Float>(2.4, 0.9, -2), SIMD3<Float>(-2.4, 0.9, -2),
        SIMD3<Float>(0, 0.9, -4.6), SIMD3<Float>(0.3, 2.8, -1.6)
    ]

    /// Expected keyframe for cube side d (+x, -x, +y, -y, +z, -z); -1 means nobody sees it.
    static let expectedKeyframeOfSide: [Int32] = [1, 2, 4, -1, 0, 3]

    /// Intrinsics as ARKit reports them: columns (fx, 0, 0), (0, fy, 0), (cx, cy, 1).
    static var intrinsics: simd_float3x3 {
        simd_float3x3(columns: (SIMD3<Float>(focal, 0, 0), SIMD3<Float>(0, focal, 0), SIMD3<Float>(cx, cy, 1)))
    }

    /// Image resolution the intrinsics refer to.
    static var resolution: SIMD2<Float> { SIMD2<Float>(Float(width), Float(height)) }

    /// Camera-to-world pose at `eye` looking at `target` (x right, y up, looking down -z).
    /// Uses world up (0, 1, 0), or (0, 0, -1) when the view is nearly vertical.
    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
        let forward: SIMD3<Float> = simd_normalize(target - eye)
        var right: SIMD3<Float> = simd_cross(forward, SIMD3<Float>(0, 1, 0))
        if simd_length(right) < 1e-6 {
            right = simd_cross(forward, SIMD3<Float>(0, 0, -1))
        }
        right = simd_normalize(right)
        let up: SIMD3<Float> = simd_cross(right, forward)
        return simd_float4x4(columns: (SIMD4<Float>(right, 0), SIMD4<Float>(up, 0),
                                       SIMD4<Float>(-forward, 0), SIMD4<Float>(eye, 1)))
    }

    /// A 320 x 240 test camera at `eye` looking at `target`.
    static func camera(eye: SIMD3<Float>, target: SIMD3<Float>) -> TXCamera {
        TXCamera(intrinsics: intrinsics, resolution: resolution, cameraToWorld: lookAt(eye: eye, target: target))
    }

    /// The five scene cameras, in keyframe order.
    static func sceneCameras() -> [TXCamera] {
        var result: [TXCamera] = []
        for eye in eyes { result.append(camera(eye: eye, target: cubeCenter)) }
        return result
    }

    // MARK: - Meshes

    /// Builds a mesh from grids, merging vertices that coincide (to 0.1 mm).
    struct MeshBuilder {
        /// Vertex positions so far.
        var positions: [SIMD3<Float>] = []
        /// Triangle indices so far.
        var indices: [UInt32] = []
        /// Index of each vertex by its rounded position.
        var lookup: [SIMD3<Int32>: UInt32] = [:]

        /// Index of the vertex at `p`, adding it when new.
        mutating func vertex(_ p: SIMD3<Float>) -> UInt32 {
            let key = SIMD3<Int32>(Int32((p.x * 10000).rounded()), Int32((p.y * 10000).rounded()),
                                   Int32((p.z * 10000).rounded()))
            if let existing = lookup[key] { return existing }
            let index = UInt32(positions.count)
            positions.append(p)
            lookup[key] = index
            return index
        }

        /// Adds an nu x nv grid of quads spanning `du` and `dv` from `origin`, 2 triangles per
        /// quad, normal along cross(du, dv) (same order as the prototype).
        mutating func addGrid(origin: SIMD3<Float>, du: SIMD3<Float>, dv: SIMD3<Float>, nu: Int, nv: Int) {
            for i in 0..<nu {
                for j in 0..<nv {
                    let a = vertex(point(origin, du, dv, i, j, nu, nv))
                    let b = vertex(point(origin, du, dv, i + 1, j, nu, nv))
                    let c = vertex(point(origin, du, dv, i + 1, j + 1, nu, nv))
                    let d = vertex(point(origin, du, dv, i, j + 1, nu, nv))
                    indices.append(contentsOf: [a, b, c, a, c, d])
                }
            }
        }

        /// Grid point (i, j) of an nu x nv grid.
        private func point(_ origin: SIMD3<Float>, _ du: SIMD3<Float>, _ dv: SIMD3<Float>,
                           _ i: Int, _ j: Int, _ nu: Int, _ nv: Int) -> SIMD3<Float> {
            let fu: Float = Float(i) / Float(nu)
            let fv: Float = Float(j) / Float(nv)
            let alongU: SIMD3<Float> = du * fu
            let alongV: SIMD3<Float> = dv * fv
            return origin + alongU + alongV
        }

        /// Adds the cube's six sides (+x, -x, +y, -y, +z, -z), each split 2 x 2, facing outward.
        mutating func addCube() {
            let c: SIMD3<Float> = TXTestScenes.cubeCenter
            let h: Float = TXTestScenes.cubeHalf
            let s: Float = 2 * h
            let x = SIMD3<Float>(1, 0, 0), y = SIMD3<Float>(0, 1, 0), z = SIMD3<Float>(0, 0, 1)
            let minusX: SIMD3<Float> = SIMD3<Float>(-1, 0, 0)
            let minusZ: SIMD3<Float> = SIMD3<Float>(0, 0, -1)
            let n: Float = -h
            // Corner, du and dv of each side, in the order +x, -x, +y, -y, +z, -z.
            let corners: [SIMD3<Float>] = [SIMD3<Float>(h, n, h), SIMD3<Float>(n, n, n), SIMD3<Float>(n, h, h),
                                           SIMD3<Float>(n, n, n), SIMD3<Float>(n, n, h), SIMD3<Float>(h, n, n)]
            let dus: [SIMD3<Float>] = [minusZ, z, x, x, x, minusX]
            let dvs: [SIMD3<Float>] = [y, y, minusZ, z, y, y]
            for side in 0..<corners.count {
                let origin: SIMD3<Float> = c + corners[side]
                let du: SIMD3<Float> = dus[side] * s
                let dv: SIMD3<Float> = dvs[side] * s
                addGrid(origin: origin, du: du, dv: dv, nu: 2, nv: 2)
            }
        }

        /// The mesh built so far.
        var mesh: TXMesh { TXMesh(positions: positions, indices: indices) }
    }

    /// The closed cube alone (48 triangles).
    static func cubeMesh() -> TXMesh {
        var builder = MeshBuilder()
        builder.addCube()
        return builder.mesh
    }

    /// Cube (faces 0..<48) plus the floor at y = -0.5 (faces 48..<176, normal +y).
    static func cubeAndFloorMesh() -> TXMesh {
        var builder = MeshBuilder()
        builder.addCube()
        builder.addGrid(origin: SIMD3<Float>(-2, -0.5, 0.5), du: SIMD3<Float>(4, 0, 0),
                        dv: SIMD3<Float>(0, 0, -5), nu: 8, nv: 8)
        return builder.mesh
    }

    /// A 0.4 m quad at z = -1.5 (faces 0 and 1) in front of a 2 x 2 m quad at z = -2.5 split
    /// 10 x 10 (faces 2..<202), both facing +z.
    static func occlusionMesh() -> TXMesh {
        var builder = MeshBuilder()
        builder.addGrid(origin: SIMD3<Float>(-0.2, -0.2, -1.5), du: SIMD3<Float>(0.4, 0, 0),
                        dv: SIMD3<Float>(0, 0.4, 0), nu: 1, nv: 1)
        builder.addGrid(origin: SIMD3<Float>(-1, -1, -2.5), du: SIMD3<Float>(2, 0, 0),
                        dv: SIMD3<Float>(0, 2, 0), nu: 10, nv: 10)
        return builder.mesh
    }

    /// A strip of 4 quads (8 equal triangles) in the plane z = -2.
    static func stripMesh() -> TXMesh {
        var builder = MeshBuilder()
        builder.addGrid(origin: SIMD3<Float>(-2, -0.5, -2), du: SIMD3<Float>(4, 0, 0),
                        dv: SIMD3<Float>(0, 1, 0), nu: 4, nv: 1)
        return builder.mesh
    }

    // MARK: - Ground truth

    /// Tint of a surface by its (axis aligned) normal direction; white for anything else.
    static func tint(_ n: SIMD3<Float>) -> SIMD3<Float> {
        let r = SIMD3<Int>(Int(n.x.rounded()), Int(n.y.rounded()), Int(n.z.rounded()))
        if r == SIMD3<Int>(1, 0, 0) { return SIMD3<Float>(1, 0.6, 0.6) }
        if r == SIMD3<Int>(-1, 0, 0) { return SIMD3<Float>(0.6, 1, 1) }
        if r == SIMD3<Int>(0, 1, 0) { return SIMD3<Float>(0.6, 1, 0.6) }
        if r == SIMD3<Int>(0, -1, 0) { return SIMD3<Float>(1, 0.6, 1) }
        if r == SIMD3<Int>(0, 0, 1) { return SIMD3<Float>(0.6, 0.6, 1) }
        if r == SIMD3<Int>(0, 0, -1) { return SIMD3<Float>(1, 1, 0.6) }
        return SIMD3<Float>(1, 1, 1)
    }

    /// Ground-truth color (0...255) of surface point `p` with unit normal `n`.
    static func groundTruth(_ p: SIMD3<Float>, _ n: SIMD3<Float>) -> SIMD3<Float> {
        let q: SIMD3<Float> = (p + SIMD3<Float>(repeating: checkerOffset)) / checker
        let sum: Int = Int(q.x.rounded(.down)) + Int(q.y.rounded(.down)) + Int(q.z.rounded(.down))
        let base: Float = (sum & 1) == 1 ? 220 : 50
        return tint(n) * base
    }

    /// Distance in meters, within the plane of a face with normal `n`, from `p` to the nearest
    /// checker line (the axis along the normal is ignored).
    static func checkerLineDistance(_ p: SIMD3<Float>, _ n: SIMD3<Float>) -> Float {
        let a = simd_abs(n)
        let normalAxis: Int = (a.x >= a.y && a.x >= a.z) ? 0 : (a.y >= a.z ? 1 : 2)
        var best = Float.infinity
        for axis in 0..<3 where axis != normalAxis {
            let q: Float = (p[axis] + checkerOffset) / checker
            best = min(best, abs(q - q.rounded()) * checker)
        }
        return best
    }

    /// Distance in meters, within the plane of a cube side with normal `n`, from `p` to the
    /// nearest cube edge.
    static func cubeEdgeDistance(_ p: SIMD3<Float>, _ n: SIMD3<Float>) -> Float {
        let a = simd_abs(n)
        let normalAxis: Int = (a.x >= a.y && a.x >= a.z) ? 0 : (a.y >= a.z ? 1 : 2)
        let local: SIMD3<Float> = p - cubeCenter
        var best = Float.infinity
        for axis in 0..<3 where axis != normalAxis {
            best = min(best, cubeHalf - abs(local[axis]))
        }
        return best
    }

    // MARK: - Rendering

    /// Renders `mesh` from `camera` by ray casting every pixel center: each triangle is tested
    /// only inside its projected bounding box (the whole image when a corner is behind the
    /// camera), with an exact ray-plane hit and an inside test; the nearest hit is colored by
    /// `groundTruth` times `gain`. Background is black. Both windings are drawn.
    static func render(mesh: TXMesh, camera: TXCamera, gain: Float = 1) -> TXRGBImage {
        let w = Int(camera.width), h = Int(camera.height)
        var image = TXRGBImage(width: w, height: h)
        if w <= 0 || h <= 0 { return image }
        let origin: SIMD3<Float> = camera.position
        var directions = [SIMD3<Float>](repeating: .zero, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let pixel = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                directions[y * w + x] = camera.unproject(pixel, depth: 1) - origin
            }
        }
        var best = [Float](repeating: Float.infinity, count: w * h)
        var owner = [Int](repeating: -1, count: w * h)
        var normals = [SIMD3<Float>](repeating: .zero, count: mesh.faceCount)
        for f in 0..<mesh.faceCount {
            guard let corners = mesh.corners(f) else { continue }
            let (a, b, c) = corners
            let n: SIMD3<Float> = simd_cross(b - a, c - a)
            let len: Float = simd_length(n)
            if len < 1e-12 { continue }
            normals[f] = n / len
            var x0 = 0, x1 = w, y0 = 0, y1 = h
            if let pa = camera.project(a), let pb = camera.project(b), let pc = camera.project(c) {
                let lo = simd_min(simd_min(pa, pb), pc), hi = simd_max(simd_max(pa, pb), pc)
                x0 = Int(min(max(lo.x - 1, 0), Float(w)))
                x1 = Int(min(max(hi.x + 2, 0), Float(w)))
                y0 = Int(min(max(lo.y - 1, 0), Float(h)))
                y1 = Int(min(max(hi.y + 2, 0), Float(h)))
            }
            if x0 >= x1 || y0 >= y1 { continue }
            let eps: Float = -1e-7 * len * len
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = y * w + x
                    let d = directions[i]
                    let denom: Float = simd_dot(n, d)
                    if abs(denom) < 1e-12 { continue }
                    let t: Float = simd_dot(n, a - origin) / denom
                    if !(t > TXCamera.nearDepth) || t >= best[i] { continue }
                    let p: SIMD3<Float> = origin + d * t
                    if simd_dot(simd_cross(b - a, p - a), n) < eps { continue }
                    if simd_dot(simd_cross(c - b, p - b), n) < eps { continue }
                    if simd_dot(simd_cross(a - c, p - c), n) < eps { continue }
                    best[i] = t
                    owner[i] = f
                }
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let f = owner[i]
                if f < 0 { continue }
                let p: SIMD3<Float> = origin + directions[i] * best[i]
                image.setPixel(x, y, groundTruth(p, normals[f]) * gain)
            }
        }
        return image
    }

    /// A copy of `image` with every channel multiplied by `gain`.
    static func scaled(_ image: TXRGBImage, gain: Float) -> TXRGBImage {
        var copy = image
        for y in 0..<image.height {
            for x in 0..<image.width {
                copy.setPixel(x, y, image.pixel(x, y) * gain)
            }
        }
        return copy
    }

    /// A keyframe from a rendered image and its camera; nil when the CGImage cannot be made.
    static func keyframe(image: TXRGBImage, camera: TXCamera, timestamp: Double) -> TXKeyframe? {
        guard let cg = image.makeCGImage() else { return nil }
        return TXKeyframe(image: cg, intrinsics: intrinsics, imageResolution: resolution,
                          cameraToWorld: camera.cameraToWorld, timestamp: timestamp, exposureOffset: nil)
    }

    // MARK: - Helpers

    /// Camera-to-world pose rotated by `degrees` about +y and translated by `t`.
    static func pose(yawDegrees degrees: Float, translation t: SIMD3<Float>) -> simd_float4x4 {
        let r: Float = degrees * Float.pi / 180
        let c: Float = cos(r), s: Float = sin(r)
        return simd_float4x4(columns: (SIMD4<Float>(c, 0, -s, 0), SIMD4<Float>(0, 1, 0, 0),
                                       SIMD4<Float>(s, 0, c, 0), SIMD4<Float>(t, 1)))
    }

    /// Number of pairs of rectangles in the same atlas that overlap (interiors intersect).
    static func overlappingPairs(sizes: [SIMD2<Int>], placements: [TXPlacement]) -> Int {
        var count = 0
        let n = min(sizes.count, placements.count)
        for i in 0..<n {
            for j in (i + 1)..<max(i + 1, n) {
                let a = placements[i], b = placements[j]
                if a.atlas != b.atlas { continue }
                if a.x < b.x + sizes[j].x && b.x < a.x + sizes[i].x
                    && a.y < b.y + sizes[j].y && b.y < a.y + sizes[i].y {
                    count += 1
                }
            }
        }
        return count
    }

    /// Number of atlas texel centers lying strictly inside (0.01 texel inset) the texcoord
    /// triangles of two different faces; 0 means no two textured faces share atlas space.
    /// `sizes[a]` is the (width, height) of atlas a.
    static func texelClashes(result: TXResult, sizes: [SIMD2<Int>]) -> Int {
        var owners: [[Int32]] = []
        for size in sizes { owners.append([Int32](repeating: -1, count: max(0, size.x * size.y))) }
        var clashes = 0
        let faceCount = min(result.faceSource.count, result.faceAtlas.count, result.texcoords.count / 3)
        for f in 0..<faceCount where result.faceSource[f] >= 0 {
            let a = Int(result.faceAtlas[f])
            if a >= sizes.count { continue }
            let size = SIMD2<Float>(Float(sizes[a].x), Float(sizes[a].y))
            var t: [SIMD2<Float>] = []
            for k in 0..<3 {
                let uv = result.texcoords[3 * f + k]
                t.append(SIMD2<Float>(uv.x * size.x, (1 - uv.y) * size.y))
            }
            let area: Float = (t[1].x - t[0].x) * (t[2].y - t[0].y) - (t[1].y - t[0].y) * (t[2].x - t[0].x)
            if abs(area) < 1e-9 { continue }
            let sign: Float = area > 0 ? 1 : -1
            let lo = simd_min(simd_min(t[0], t[1]), t[2]), hi = simd_max(simd_max(t[0], t[1]), t[2])
            if !(lo.x.isFinite && lo.y.isFinite && hi.x.isFinite && hi.y.isFinite) { continue }
            let x0 = Int(max(0, lo.x)), x1 = Int(min(size.x, hi.x + 1))
            let y0 = Int(max(0, lo.y)), y1 = Int(min(size.y, hi.y + 1))
            if x0 >= x1 || y0 >= y1 { continue }
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let p = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                    var inside = true
                    for k in 0..<3 {
                        let e0 = t[k], e1 = t[(k + 1) % 3]
                        let edge = e1 - e0
                        let len: Float = max(simd_length(edge), 1e-9)
                        let dist: Float = sign * (edge.x * (p.y - e0.y) - edge.y * (p.x - e0.x)) / len
                        if dist < 0.01 { inside = false }
                    }
                    if !inside { continue }
                    let i = y * sizes[a].x + x
                    if owners[a][i] >= 0 && owners[a][i] != Int32(f) { clashes += 1 }
                    owners[a][i] = Int32(f)
                }
            }
        }
        return clashes
    }

    /// Color errors (largest channel difference, 0...255) at up to `count` pseudo-random points on the cube's
    /// textured sides (bottom excluded), each at least 0.025 m from checker lines and 0.05 m
    /// from cube edges. Each point's texcoord is the barycentric blend of its face's texcoords;
    /// the atlas is sampled bilinearly (v flipped back to rows) and compared with `groundTruth`.
    static func colorErrors(result: TXResult, mesh: TXMesh, geometry: TXFaceGeometry, count: Int) -> [Float] {
        var atlases: [TXRGBImage?] = []
        for image in result.atlases { atlases.append(TXRGBImage(image: image)) }
        var sideFaces: [Int] = []
        for f in 0..<min(48, mesh.faceCount) where f / trianglesPerSide != 3 { sideFaces.append(f) }
        var rng = TXTestRandom(seed: 20260928)
        var errors: [Float] = []
        var attempts = 0
        while errors.count < count && attempts < 50_000 && !sideFaces.isEmpty {
            attempts += 1
            let f: Int = sideFaces[min(sideFaces.count - 1, Int(rng.next() * Float(sideFaces.count)))]
            var r1: Float = rng.next()
            var r2: Float = rng.next()
            if r1 + r2 > 1 {
                r1 = 1 - r1
                r2 = 1 - r2
            }
            let r0: Float = 1 - r1 - r2
            guard f < result.faceSource.count, result.faceSource[f] >= 0, 3 * f + 2 < result.texcoords.count,
                  f < result.faceAtlas.count, f < geometry.normals.count, let t = mesh.corners(f) else { continue }
            let p: SIMD3<Float> = t.0 * r0 + t.1 * r1 + t.2 * r2
            let n: SIMD3<Float> = geometry.normals[f]
            if checkerLineDistance(p, n) < 0.025 || cubeEdgeDistance(p, n) < 0.05 { continue }
            let a = Int(result.faceAtlas[f])
            guard a < atlases.count, let atlas = atlases[a] else { continue }
            let uv0: SIMD2<Float> = result.texcoords[3 * f] * r0
            let uv1: SIMD2<Float> = result.texcoords[3 * f + 1] * r1
            let uv2: SIMD2<Float> = result.texcoords[3 * f + 2] * r2
            let uv: SIMD2<Float> = uv0 + uv1 + uv2
            let texel = SIMD2<Float>(uv.x * Float(atlas.width), (1 - uv.y) * Float(atlas.height))
            let diff: SIMD3<Float> = simd_abs(atlas.sample(texel) - groundTruth(p, n))
            errors.append(max(diff.x, max(diff.y, diff.z)))
        }
        return errors
    }
}

/// Deterministic 64-bit linear congruential generator for repeatable test points.
struct TXTestRandom {
    /// Current state.
    var state: UInt64

    /// A generator starting from `seed`.
    init(seed: UInt64) { state = seed }

    /// Next value in 0..<1 (24 bits of precision).
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(state >> 40) / Float(1 << 24)
    }
}
