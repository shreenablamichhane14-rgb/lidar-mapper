import CoreGraphics
import Foundation
import simd

/// Decoded keyframe images with a small least-recently-used cache, so at most `capacity`
/// full-resolution images are held by the cache at once (a caller may keep one more alive by
/// holding a returned copy). Images are decoded at the CGImage's own size.
///
/// Not thread safe: use one cache from one thread at a time (the baker's worker thread).
final class TXImageCache {
    /// Keyframes whose images are decoded on demand.
    private let keyframes: [TXKeyframe]
    /// Most decoded images kept at once (at least 1).
    let capacity: Int
    /// Cached images, least recently used first.
    private var entries: [(index: Int, image: TXRGBImage)] = []
    /// Number of decodes performed so far (useful for tests and logs).
    private(set) var decodeCount: Int = 0

    /// Creates an empty cache over `keyframes` holding at most `capacity` decoded images.
    init(keyframes: [TXKeyframe], capacity: Int = 3) {
        self.keyframes = keyframes
        self.capacity = max(1, capacity)
    }

    /// The decoded image of keyframe `index`, or nil when the index is out of range or the
    /// image cannot be decoded. Evicts the least recently used image before decoding a new one.
    func image(_ index: Int) -> TXRGBImage? {
        guard index >= 0, index < keyframes.count else { return nil }
        if let position = entries.firstIndex(where: { $0.index == index }) {
            let entry = entries.remove(at: position)
            entries.append(entry)
            return entry.image
        }
        while entries.count >= capacity { entries.removeFirst() }
        guard let decoded = TXRGBImage(image: keyframes[index].image) else { return nil }
        decodeCount += 1
        entries.append((index: index, image: decoded))
        return decoded
    }
}

/// A half-open texel rectangle `[x0, x1) x [y0, y1)` in an atlas.
fileprivate struct TXTexelRect {
    /// Left edge (inclusive).
    var x0: Int
    /// Top edge (inclusive).
    var y0: Int
    /// Right edge (exclusive).
    var x1: Int
    /// Bottom edge (exclusive).
    var y1: Int
    /// True when the rectangle holds no texel.
    var isEmpty: Bool { x1 <= x0 || y1 <= y0 }
}

