import Foundation
import simd

// Which faces each keyframe sees. Occlusion uses a small CPU z-buffer per keyframe,
// rasterized from the mesh itself, so no ARKit depth maps are needed at bake time.

/// CPU z-buffer of one camera at reduced resolution, rasterized from the mesh.
///
/// Every triangle is drawn with a bounding-box edge-function rasterizer that samples at
/// pixel centers (`x + 0.5`, `y + 0.5`). Depth is perspective correct: `1 / depth` is
/// interpolated linearly in screen space and the stored value is `1 / interpolated`.
/// Both windings are drawn, so back faces occlude too.
///
/// Near plane: a triangle with any corner closer than `TXCamera.nearDepth` (or behind the
/// camera) is skipped instead of clipped. Such a triangle then cannot occlude anything, which
/// can only make a hidden point look visible, never the reverse. Scanned triangles are a few
/// centimeters wide, so this touches very few of them (mostly floor right under the phone).
struct TXDepthBuffer {
    /// Buffer width in pixels.
    let width: Int
    /// Buffer height in pixels.
    let height: Int
    /// Depth in meters along the camera's -z axis, +infinity where empty, row-major, row 0 at top.
    var depth: [Float]
    /// The camera resized to `width` x `height`.
    let camera: TXCamera

    /// Rasterizes every triangle of `mesh` seen from `camera` (any image size; it is resized
    /// here to `width` x `height`).
    init(mesh: TXMesh, camera: TXCamera, width: Int, height: Int) {
        let w: Int = max(1, width)
        let h: Int = max(1, height)
        self.width = w
        self.height = h
        let small: TXCamera = camera.resized(width: Float(w), height: Float(h))
        self.camera = small

        var buffer = [Float](repeating: Float.infinity, count: w * h)
        let positions: [SIMD3<Float>] = mesh.positions
        let indices: [UInt32] = mesh.indices
        let vertexCount: Int = positions.count

        // Screen x, screen y and 1 / depth per vertex; z = 0 marks a vertex not in front.
        var screen = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: vertexCount)
        for i in 0..<vertexCount {
            if let q = small.project(positions[i]) {
                screen[i] = SIMD3<Float>(q.x, q.y, 1 / q.z)
            }
        }

        let fw = Float(w)
        let fh = Float(h)
        let inside: Float = -1e-5
        for f in 0..<mesh.faceCount {
            let i0 = Int(indices[3 * f])
            let i1 = Int(indices[3 * f + 1])
            let i2 = Int(indices[3 * f + 2])
            if i0 >= vertexCount || i1 >= vertexCount || i2 >= vertexCount { continue }
            let a: SIMD3<Float> = screen[i0]
            let b: SIMD3<Float> = screen[i1]
            let c: SIMD3<Float> = screen[i2]
            if !(a.z > 0 && b.z > 0 && c.z > 0) { continue }

            // Early cull and clamped bounding box of the pixel centers covered.
            let minX: Float = min(a.x, min(b.x, c.x))
            let maxX: Float = max(a.x, max(b.x, c.x))
            let minY: Float = min(a.y, min(b.y, c.y))
            let maxY: Float = max(a.y, max(b.y, c.y))
            if !(maxX >= 0 && maxY >= 0 && minX <= fw && minY <= fh) { continue }
            let x0f: Float = max(0, (minX - 0.5).rounded(.up))
            let x1f: Float = min(fw - 1, (maxX - 0.5).rounded(.down))
            let y0f: Float = max(0, (minY - 0.5).rounded(.up))
            let y1f: Float = min(fh - 1, (maxY - 0.5).rounded(.down))
            if !(x0f <= x1f && y0f <= y1f) { continue }

            let area: Float = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            if !(abs(area) > 1e-12) { continue }
            let invArea: Float = 1 / area

            let x0 = Int(x0f)
            let x1 = Int(x1f)
            let y0 = Int(y0f)
            let y1 = Int(y1f)
            for y in y0...y1 {
                let py = Float(y) + 0.5
                let row = y * w
                for x in x0...x1 {
                    let px = Float(x) + 0.5
                    // Barycentric weights; dividing by the signed area accepts both windings.
                    let w0: Float = ((c.x - b.x) * (py - b.y) - (c.y - b.y) * (px - b.x)) * invArea
                    let w1: Float = ((a.x - c.x) * (py - c.y) - (a.y - c.y) * (px - c.x)) * invArea
                    let w2: Float = ((b.x - a.x) * (py - a.y) - (b.y - a.y) * (px - a.x)) * invArea
                    if w0 < inside || w1 < inside || w2 < inside { continue }
                    let invDepth: Float = w0 * a.z + w1 * b.z + w2 * c.z
                    if !(invDepth > 0) { continue }
                    let d: Float = 1 / invDepth
                    if d < buffer[row + x] { buffer[row + x] = d }
                }
            }
        }
        self.depth = buffer
    }

    /// Buffer cell holding pixel `p` of the original (unresized) camera image, or nil if outside.
    private func cell(atSourcePixel p: SIMD2<Float>, sourceCamera: TXCamera) -> SIMD2<Int>? {
        let sx: Float = sourceCamera.width > 0 ? Float(width) / sourceCamera.width : 1
        let sy: Float = sourceCamera.height > 0 ? Float(height) / sourceCamera.height : 1
        let qx: Float = p.x * sx
        let qy: Float = p.y * sy
        guard qx >= 0, qy >= 0, qx < Float(width), qy < Float(height) else { return nil }
        return SIMD2<Int>(min(width - 1, Int(qx)), min(height - 1, Int(qy)))
    }

    /// Nearest depth at a pixel of the ORIGINAL (unresized) camera image; +inf if outside.
    func depth(atSourcePixel p: SIMD2<Float>, sourceCamera: TXCamera) -> Float {
        guard let q = cell(atSourcePixel: p, sourceCamera: sourceCamera) else { return Float.infinity }
        let values: [Float] = self.depth
        return values[q.y * width + q.x]
    }

    /// True when world point p is not hidden: its depth <= buffer depth (3x3 min neighborhood) + tolerance.
    /// A point behind the camera or outside the image is reported as not visible.
    func isVisible(_ p: SIMD3<Float>, sourceCamera: TXCamera, tolerance: Float) -> Bool {
        guard let q = sourceCamera.project(p) else { return false }
        guard let center = cell(atSourcePixel: SIMD2<Float>(q.x, q.y), sourceCamera: sourceCamera) else {
            return false
        }
        let values: [Float] = self.depth
        var nearest = Float.infinity
        let yLow: Int = max(0, center.y - 1)
        let yHigh: Int = min(height - 1, center.y + 1)
        let xLow: Int = max(0, center.x - 1)
        let xHigh: Int = min(width - 1, center.x + 1)
        for y in yLow...yHigh {
            for x in xLow...xHigh {
                let d: Float = values[y * width + x]
                if d < nearest { nearest = d }
            }
        }
        return q.z <= nearest + tolerance
    }
}

