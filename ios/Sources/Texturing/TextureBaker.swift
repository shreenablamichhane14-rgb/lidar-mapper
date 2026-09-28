import CoreGraphics
import Foundation
import simd

/// Bakes a texture atlas for a mesh from a set of keyframes, on the CPU.
///
/// Pipeline (one stage per file): validate, face geometry and adjacency, cameras, visibility
/// (Visibility.swift), luma thumbnails for sharpness and exposure (TexturingImage.swift,
/// ViewSelection.swift, Exposure.swift), view selection, charts (Charts.swift), atlas packing
/// (AtlasPacking.swift), then baking atlas by atlas (Baking.swift) and texture coordinates.
///
/// Usage: call `bake` on a background thread; `cancel()` may be called from any thread and
/// makes `bake` throw `TXError.cancelled` at the next check (between stages, between
/// keyframes during visibility, and between charts during baking). One baker runs one bake at
/// a time; a cancelled baker stays cancelled, so create a new one for the next bake.
///
/// Progress is reported on the calling thread, monotonic in 0...1: visibility 0...0.35, luma
/// thumbnails 0.35...0.45, view selection, charts and packing 0.45...0.55, baking 0.55...1.
///
/// Peak memory estimate for 1M triangles (about 500k vertices) and 300 keyframes of
/// 1920 x 1440, default options (4096 atlases, up to 8). SIMD3<Float> has a 16 byte stride.
/// - Mesh arrays (held by the caller and shared copy-on-write): positions 500k x 16 B = 8 MB,
///   indices 3M x 4 B = 12 MB. Total 20 MB.
/// - TXFaceGeometry: normals 16 MB, centroids 16 MB, areas 4 MB. Total 36 MB.
/// - TXAdjacency: temporary edge list 3M x 16 B = 48 MB plus pair list about 3M x 8 B = 24 MB
///   while building (freed afterwards), final CSR about 16 MB.
/// - Visibility: working slots 12 B x 6 x 1M = 72 MB plus the final CSR 72 MB + 4 MB offsets,
///   so about 150 MB at the end of that stage and 76 MB after it. Depth buffer 256 x 192 x 4 B
///   and per-vertex projections (500k x 16 B = 8 MB) are per keyframe and reused.
/// - Luma thumbnails: 320 x 240 x 4 B (Float) x 300 = 92 MB, freed once gains and sharpness
///   weights are computed (they live only inside `computeWeightsAndGains`).
/// - Charts: corner texels 3 x 8 B x 1M = 24 MB, face lists 4 MB; faceSource and chartOfFace
///   4 MB each; texcoords 3 x 8 B x 1M = 24 MB; faceAtlas 2 MB.
/// - Image cache: 3 x 1920 x 1440 x 4 B = 33 MB (plus one transient decode, 11 MB).
/// - One atlas being baked: 4096 x 4096 x 4 B = 64 MB bitmap plus a 16 MB coverage mask, and a
///   transient 64 MB copy while `makeCGImage` wraps it in a CGImage.
/// - Finished atlases as CGImages: 64 MB each, up to 8 = 512 MB.
/// Peak is while baking the last atlas: about 20 + 36 + 16 + 76 + 62 + 33 + 80 + 64 + 7 x 64
/// = roughly 830 MB. Finished atlases are the dominant cost; writing each one to disk (PNG or
/// KTX) right after it is baked and returning file URLs would cut the peak to about 400 MB.
///
/// Estimated CPU time on an A15, single threaded (estimates, not measured): visibility about
/// 100 ms per keyframe for 1M triangles (z-buffer rasterization plus per-face tests), so about
/// 30 s for 300 keyframes; thumbnails about 5 to 15 ms each, 2 to 5 s; selection, charts and
/// packing 2 to 4 s; baking 8 x 16M texels at about 50 ns per texel is about 7 s plus keyframe
/// decodes (15 ms each, repeated per atlas for keyframes spanning atlases), 5 to 35 s. Total
/// roughly 45 to 90 s. Visibility is the first stage worth moving to Metal.
final class TextureBaker {
    /// Options for every bake of this baker.
    let options: TXOptions
    /// Guards `cancelRequested`.
    private let lock = NSLock()
    /// Set by `cancel()`; read through `isCancelled`.
    private var cancelRequested: Bool = false
    /// Highest progress value reported so far in the current bake (keeps progress monotonic).
    private var lastProgress: Float = 0

