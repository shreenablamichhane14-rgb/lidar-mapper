import Foundation
import simd

/// Groups faces that share a keyframe into charts and lays each chart out in 2D.
///
/// A chart is a connected set of faces (over shared edges) textured from the same keyframe.
/// Because every face of a chart is seen from one camera, its layout is simply the faces'
/// projections into that keyframe's image, scaled from image pixels to texels by one uniform
/// factor (`texelsPerPixel`) and shifted so the bounding box starts at the gutter. No
/// unwrapping is needed.
///
/// Scale policy (documented choice):
/// 1. While a chart grows, its texel box is tested with a FIXED growth scale taken from the
///    seed face alone: `texelsPerMeter / seedPixelsPerMeter`. A fixed scale keeps the
///    "does the box still fit" test monotone and cheap, since the final scale is not known
///    until the chart is complete.
/// 2. When growth stops, the final scale is `texelsPerMeter / (area-weighted mean
///    pixelsPerMeter of all faces)`, so the chart as a whole hits the target density.
/// 3. If the final scale would make the box larger than `maxChartSize` (either because the
///    area-weighted scale is larger than the seed's, or because the seed face alone is too big),
///    the scale is reduced so the box fits. Such charts get a slightly lower density than the
///    target; all others get exactly the target on average.
///
/// Guarantees for every chart returned by `build` and `rescaled`: `width` and `height` are at
/// least `1 + 2 * gutter`; every corner texel lies in `[gutter, width - gutter]` x
/// `[gutter, height - gutter]`; `build` never returns a chart wider or taller than
/// `maxChartSize` (when `maxChartSize >= 1 + 2 * gutter`).
enum TXChartBuilder {
    /// Smallest world area (square meters) treated as a real triangle.
    private static let minArea: Float = 1e-12
    /// Fallback texels per pixel when no density can be measured for a chart.
    private static let fallbackTexelsPerPixel: Float = 1
    /// Safety factor applied when the scale is clamped to fit, so rounding up never overflows.
    private static let clampSafety: Float = 0.999

    /// Flood fill over shared edges of faces with the same faceSource (>= 0) into charts.
    /// Each chart: pixel coords of its corners via cameras[keyframe].project; chart scale
    /// texelsPerPixel = texelsPerMeter / (area-weighted mean pixelsPerMeter of its faces, from
    /// visibility.candidate(forFace:keyframe:), falling back to projected-area/world-area),
    /// cornerTexels = (pixel - pixelOrigin) * texelsPerPixel + gutter, width/height =
    /// ceil(extent * scale) + 2 * gutter (at least 1 + 2 * gutter).
    /// A chart grows only while its texel bounding box stays <= maxChartSize on both axes; a face
    /// that would overflow is left for a new chart. If a single face alone exceeds maxChartSize,
    /// that chart's texelsPerPixel is reduced to fit. Faces whose corners fail to project get
    /// faceSource -1 in `faceSource` (inout). Charts come out in order of their lowest face
    /// index (deterministic), faces within a chart in breadth-first order.
    static func build(mesh: TXMesh, faceSource: inout [Int32], adjacency: TXAdjacency, cameras: [TXCamera],
                      visibility: TXVisibility, geometry: TXFaceGeometry,
                      texelsPerMeter: Float, maxChartSize: Int) -> [TXChart] {
        let faceCount: Int = min(mesh.faceCount, faceSource.count)
        if faceCount == 0 { return [] }
        let gutter: Int = TXChart.gutter
        // Largest texel extent inside the gutters (never below 1 texel).
        let inner: Int = max(1, maxChartSize - 2 * gutter)
        let innerF: Float = Float(inner)

        // Pass 1: project every textured face into its keyframe; drop faces that fail.
        var pixels = [SIMD2<Float>](repeating: SIMD2<Float>(0, 0), count: 3 * faceCount)
        var density = [Float](repeating: 0, count: faceCount)
        for f in 0..<faceCount {
            let k: Int = Int(faceSource[f])
            if k < 0 { continue }
            guard k < cameras.count, let projected = projectFace(mesh: mesh, face: f, camera: cameras[k]) else {
                faceSource[f] = -1
                continue
            }
            pixels[3 * f] = projected.0
            pixels[3 * f + 1] = projected.1
            pixels[3 * f + 2] = projected.2
            density[f] = pixelsPerMeter(face: f, keyframe: faceSource[f], a: projected.0, b: projected.1,
                                        c: projected.2, visibility: visibility, geometry: geometry)
        }

        // Pass 2: breadth-first flood fill. `owner` marks faces already in a chart; `rejectedBy`
        // remembers which chart already refused a face so it is not retested for that chart.
        var owner = [Int32](repeating: -1, count: faceCount)
        var rejectedBy = [Int32](repeating: -1, count: faceCount)
        var charts: [TXChart] = []
        var queue: [Int32] = []
        var members: [Int32] = []

        for seed in 0..<faceCount {
            let key: Int32 = faceSource[seed]
            if key < 0 || owner[seed] >= 0 { continue }
            let chartId: Int32 = Int32(charts.count)
            let growthScale: Float = seedScale(texelsPerMeter: texelsPerMeter, pixelsPerMeter: density[seed])

            var minP: SIMD2<Float> = faceMin(pixels, seed)
            var maxP: SIMD2<Float> = faceMax(pixels, seed)
            owner[seed] = chartId
            queue.removeAll(keepingCapacity: true)
            members.removeAll(keepingCapacity: true)
            queue.append(Int32(seed))
            var head: Int = 0

            while head < queue.count {
                let face: Int = Int(queue[head])
                head += 1
                members.append(Int32(face))
                for neighbor32 in adjacency.neighbors(of: face) {
                    let n: Int = Int(neighbor32)
                    if n < 0 || n >= faceCount { continue }
                    if owner[n] >= 0 || rejectedBy[n] == chartId || faceSource[n] != key { continue }
                    let newMin: SIMD2<Float> = simd_min(minP, faceMin(pixels, n))
                    let newMax: SIMD2<Float> = simd_max(maxP, faceMax(pixels, n))
                    let extent: SIMD2<Float> = (newMax - newMin) * growthScale
                    if extent.x <= innerF && extent.y <= innerF {
                        minP = newMin
                        maxP = newMax
                        owner[n] = chartId
                        queue.append(Int32(n))
                    } else {
                        rejectedBy[n] = chartId
                    }
                }
            }

            let chart: TXChart = makeChart(keyframe: key, faces: members, pixels: pixels, density: density,
                                           geometry: geometry, minP: minP, maxP: maxP,
                                           texelsPerMeter: texelsPerMeter, growthScale: growthScale,
                                           innerLimit: innerF)
            charts.append(chart)
        }
        return charts
    }

