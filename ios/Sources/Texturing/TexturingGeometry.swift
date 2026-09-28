import Foundation
import simd

/// Pinhole projection of one keyframe, in pixels of a chosen image size.
///
/// Verified convention (docs/research/raw/texturing.json, "Forward projection of a world point
/// into an ARFrame image", checked against Apple's "Displaying a Point Cloud Using Scene
/// Depth" sample: Shaders.metal `worldPoint` = localToWorld * (intrinsicsInversed * (u, v, 1)
/// * depth) with Renderer.swift `localToWorld = viewMatrixInversed * flipYZ`,
/// `flipYZ = diag(1, -1, -1, 1)`, landscape-right = zero rotation, texCoord = pixel /
/// cameraResolution with no flip). Inverting that chain:
///
///     cam   = inverse(cameraToWorld) * (p, 1)     // ARKit camera: x right, y up, looks down -z
///     depth = -cam.z                              // must be > 0 (in front of the camera)
///     u     = fx * cam.x / depth + cx             // pixels, origin top-left, along the long axis
///     v     = fy * (-cam.y) / depth + cy          // pixels, v grows downward (note the minus)
///
/// `u, v` are continuous coordinates of `capturedImage` in its native landscape-right
/// orientation (row 0 = top), with pixel `i` centered at `i + 0.5`.
struct TXCamera {
    /// Points closer than this (meters) are treated as behind the camera.
    static let nearDepth: Float = 0.01

    /// Focal length along u, pixels.
    var fx: Float
    /// Focal length along v, pixels.
    var fy: Float
    /// Principal point u, pixels.
    var cx: Float
    /// Principal point v, pixels.
    var cy: Float
    /// Image width in pixels that the intrinsics refer to.
    var width: Float
    /// Image height in pixels that the intrinsics refer to.
    var height: Float
    /// Camera-to-world transform.
    var cameraToWorld: simd_float4x4
    /// World-to-camera transform (inverse of `cameraToWorld`).
    var worldToCamera: simd_float4x4

    /// Creates a camera from ARKit-style column-major intrinsics for `resolution`.
    init(intrinsics: simd_float3x3, resolution: SIMD2<Float>, cameraToWorld: simd_float4x4) {
        fx = intrinsics[0][0]
        fy = intrinsics[1][1]
        cx = intrinsics[2][0]
        cy = intrinsics[2][1]
        width = resolution.x
        height = resolution.y
        self.cameraToWorld = cameraToWorld
        worldToCamera = cameraToWorld.inverse
    }

    /// Camera for a keyframe, rescaled to the pixel size of `keyframe.image`.
    init(keyframe: TXKeyframe) {
        self.init(intrinsics: keyframe.intrinsics, resolution: keyframe.imageResolution,
                  cameraToWorld: keyframe.cameraToWorld)
        self = resized(width: Float(keyframe.image.width), height: Float(keyframe.image.height))
    }

    /// The same camera for an image of another size with the same aspect ratio.
    func resized(width newWidth: Float, height newHeight: Float) -> TXCamera {
        var copy = self
        let sx = width > 0 ? newWidth / width : 1
        let sy = height > 0 ? newHeight / height : 1
        copy.fx = fx * sx
        copy.cx = cx * sx
        copy.fy = fy * sy
        copy.cy = cy * sy
        copy.width = newWidth
        copy.height = newHeight
        return copy
    }

    /// Camera center in world space.
    var position: SIMD3<Float> {
        let t = cameraToWorld.columns.3
        return SIMD3<Float>(t.x, t.y, t.z)
    }

    /// Unit viewing direction in world space (the camera's -z axis).
    var forward: SIMD3<Float> {
        let z = cameraToWorld.columns.2
        return -simd_normalize(SIMD3<Float>(z.x, z.y, z.z))
    }

    /// World point in camera space.
    func cameraPoint(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let c = worldToCamera * SIMD4<Float>(p, 1)
        return SIMD3<Float>(c.x, c.y, c.z)
    }