    /// Width of the luma thumbnails used for sharpness and exposure statistics.
    static let lumaThumbnailWidth: Int = 320
    /// End of the visibility progress range.
    static let visibilityEnd: Float = 0.35
    /// End of the luma thumbnail progress range.
    static let lumaEnd: Float = 0.45
    /// End of the selection, charts and packing progress range.
    static let layoutEnd: Float = 0.55

    /// Creates a baker with the given options.
    init(options: TXOptions = TXOptions()) {
        self.options = options
    }

    /// Requests cancellation. Thread safe; `bake` throws `TXError.cancelled` at its next check.
    func cancel() {
        lock.lock()
        cancelRequested = true
        lock.unlock()
    }

    /// True once `cancel()` has been called. Thread safe.
    var isCancelled: Bool {
        lock.lock()
        let value = cancelRequested
        lock.unlock()
        return value
    }

    /// Throws `TXError.cancelled` when cancellation was requested.
    private func checkCancelled() throws {
        if isCancelled { throw TXError.cancelled }
    }

    /// Reports `value` clamped to 0...1 and never below the last reported value.
    private func report(_ value: Float, _ progress: ((Float) -> Void)?) {
        guard let progress = progress else { return }
        let clamped: Float = value.isFinite ? min(1, max(0, value)) : lastProgress
        let monotonic: Float = max(lastProgress, clamped)
        lastProgress = monotonic
        progress(monotonic)
    }