    /// Same charts at `factor` times the resolution (factor < 1 shrinks): texelsPerPixel and
    /// cornerTexels scaled around the gutter, width/height recomputed. A factor that is not a
    /// positive finite number returns the charts unchanged.
    static func rescaled(_ charts: [TXChart], factor: Float) -> [TXChart] {
        guard factor.isFinite && factor > 0 else { return charts }
        let g: Float = Float(TXChart.gutter)
        var result: [TXChart] = []
        result.reserveCapacity(charts.count)
        for chart in charts {
            var copy: TXChart = chart
            copy.texelsPerPixel = chart.texelsPerPixel * factor
            var corners = [SIMD2<Float>](repeating: SIMD2<Float>(g, g), count: chart.cornerTexels.count)
            var innerMax = SIMD2<Float>(0, 0)
            for i in 0..<chart.cornerTexels.count {
                let local: SIMD2<Float> = simd_max(chart.cornerTexels[i] - SIMD2<Float>(g, g), SIMD2<Float>(0, 0))
                let scaled: SIMD2<Float> = local * factor
                innerMax = simd_max(innerMax, scaled)
                corners[i] = scaled + SIMD2<Float>(g, g)
            }
            let size: SIMD2<Int> = rectSize(innerExtent: innerMax)
            copy.cornerTexels = clampCorners(corners, size: size)
            copy.width = size.x
            copy.height = size.y
            result.append(copy)
        }
        return result
    }

    // MARK: - Helpers

    /// Projects the 3 corners of face `face`; nil if any corner is behind the camera, the face
    /// has an invalid index, or a coordinate is not finite.
    private static func projectFace(mesh: TXMesh, face: Int,
                                    camera: TXCamera) -> (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)? {
        guard let corners = mesh.corners(face) else { return nil }
        guard let pa = camera.project(corners.0),
              let pb = camera.project(corners.1),
              let pc = camera.project(corners.2) else { return nil }
        let a = SIMD2<Float>(pa.x, pa.y)
        let b = SIMD2<Float>(pb.x, pb.y)
        let c = SIMD2<Float>(pc.x, pc.y)
        guard isFinite(a) && isFinite(b) && isFinite(c) else { return nil }
        return (a, b, c)
    }

    /// True when both components are finite.
    private static func isFinite(_ p: SIMD2<Float>) -> Bool {
        p.x.isFinite && p.y.isFinite
    }

    /// Keyframe pixels per meter on face `face`: the visibility candidate's value when present
    /// and positive, else the square root of projected pixel area over world area; 0 when
    /// neither can be measured (degenerate face).
    private static func pixelsPerMeter(face: Int, keyframe: Int32, a: SIMD2<Float>, b: SIMD2<Float>,
                                       c: SIMD2<Float>, visibility: TXVisibility,
                                       geometry: TXFaceGeometry) -> Float {
        if visibility.offsets.count > face + 1 {
            if let candidate = visibility.candidate(forFace: face, keyframe: keyframe) {
                let value: Float = candidate.pixelsPerMeter
                if value.isFinite && value > 0 { return value }
            }
        }
        guard face < geometry.areas.count else { return 0 }
        let worldArea: Float = geometry.areas[face]
        guard worldArea > minArea else { return 0 }
        let e1: SIMD2<Float> = b - a
        let e2: SIMD2<Float> = c - a
        let pixelArea: Float = abs(e1.x * e2.y - e1.y * e2.x) * 0.5
        let value: Float = (pixelArea / worldArea).squareRoot()
        return value.isFinite ? value : 0
    }