    /// Projects a world point to (u, v, depth); nil when it is not in front of the camera.
    func project(_ p: SIMD3<Float>) -> SIMD3<Float>? {
        let c = cameraPoint(p)
        let depth = -c.z
        guard depth > TXCamera.nearDepth else { return nil }
        return SIMD3<Float>(fx * c.x / depth + cx, fy * -c.y / depth + cy, depth)
    }

    /// World point at pixel (u, v) and the given depth (meters along -z).
    func unproject(_ pixel: SIMD2<Float>, depth: Float) -> SIMD3<Float> {
        let x = (pixel.x - cx) / fx * depth
        let y = -(pixel.y - cy) / fy * depth
        let w = cameraToWorld * SIMD4<Float>(x, y, -depth, 1)
        return SIMD3<Float>(w.x, w.y, w.z)
    }

    /// True when pixel (u, v) lies inside the image, at least `margin` pixels from the edges.
    func contains(_ pixel: SIMD2<Float>, margin: Float = 0) -> Bool {
        pixel.x >= margin && pixel.y >= margin && pixel.x <= width - margin && pixel.y <= height - margin
    }
}

/// Per-face normals, centroids and areas, computed once per bake.
struct TXFaceGeometry {
    /// Unit normal of each face (counter-clockwise winding), zero for degenerate faces.
    var normals: [SIMD3<Float>]
    /// Centroid of each face.
    var centroids: [SIMD3<Float>]
    /// Area of each face in square meters (0 for degenerate or invalid faces).
    var areas: [Float]

    /// Computes normals, centroids and areas for every face of `mesh`.
    init(mesh: TXMesh) {
        let n = mesh.faceCount
        normals = [SIMD3<Float>](repeating: .zero, count: n)
        centroids = [SIMD3<Float>](repeating: .zero, count: n)
        areas = [Float](repeating: 0, count: n)
        for f in 0..<n {
            guard let corners = mesh.corners(f) else { continue }
            let (a, b, c) = corners
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            centroids[f] = (a + b + c) / 3
            areas[f] = length * 0.5
            if length > 1e-12 { normals[f] = cross / length }
        }
    }

    /// Sum of all face areas.
    var totalArea: Float { areas.reduce(0, +) }
}

/// Face adjacency over shared edges (CSR layout). Faces sharing an edge through a
/// non-manifold edge are all connected to each other.
struct TXAdjacency {
    /// Neighbors of face `f` are `neighbors[offsets[f] ..< offsets[f + 1]]`.
    var offsets: [Int32]
    /// All neighbor lists, grouped by face.
    var neighbors: [Int32]

    /// Builds adjacency by sorting edge keys (memory: 16 bytes per face corner, temporary).
    init(mesh: TXMesh) {
        let faceCount = mesh.faceCount
        var edges: [(key: UInt64, face: Int32)] = []
        edges.reserveCapacity(faceCount * 3)
        for f in 0..<faceCount {
            for k in 0..<3 {
                let a = mesh.indices[3 * f + k], b = mesh.indices[3 * f + (k + 1) % 3]
                if a == b { continue }
                let key = (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
                edges.append((key, Int32(f)))
            }
        }
        edges.sort { $0.key < $1.key }
        var pairs: [(Int32, Int32)] = []
        var start = 0
        while start < edges.count {
            var end = start + 1
            while end < edges.count && edges[end].key == edges[start].key { end += 1 }
            if end - start > 1 {
                for p in start..<end {
                    for q in (p + 1)..<end where edges[p].face != edges[q].face {
                        pairs.append((edges[p].face, edges[q].face))
                        pairs.append((edges[q].face, edges[p].face))
                    }
                }
            }
            start = end
        }
        var counts = [Int32](repeating: 0, count: faceCount + 1)
        for (a, _) in pairs { counts[Int(a) + 1] += 1 }
        for f in 0..<faceCount { counts[f + 1] += counts[f] }
        var fill = counts
        var list = [Int32](repeating: 0, count: pairs.count)
        for (a, b) in pairs {
            list[Int(fill[Int(a)])] = b
            fill[Int(a)] += 1
        }
        offsets = counts
        neighbors = list
    }

    /// Neighbors of face `f`.
    func neighbors(of f: Int) -> ArraySlice<Int32> {
        neighbors[Int(offsets[f]) ..< Int(offsets[f + 1])]
    }
}