    /// Bakes atlases and per-corner texture coordinates for `mesh` from `keyframes`.
    ///
    /// Throws `TXError.invalidMesh` when the mesh has no triangles or an index is out of range,
    /// `TXError.noKeyframes` when `keyframes` is empty, `TXError.cancelled` after `cancel()`,
    /// and `TXError.imageFailed` when an atlas bitmap cannot become a CGImage or when the charts
    /// cannot be packed into `options.maxAtlases` atlases even after 12 shrink steps (this only
    /// happens with a single chart larger than the atlas or absurd options; the baker throws
    /// rather than silently returning an untextured result, so the caller can retry with a
    /// larger `maxAtlases` or lower `texelsPerMeter`).
    func bake(mesh: TXMesh, keyframes: [TXKeyframe], progress: ((Float) -> Void)?) throws -> TXResult {
        lastProgress = 0
        report(0, progress)

        // Validate.
        let faceCount: Int = mesh.faceCount
        guard faceCount > 0 else { throw TXError.invalidMesh("the mesh has no triangles") }
        let vertexCount: Int = mesh.positions.count
        for i in 0..<(faceCount * 3) where Int(mesh.indices[i]) >= vertexCount {
            throw TXError.invalidMesh("index \(mesh.indices[i]) at position \(i) is out of range (\(vertexCount) vertices)")
        }
        guard !keyframes.isEmpty else { throw TXError.noKeyframes }
        try checkCancelled()

        // Geometry, adjacency, cameras.
        let geometry = TXFaceGeometry(mesh: mesh)
        let adjacency = TXAdjacency(mesh: mesh)
        var cameras: [TXCamera] = []
        cameras.reserveCapacity(keyframes.count)
        for keyframe in keyframes { cameras.append(TXCamera(keyframe: keyframe)) }
        try checkCancelled()

        // Visibility (0 ... 0.35).
        let stop: () -> Bool = { [weak self] in self?.isCancelled ?? true }
        let visibility: TXVisibility = try TXVisibilityBuilder.compute(
            mesh: mesh, geometry: geometry, cameras: cameras, options: options, isCancelled: stop,
            progress: { [weak self] (fraction: Float) in
                self?.report(fraction * TextureBaker.visibilityEnd, progress)
            })
        report(TextureBaker.visibilityEnd, progress)
        try checkCancelled()

        // Luma thumbnails, sharpness weights and exposure gains (0.35 ... 0.45).
        let stats = try computeWeightsAndGains(keyframes: keyframes, visibility: visibility,
                                               geometry: geometry, cameras: cameras, progress: progress)
        report(TextureBaker.lumaEnd, progress)
        try checkCancelled()

        // View selection, charts, packing (0.45 ... 0.55).
        var faceSource: [Int32] = TXViewSelection.select(
            visibility: visibility, adjacency: adjacency, geometry: geometry, weights: stats.weights,
            targetPixelsPerMeter: options.texelsPerMeter)
        if faceSource.count != faceCount {
            faceSource = TextureBaker.resized(faceSource, count: faceCount)
        }
        report(TextureBaker.lumaEnd + 0.03, progress)
        try checkCancelled()

        let builtCharts: [TXChart] = TXChartBuilder.build(
            mesh: mesh, faceSource: &faceSource, adjacency: adjacency, cameras: cameras,
            visibility: visibility, geometry: geometry, texelsPerMeter: options.texelsPerMeter,
            maxChartSize: options.atlasSize)
        report(TextureBaker.lumaEnd + 0.07, progress)
        try checkCancelled()

        guard let packed = TXAtlasPacker.packCharts(builtCharts, atlasSize: options.atlasSize,
                                                    maxAtlases: options.maxAtlases) else {
            throw TXError.imageFailed("atlas packing: \(builtCharts.count) charts do not fit in \(options.maxAtlases) atlases of \(options.atlasSize) texels")
        }
        let charts: [TXChart] = packed.charts
        let packing: TXPacking = packed.packing
        report(TextureBaker.layoutEnd, progress)
        try checkCancelled()

        // Chart of every face (-1 when none); faces without a chart become untextured.
        var chartOfFace = [Int32](repeating: -1, count: faceCount)
        for c in 0..<charts.count {
            for face in charts[c].faces {
                let f = Int(face)
                if f >= 0 && f < faceCount { chartOfFace[f] = Int32(c) }
            }
        }
        for f in 0..<faceCount where chartOfFace[f] < 0 { faceSource[f] = -1 }

        // Bake atlas by atlas (0.55 ... 1); only one atlas bitmap is alive at a time.
        let atlasWidth: Int = options.atlasSize
        var heights: [Int] = []
        var atlases: [CGImage] = []
        let atlasCount: Int = packing.atlasCount
        let images = TXImageCache(keyframes: keyframes, capacity: 3)
        for a in 0..<atlasCount {
            try checkCancelled()
            let used: Int = a < packing.usedHeights.count ? packing.usedHeights[a] : options.atlasSize
            let height: Int = TXAtlasPacker.atlasHeight(usedHeight: used, atlasSize: options.atlasSize)
            heights.append(height)
            let cgImage: CGImage? = try autoreleasepool { () throws -> CGImage? in
                let bitmap: TXRGBImage = try TXAtlasBaker.bake(
                    atlasIndex: a, width: atlasWidth, height: height, mesh: mesh, charts: charts,
                    placements: packing.placements, chartOfFace: chartOfFace, adjacency: adjacency,
                    visibility: visibility, cameras: cameras, images: images, gains: stats.gains,
                    blendSeams: options.blendSeams, isCancelled: stop)
                return bitmap.makeCGImage()
            }
            guard let image = cgImage else {
                throw TXError.imageFailed("atlas \(a) (\(atlasWidth) x \(height)) could not become a CGImage")
            }
            atlases.append(image)
            let done: Float = Float(a + 1) / Float(max(1, atlasCount))
            report(TextureBaker.layoutEnd + (1 - TextureBaker.layoutEnd) * done, progress)
        }
        try checkCancelled()

        // Texture coordinates, bottom-left origin, v against the trimmed atlas height.
        var texcoords = [SIMD2<Float>](repeating: SIMD2<Float>(0, 0), count: faceCount * 3)
        var faceAtlas = [UInt16](repeating: 0, count: faceCount)
        let inverseWidth: Float = 1 / Float(max(1, atlasWidth))
        for c in 0..<charts.count where c < packing.placements.count {
            let chart: TXChart = charts[c]
            let placement: TXPlacement = packing.placements[c]
            guard placement.atlas >= 0, placement.atlas < heights.count else { continue }
            let inverseHeight: Float = 1 / Float(max(1, heights[placement.atlas]))
            let origin = SIMD2<Float>(Float(placement.x), Float(placement.y))
            for i in 0..<chart.faces.count {
                let f = Int(chart.faces[i])
                guard f >= 0, f < faceCount, chartOfFace[f] == Int32(c) else { continue }
                guard 3 * i + 2 < chart.cornerTexels.count else { continue }
                faceAtlas[f] = UInt16(clamping: placement.atlas)
                for k in 0..<3 {
                    let texel: SIMD2<Float> = origin + chart.cornerTexels[3 * i + k]
                    texcoords[3 * f + k] = SIMD2<Float>(texel.x * inverseWidth, 1 - texel.y * inverseHeight)
                }
            }
        }

        // Coverage: textured area over total area.
        var totalArea: Double = 0
        var texturedArea: Double = 0
        let areaCount: Int = min(faceCount, geometry.areas.count)
        for f in 0..<areaCount {
            let area = Double(geometry.areas[f])
            guard area.isFinite, area > 0 else { continue }
            totalArea += area
            if faceSource[f] >= 0 { texturedArea += area }
        }
        let coverage: Float = totalArea > 0 ? Float(min(1, max(0, texturedArea / totalArea))) : 0

        report(1, progress)
        return TXResult(texcoords: texcoords, faceAtlas: faceAtlas, atlases: atlases,
                        faceSource: faceSource, coverage: coverage)
    }