    /// Texels per pixel for a density in pixels per meter, or the fallback when either number
    /// is not usable.
    private static func seedScale(texelsPerMeter: Float, pixelsPerMeter: Float) -> Float {
        guard texelsPerMeter.isFinite && texelsPerMeter > 0 else { return fallbackTexelsPerPixel }
        guard pixelsPerMeter.isFinite && pixelsPerMeter > 0 else { return fallbackTexelsPerPixel }
        let scale: Float = texelsPerMeter / pixelsPerMeter
        return (scale.isFinite && scale > 0) ? scale : fallbackTexelsPerPixel
    }

    /// Component-wise minimum of face `f`'s 3 projected corners.
    private static func faceMin(_ pixels: [SIMD2<Float>], _ f: Int) -> SIMD2<Float> {
        simd_min(simd_min(pixels[3 * f], pixels[3 * f + 1]), pixels[3 * f + 2])
    }

    /// Component-wise maximum of face `f`'s 3 projected corners.
    private static func faceMax(_ pixels: [SIMD2<Float>], _ f: Int) -> SIMD2<Float> {
        simd_max(simd_max(pixels[3 * f], pixels[3 * f + 1]), pixels[3 * f + 2])
    }

    /// Builds the finished chart: final area-weighted scale (clamped to fit `innerLimit`
    /// texels inside the gutters), corner texels and rectangle size.
    private static func makeChart(keyframe: Int32, faces: [Int32], pixels: [SIMD2<Float>], density: [Float],
                                  geometry: TXFaceGeometry, minP: SIMD2<Float>, maxP: SIMD2<Float>,
                                  texelsPerMeter: Float, growthScale: Float, innerLimit: Float) -> TXChart {
        // Area-weighted mean density over faces with a measurable density.
        var weightedSum: Float = 0
        var areaSum: Float = 0
        for face32 in faces {
            let f: Int = Int(face32)
            let d: Float = density[f]
            let area: Float = f < geometry.areas.count ? geometry.areas[f] : 0
            if d > 0 && area > minArea {
                weightedSum += d * area
                areaSum += area
            }
        }
        var scale: Float = growthScale
        if areaSum > 0 {
            scale = seedScale(texelsPerMeter: texelsPerMeter, pixelsPerMeter: weightedSum / areaSum)
        }

        // Clamp so the box fits inside the limit on both axes.
        let extent: SIMD2<Float> = maxP - minP
        let longest: Float = max(extent.x, extent.y)
        if longest > 0 && longest * scale > innerLimit {
            scale = innerLimit * clampSafety / longest
        }
        if !(scale.isFinite && scale > 0) { scale = fallbackTexelsPerPixel }

        let g = SIMD2<Float>(Float(TXChart.gutter), Float(TXChart.gutter))
        var corners = [SIMD2<Float>](repeating: g, count: 3 * faces.count)
        var innerMax = SIMD2<Float>(0, 0)
        for i in 0..<faces.count {
            let f: Int = Int(faces[i])
            for j in 0..<3 {
                let local: SIMD2<Float> = simd_max((pixels[3 * f + j] - minP) * scale, SIMD2<Float>(0, 0))
                innerMax = simd_max(innerMax, local)
                corners[3 * i + j] = local + g
            }
        }
        var size: SIMD2<Int> = rectSize(innerExtent: innerMax)
        // Rounding can never push past the limit after the safety factor, but make sure.
        let maxSide: Int = Int(innerLimit) + 2 * TXChart.gutter
        size = SIMD2<Int>(min(size.x, maxSide), min(size.y, maxSide))

        return TXChart(keyframe: keyframe, faces: faces, cornerTexels: clampCorners(corners, size: size),
                       pixelOrigin: minP, texelsPerPixel: scale, width: size.x, height: size.y)
    }

    /// Rectangle size for an inner texel extent: ceil(extent), at least 1, plus both gutters.
    private static func rectSize(innerExtent: SIMD2<Float>) -> SIMD2<Int> {
        let g: Int = TXChart.gutter
        return SIMD2<Int>(ceilToInt(innerExtent.x) + 2 * g, ceilToInt(innerExtent.y) + 2 * g)
    }

    /// Rounds up to an Int of at least 1; non-finite or huge values give 1 or a large cap.
    private static func ceilToInt(_ v: Float) -> Int {
        guard v.isFinite && v > 0 else { return 1 }
        let capped: Float = min(v.rounded(.up), 1_000_000_000)
        return max(1, Int(capped))
    }

    /// Clamps every corner into `[gutter, size - gutter]` on both axes.
    private static func clampCorners(_ corners: [SIMD2<Float>], size: SIMD2<Int>) -> [SIMD2<Float>] {
        let g: Float = Float(TXChart.gutter)
        let lower = SIMD2<Float>(g, g)
        let upper = SIMD2<Float>(Float(size.x) - g, Float(size.y) - g)
        var out: [SIMD2<Float>] = corners
        for i in 0..<out.count {
            out[i] = simd_min(simd_max(out[i], lower), upper)
        }
        return out
    }
}