/// One chart face in atlas texel coordinates with its edge functions.
fileprivate struct TXTexelTriangle {
    /// Corner 0 in atlas texels.
    let t0: SIMD2<Float>
    /// Corner 1 in atlas texels.
    let t1: SIMD2<Float>
    /// Corner 2 in atlas texels.
    let t2: SIMD2<Float>
    /// Twice the signed area (sign follows the winding).
    let area2: Float
    /// Height of the triangle at each corner: barycentric weight times this is the signed
    /// distance in texels to the edge opposite that corner (positive inside).
    let heights: SIMD3<Float>

    /// A triangle from three atlas-space corners; nil when degenerate or not finite.
    init?(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) {
        let limit: Float = 1e7
        for p in [a, b, c] {
            guard p.x.isFinite, p.y.isFinite, abs(p.x) < limit, abs(p.y) < limit else { return nil }
        }
        let area: Float = TXTexelTriangle.cross(b - a, c - a)
        guard abs(area) > 1e-6 else { return nil }
        t0 = a
        t1 = b
        t2 = c
        area2 = area
        let magnitude: Float = abs(area)
        heights = SIMD3<Float>(magnitude / max(simd_length(c - b), 1e-12),
                               magnitude / max(simd_length(a - c), 1e-12),
                               magnitude / max(simd_length(b - a), 1e-12))
    }

    /// 2D cross product (z of the 3D cross).
    static func cross(_ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Float {
        u.x * v.y - u.y * v.x
    }

    /// Corner `k` (0, 1 or 2).
    func corner(_ k: Int) -> SIMD2<Float> {
        k == 0 ? t0 : (k == 1 ? t1 : t2)
    }

    /// Barycentric weights of `p` (unclamped; all >= 0 inside).
    func weights(_ p: SIMD2<Float>) -> SIMD3<Float> {
        let w0: Float = TXTexelTriangle.cross(t2 - t1, p - t1)
        let w1: Float = TXTexelTriangle.cross(t0 - t2, p - t2)
        let w2: Float = TXTexelTriangle.cross(t1 - t0, p - t0)
        return SIMD3<Float>(w0, w1, w2) / area2
    }

    /// Texels whose centers may lie within one texel of the triangle, clipped to `rect`.
    func bounds(within rect: TXTexelRect) -> TXTexelRect {
        let low = simd_min(simd_min(t0, t1), t2)
        let high = simd_max(simd_max(t0, t1), t2)
        return TXTexelRect(x0: max(rect.x0, Int((low.x - 1).rounded(.down))),
                           y0: max(rect.y0, Int((low.y - 1).rounded(.down))),
                           x1: min(rect.x1, Int((high.x + 1).rounded(.up))),
                           y1: min(rect.y1, Int((high.y + 1).rounded(.up))))
    }
}

/// A chart face edge that borders a chart textured from another keyframe.
fileprivate struct TXSeamEdge {
    /// Position of the face in the chart's `faces`.
    let slot: Int
    /// Edge index: edge k joins corners k and (k + 1) % 3.
    let edge: Int
    /// Keyframe of the neighbouring chart.
    let keyframe: Int32
}

/// Fills one atlas bitmap from the keyframe images.
struct TXAtlasBaker {
    /// Width in texels of the seam blending band on each side of a chart border.
    static let blendWidth: Float = 4
    /// Conservative rasterization: texels whose center is within this many texels outside a
    /// triangle are filled too (unless another face already covers them).
    static let rasterExpansion: Float = 0.5
    /// Byte value of atlas texels that no chart covers (mid-grey).
    static let background: UInt8 = 128
    /// Coverage state: texel written by the 0.5 texel expansion of a triangle.
    private static let coverageExpanded: UInt8 = 1
    /// Coverage state: texel center inside a triangle.
    private static let coverageInterior: UInt8 = 2
    /// Coverage flag: texel already seam blended.
    private static let blendedFlag: UInt8 = 0x80
    /// Mask of the coverage state bits (0 = empty, 1 expanded, 2 interior, 3 + pass dilated).
    private static let stateMask: UInt8 = 0x7F

    /// Bakes one atlas (width x height texels). `charts` are all charts, `placements` their
    /// placements; only charts with placement.atlas == atlasIndex are drawn. For each chart's
    /// faces: rasterizes the triangle in atlas texel space (texel centers, 0.5 texel expansion),
    /// maps each texel to a keyframe pixel perspective correctly (barycentric weights in chart
    /// texel space, 3D point from the face's world corners, cameras[k].project; the chart's
    /// affine map is only an approximation under perspective), bilinear samples images.image(k)
    /// and multiplies by gains[k]. Texels whose point does not project stay unfilled.
    /// Seam blending (if enabled): texels within blendWidth texels of a chart-boundary edge
    /// (neighbour face in a different chart with a different keyframe that also sees this
    /// face) are blended with the neighbour keyframe's
    /// sample of the same 3D point, weight 0.5 * (1 - d / blendWidth). Then dilates:
    /// gutter + 1 passes averaging filled 8-neighbours into empty texels inside each chart's
    /// rectangle. Texels never filled stay mid-grey (128). Charts whose image fails to decode
    /// are skipped (left grey). Checks isCancelled per chart and throws TXError.cancelled.
    /// Charts are processed grouped by keyframe so the image cache rarely decodes twice.
    static func bake(atlasIndex: Int, width: Int, height: Int, mesh: TXMesh, charts: [TXChart],
                     placements: [TXPlacement], chartOfFace: [Int32], adjacency: TXAdjacency,
                     visibility: TXVisibility, cameras: [TXCamera], images: TXImageCache,
                     gains: [Float], blendSeams: Bool, isCancelled: () -> Bool) throws -> TXRGBImage {
        var atlas = TXRGBImage(width: width, height: height)
        let w: Int = atlas.width
        let h: Int = atlas.height
        if w == 0 || h == 0 { return atlas }
        atlas.pixels = [UInt8](repeating: background, count: w * h * 4)
        var coverage = [UInt8](repeating: 0, count: w * h)

        let chartCount: Int = min(charts.count, placements.count)
        var order: [Int] = []
        for c in 0..<chartCount where placements[c].atlas == atlasIndex { order.append(c) }
        order.sort { (a: Int, b: Int) -> Bool in
            if charts[a].keyframe != charts[b].keyframe { return charts[a].keyframe < charts[b].keyframe }
            return a < b
        }

        for c in order {
            if isCancelled() { throw TXError.cancelled }
            let chart = charts[c]
            let k = Int(chart.keyframe)
            guard k >= 0, k < cameras.count, chart.texelsPerPixel > 0,
                  chart.texelsPerPixel.isFinite else { continue }
            guard let image = images.image(k) else { continue }
            let placement = placements[c]
            let rect = TXAtlasBaker.chartRect(of: chart, at: placement, width: w, height: h)
            if rect.isEmpty { continue }
            let offset = SIMD2<Float>(Float(placement.x), Float(placement.y))
            fillChart(chart, rect: rect, offset: offset, mesh: mesh, camera: cameras[k], image: image,
                      gain: TXAtlasBaker.gain(k, gains), atlas: &atlas, coverage: &coverage)
            if blendSeams {
                let seams = seamEdges(chart, chartIndex: c, mesh: mesh, charts: charts,
                                      chartOfFace: chartOfFace, adjacency: adjacency, visibility: visibility)
                if !seams.isEmpty {
                    blendChart(chart, seams: seams, rect: rect, offset: offset, mesh: mesh, cameras: cameras,
                               images: images, gains: gains, atlas: &atlas, coverage: &coverage)
                }
            }
        }
        if isCancelled() { throw TXError.cancelled }

        var rects: [TXTexelRect] = []
        for c in order {
            let rect = TXAtlasBaker.chartRect(of: charts[c], at: placements[c], width: w, height: h)
            if !rect.isEmpty { rects.append(rect) }
        }
        dilate(rects: rects, atlas: &atlas, coverage: &coverage)
        return atlas
    }

    /// The chart's rectangle in the atlas, clipped to the atlas bounds.
    private static func chartRect(of chart: TXChart, at placement: TXPlacement, width: Int, height: Int) -> TXTexelRect {
        TXTexelRect(x0: max(0, placement.x), y0: max(0, placement.y),
                    x1: min(width, placement.x + chart.width), y1: min(height, placement.y + chart.height))
    }

    /// Gain of keyframe `k`, 1 when missing or invalid.
    private static func gain(_ k: Int, _ gains: [Float]) -> Float {
        guard k >= 0, k < gains.count, gains[k].isFinite, gains[k] > 0 else { return 1 }
        return gains[k]
    }

    /// Face `slot` of `chart` as an atlas-space triangle, nil if missing or degenerate.
    private static func triangle(_ chart: TXChart, slot: Int, offset: SIMD2<Float>) -> TXTexelTriangle? {
        let base: Int = 3 * slot
        guard slot >= 0, base + 2 < chart.cornerTexels.count else { return nil }
        return TXTexelTriangle(chart.cornerTexels[base] + offset, chart.cornerTexels[base + 1] + offset,
                               chart.cornerTexels[base + 2] + offset)
    }

    /// Rasterizes every face of one chart and samples its keyframe image into the atlas.
    /// Interior texels always win over texels written by another face's expansion.
    /// Texel to pixel is perspective correct: the texel's barycentric weights (unclamped, so the
    /// 0.5 texel expansion extrapolates along the face plane) interpolate the face's world
    /// corners, and that 3D point is projected with `camera`.
    private static func fillChart(_ chart: TXChart, rect: TXTexelRect, offset: SIMD2<Float>, mesh: TXMesh,
                                  camera: TXCamera, image: TXRGBImage, gain: Float,
                                  atlas: inout TXRGBImage, coverage: inout [UInt8]) {
        let w: Int = atlas.width
        for slot in 0..<chart.faces.count {
            let face = Int(chart.faces[slot])
            guard face >= 0, face < mesh.faceCount,
                  let tri = triangle(chart, slot: slot, offset: offset),
                  let corners = mesh.corners(face) else { continue }
            let box = tri.bounds(within: rect)
            if box.isEmpty { continue }
            for y in box.y0..<box.y1 {
                for x in box.x0..<box.x1 {
                    let index: Int = y * w + x
                    let state: UInt8 = coverage[index] & stateMask
                    if state == coverageInterior { continue }
                    let p = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                    let weights = tri.weights(p)
                    let interior: Bool = min(min(weights.x, weights.y), weights.z) >= -1e-5
                    if !interior {
                        if state != 0 { continue }
                        let d = weights * tri.heights
                        if min(min(d.x, d.y), d.z) < -rasterExpansion { continue }
                    }
                    let world: SIMD3<Float> = corners.0 * weights.x + corners.1 * weights.y + corners.2 * weights.z
                    guard let projected = camera.project(world) else { continue }
                    let pixel = SIMD2<Float>(projected.x, projected.y)
                    atlas.setPixel(x, y, image.sample(pixel) * gain)
                    coverage[index] = interior ? coverageInterior : coverageExpanded
                }
            }
        }
    }

    /// True when face `face` of `mesh` uses both vertex indices `a` and `b`.
    private static func sharesEdge(_ mesh: TXMesh, face: Int, _ a: UInt32, _ b: UInt32) -> Bool {
        let i0 = mesh.indices[3 * face], i1 = mesh.indices[3 * face + 1], i2 = mesh.indices[3 * face + 2]
        let hasA: Bool = i0 == a || i1 == a || i2 == a
        let hasB: Bool = i0 == b || i1 == b || i2 == b
        return hasA && hasB
    }

    /// Edges of the chart's faces that border a chart from a different keyframe which also sees
    /// the face, sorted by that keyframe (then face slot, then edge) so each neighbour image is
    /// fetched once per chart.
    private static func seamEdges(_ chart: TXChart, chartIndex: Int, mesh: TXMesh, charts: [TXChart],
                                  chartOfFace: [Int32], adjacency: TXAdjacency,
                                  visibility: TXVisibility) -> [TXSeamEdge] {
        var result: [TXSeamEdge] = []
        let faceCount: Int = min(mesh.faceCount, adjacency.offsets.count - 1, visibility.offsets.count - 1)
        for slot in 0..<chart.faces.count {
            let f = Int(chart.faces[slot])
            guard f >= 0, f < faceCount else { continue }
            for e in 0..<3 {
                let a: UInt32 = mesh.indices[3 * f + e]
                let b: UInt32 = mesh.indices[3 * f + (e + 1) % 3]
                if a == b { continue }
                for neighbour in adjacency.neighbors(of: f) {
                    let nf = Int(neighbour)
                    guard nf >= 0, nf < mesh.faceCount, nf < chartOfFace.count else { continue }
                    let nc = Int(chartOfFace[nf])
                    guard nc >= 0, nc != chartIndex, nc < charts.count else { continue }
                    let nk: Int32 = charts[nc].keyframe
                    guard nk >= 0, nk != chart.keyframe else { continue }
                    guard sharesEdge(mesh, face: nf, a, b) else { continue }
                    guard visibility.candidate(forFace: f, keyframe: nk) != nil else { continue }
                    result.append(TXSeamEdge(slot: slot, edge: e, keyframe: nk))
                    break
                }
            }
        }
        result.sort { (l: TXSeamEdge, r: TXSeamEdge) -> Bool in
            if l.keyframe != r.keyframe { return l.keyframe < r.keyframe }
            if l.slot != r.slot { return l.slot < r.slot }
            return l.edge < r.edge
        }
        return result
    }

    /// Distance from `p` to the segment `a`-`b`.
    private static func segmentDistance(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let lengthSquared: Float = simd_dot(ab, ab)
        var t: Float = 0
        if lengthSquared > 1e-12 { t = min(max(simd_dot(p - a, ab) / lengthSquared, 0), 1) }
        return simd_length(p - (a + ab * t))
    }

    /// Blends texels near seam edges with the neighbouring keyframe's view of the same 3D point.
    /// Each texel is blended at most once (the first seam edge in keyframe order wins).
    private static func blendChart(_ chart: TXChart, seams: [TXSeamEdge], rect: TXTexelRect, offset: SIMD2<Float>,
                                   mesh: TXMesh, cameras: [TXCamera], images: TXImageCache, gains: [Float],
                                   atlas: inout TXRGBImage, coverage: inout [UInt8]) {
        let w: Int = atlas.width
        var currentKeyframe: Int32 = -1
        var neighbourImage: TXRGBImage? = nil
        for seam in seams {
            let nk = Int(seam.keyframe)
            guard nk >= 0, nk < cameras.count else { continue }
            if seam.keyframe != currentKeyframe {
                currentKeyframe = seam.keyframe
                neighbourImage = images.image(nk)
            }
            guard let other = neighbourImage else { continue }
            guard seam.slot < chart.faces.count,
                  let tri = triangle(chart, slot: seam.slot, offset: offset) else { continue }
            let face = Int(chart.faces[seam.slot])
            guard face >= 0, face < mesh.faceCount, let corners = mesh.corners(face) else { continue }
            let camera = cameras[nk]
            let neighbourGain: Float = gain(nk, gains)
            let a = tri.corner(seam.edge)
            let b = tri.corner((seam.edge + 1) % 3)
            let box = tri.bounds(within: rect)
            if box.isEmpty { continue }
            for y in box.y0..<box.y1 {
                for x in box.x0..<box.x1 {
                    let index: Int = y * w + x
                    let state: UInt8 = coverage[index]
                    if state & blendedFlag != 0 || state & stateMask == 0 { continue }
                    let p = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                    let weights = tri.weights(p)
                    let d = weights * tri.heights
                    if min(min(d.x, d.y), d.z) < -rasterExpansion { continue }
                    let distance: Float = segmentDistance(p, a, b)
                    if distance >= blendWidth { continue }
                    var bary = simd_max(weights, SIMD3<Float>(0, 0, 0))
                    let sum: Float = bary.x + bary.y + bary.z
                    bary = sum > 1e-12 ? bary / sum : SIMD3<Float>(1, 1, 1) / 3
                    let world: SIMD3<Float> = corners.0 * bary.x + corners.1 * bary.y + corners.2 * bary.z
                    guard let projected = camera.project(world) else { continue }
                    let pixel = SIMD2<Float>(projected.x, projected.y)
                    guard camera.contains(pixel) else { continue }
                    let weight: Float = 0.5 * (1 - distance / blendWidth)
                    let mine: SIMD3<Float> = atlas.pixel(x, y)
                    let theirs: SIMD3<Float> = other.sample(pixel) * neighbourGain
                    atlas.setPixel(x, y, mine * (1 - weight) + theirs * weight)
                    coverage[index] = state | blendedFlag
                }
            }
        }
    }

    /// gutter + 1 passes: each empty texel inside a chart rectangle with filled 8-neighbours
    /// (from earlier passes, inside the same rectangle) takes their average color.
    private static func dilate(rects: [TXTexelRect], atlas: inout TXRGBImage, coverage: inout [UInt8]) {
        let w: Int = atlas.width
        let passes: Int = TXChart.gutter + 1
        for pass in 1...passes {
            let mark = UInt8(2 + pass)
            for rect in rects {
                for y in rect.y0..<rect.y1 {
                    for x in rect.x0..<rect.x1 {
                        let index: Int = y * w + x
                        if coverage[index] & stateMask != 0 { continue }
                        var sum = SIMD3<Float>(0, 0, 0)
                        var count: Int = 0
                        for dy in -1...1 {
                            let ny: Int = y + dy
                            if ny < rect.y0 || ny >= rect.y1 { continue }
                            for dx in -1...1 {
                                let nx: Int = x + dx
                                if (dx == 0 && dy == 0) || nx < rect.x0 || nx >= rect.x1 { continue }
                                let s: UInt8 = coverage[ny * w + nx] & stateMask
                                if s == 0 || s == mark { continue }
                                sum += atlas.pixel(nx, ny)
                                count += 1
                            }
                        }
                        if count > 0 {
                            atlas.setPixel(x, y, sum / Float(count))
                            coverage[index] = mark
                        }
                    }
                }
            }
        }
    }
}