    /// Builds luma thumbnails one keyframe at a time, then returns per-keyframe sharpness
    /// weights and exposure gains (all 1 when `options.normalizeExposure` is false). The
    /// thumbnails are released when this function returns. Reports progress 0.35 ... 0.45.
    private func computeWeightsAndGains(keyframes: [TXKeyframe], visibility: TXVisibility,
                                        geometry: TXFaceGeometry, cameras: [TXCamera],
                                        progress: ((Float) -> Void)?) throws -> (weights: [Float], gains: [Float]) {
        let count: Int = keyframes.count
        var lumas: [TXLumaImage?] = []
        lumas.reserveCapacity(count)
        var sharpness: [Float] = []
        sharpness.reserveCapacity(count)
        let span: Float = TextureBaker.lumaEnd - TextureBaker.visibilityEnd
        for k in 0..<count {
            try checkCancelled()
            let luma: TXLumaImage? = autoreleasepool { () -> TXLumaImage? in
                TXLumaImage(image: keyframes[k].image, maxWidth: TextureBaker.lumaThumbnailWidth)
            }
            if let thumbnail = luma {
                sharpness.append(TXViewSelection.sharpness(of: thumbnail))
            } else {
                sharpness.append(0)
            }
            lumas.append(luma)
            let done: Float = Float(k + 1) / Float(max(1, count))
            report(TextureBaker.visibilityEnd + span * done, progress)
        }
        let weights: [Float] = TXViewSelection.sharpnessWeights(sharpness)
        try checkCancelled()
        var gains: [Float]
        if options.normalizeExposure {
            gains = TXExposure.solveGains(visibility: visibility, geometry: geometry, cameras: cameras,
                                          lumas: lumas)
        } else {
            gains = [Float](repeating: 1, count: count)
        }
        if gains.count != count {
            gains = [Float](repeating: 1, count: count)
        }
        return (weights: weights, gains: gains)
    }

    /// `values` truncated or padded with -1 to exactly `count` entries.
    private static func resized(_ values: [Int32], count: Int) -> [Int32] {
        var out = [Int32](repeating: -1, count: count)
        for i in 0..<min(count, values.count) { out[i] = values[i] }
        return out
    }
}