/// Builds `TXVisibility`: for every face, the keyframes that see it well, best first.
///
/// Cost per keyframe is one pass over the vertices (projection) and two passes over the faces
/// (z-buffer and tests). Faces that fail the cheap frustum and angle tests, or that could not
/// enter the face's top list anyway, skip the occlusion test. Memory: one depth buffer at a
/// time plus `maxCandidatesPerFace` fixed slots per face (12 bytes each, 72 MB for 1M faces),
/// compacted in place into the CSR result at the end.
enum TXVisibilityBuilder {
    /// Depth buffer width in pixels.
    static let depthBufferWidth = 256
    /// Depth buffer height in pixels.
    static let depthBufferHeight = 192

    /// cameras[i] = TXCamera(keyframe: keyframes[i]) (image pixel size). Streams one depth buffer at a time.
    /// For each keyframe: frustum test (all 3 corners project in front and inside image with 1 px margin),
    /// back-face test and cosine (dot(normal, normalize(camPos - centroid)) >= options.minViewCosine),
    /// occlusion (centroid AND at least 2 of 3 corners pulled 5% toward centroid pass isVisible),
    /// pixelsPerMeter = sqrt(projected triangle pixel area / world area).
    /// Keeps per face the best maxCandidatesPerFace by cosine * pixelsPerMeter (ties keep the
    /// lower keyframe index). Candidates of a face are sorted best first.
    /// Calls isCancelled() between keyframes and throws TXError.cancelled; progress(0...1) per keyframe.
    static func compute(mesh: TXMesh, geometry: TXFaceGeometry, cameras: [TXCamera], options: TXOptions,
                        isCancelled: () -> Bool = { false }, progress: ((Float) -> Void)? = nil) throws -> TXVisibility {
        let faceCount: Int = mesh.faceCount
        let slotsPerFace: Int = TXVisibility.maxCandidatesPerFace
        let usable: Int = min(faceCount, geometry.normals.count, geometry.centroids.count, geometry.areas.count)
        let positions: [SIMD3<Float>] = mesh.positions
        let indices: [UInt32] = mesh.indices
        let vertexCount: Int = positions.count
        let tolerance: Float = options.occlusionTolerance
        let minCosine: Float = options.minViewCosine

        let empty = TXViewCandidate(keyframe: -1, cosine: 0, pixelsPerMeter: 0)
        var slots = [TXViewCandidate](repeating: empty, count: faceCount * slotsPerFace)
        var counts = [UInt8](repeating: 0, count: faceCount)
        var projected = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: vertexCount)
        var valid = [Bool](repeating: false, count: vertexCount)

        let cameraCount: Int = cameras.count
        for k in 0..<cameraCount {
            if isCancelled() { throw TXError.cancelled }
            let camera: TXCamera = cameras[k]
            let buffer = TXDepthBuffer(mesh: mesh, camera: camera,
                                       width: depthBufferWidth, height: depthBufferHeight)

            // Frustum test per vertex, at the keyframe image's own pixel size.
            for i in 0..<vertexCount {
                valid[i] = false
                if let q = camera.project(positions[i]), camera.contains(SIMD2<Float>(q.x, q.y), margin: 1) {
                    projected[i] = q
                    valid[i] = true
                }
            }

            let cameraPosition: SIMD3<Float> = camera.position
            let keyframe = Int32(k)
            for f in 0..<usable {
                let i0 = Int(indices[3 * f])
                let i1 = Int(indices[3 * f + 1])
                let i2 = Int(indices[3 * f + 2])
                if i0 >= vertexCount || i1 >= vertexCount || i2 >= vertexCount { continue }
                if !(valid[i0] && valid[i1] && valid[i2]) { continue }
                let worldArea: Float = geometry.areas[f]
                if !(worldArea > 0) { continue }

                // Back-face and view angle.
                let centroid: SIMD3<Float> = geometry.centroids[f]
                let toCamera: SIMD3<Float> = cameraPosition - centroid
                let distance: Float = simd_length(toCamera)
                if !(distance > 1e-6) { continue }
                let cosine: Float = simd_dot(geometry.normals[f], toCamera) / distance
                if !(cosine >= minCosine) { continue }

                // Image density.
                let a: SIMD3<Float> = projected[i0]
                let b: SIMD3<Float> = projected[i1]
                let c: SIMD3<Float> = projected[i2]
                let pixelArea: Float = 0.5 * abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x))
                if !(pixelArea > 0) { continue }
                let pixelsPerMeter: Float = (pixelArea / worldArea).squareRoot()
                let score: Float = cosine * pixelsPerMeter

                // Skip the occlusion test when the face's list is full of better views.
                let base: Int = f * slotsPerFace
                let count = Int(counts[f])
                if count == slotsPerFace {
                    let worst: TXViewCandidate = slots[base + slotsPerFace - 1]
                    if score <= worst.cosine * worst.pixelsPerMeter { continue }
                }

                // Occlusion: centroid and at least 2 of 3 slightly pulled-in corners.
                if !buffer.isVisible(centroid, sourceCamera: camera, tolerance: tolerance) { continue }
                let p0: SIMD3<Float> = positions[i0]
                let p1: SIMD3<Float> = positions[i1]
                let p2: SIMD3<Float> = positions[i2]
                var passed = 0
                if buffer.isVisible(p0 + (centroid - p0) * 0.05, sourceCamera: camera, tolerance: tolerance) {
                    passed += 1
                }
                if buffer.isVisible(p1 + (centroid - p1) * 0.05, sourceCamera: camera, tolerance: tolerance) {
                    passed += 1
                }
                if passed < 2 && buffer.isVisible(p2 + (centroid - p2) * 0.05, sourceCamera: camera,
                                                  tolerance: tolerance) {
                    passed += 1
                }
                if passed < 2 { continue }

                // Insertion into the face's sorted list (best first); the worst drops out when full.
                let candidate = TXViewCandidate(keyframe: keyframe, cosine: cosine, pixelsPerMeter: pixelsPerMeter)
                var position: Int
                if count < slotsPerFace {
                    position = count
                    counts[f] = UInt8(count + 1)
                } else {
                    position = slotsPerFace - 1
                }
                while position > 0 {
                    let previous: TXViewCandidate = slots[base + position - 1]
                    if previous.cosine * previous.pixelsPerMeter >= score { break }
                    slots[base + position] = previous
                    position -= 1
                }
                slots[base + position] = candidate
            }

            if let report = progress {
                report(Float(k + 1) / Float(cameraCount))
            }
        }

        // Compact the fixed slots into CSR in place (the write index never passes the read index).
        var offsets = [Int32](repeating: 0, count: faceCount + 1)
        var write = 0
        for f in 0..<faceCount {
            offsets[f] = Int32(write)
            let count = Int(counts[f])
            let base: Int = f * slotsPerFace
            var j = 0
            while j < count {
                slots[write] = slots[base + j]
                write += 1
                j += 1
            }
        }
        offsets[faceCount] = Int32(write)
        if slots.count > write {
            slots.removeLast(slots.count - write)
        }
        return TXVisibility(offsets: offsets, candidates: slots)
    }
}
