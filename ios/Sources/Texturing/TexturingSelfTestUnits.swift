import CoreGraphics
import Foundation
import simd

// Unit-level checks of TexturingSelfTest: packer, keyframe selector, sharpness, label
// smoothing and bake errors. Split from TexturingSelfTest.swift to keep files small.

/// Packer, keyframe selector, sharpness, smoothing and error checks of the texturing self-test.
extension TexturingSelfTest {
    // MARK: - Packer

    /// Skyline packer spill, failure cases and atlas trimming.
    static func checkPacker(_ c: inout TXTestChecks) {
        let five = [SIMD2<Int>](repeating: SIMD2<Int>(100, 100), count: 5)
        if let p = TXAtlasPacker.pack(sizes: five, atlasSize: 256, maxAtlases: 8) {
            c.expect("packer.fiveInto256.atlases", p.atlasCount == 2, "\(p.atlasCount) atlases")
            c.expect("packer.fiveInto256.usedHeights", p.usedHeights == [200, 100], "\(p.usedHeights)")
            c.expect("packer.fiveInto256.noOverlap", TXTestScenes.overlappingPairs(sizes: five, placements: p.placements) == 0)
        } else {
            c.expect("packer.fiveInto256", false, "returned nil")
        }
        c.expect("packer.maxAtlases1.nil", TXAtlasPacker.pack(sizes: five, atlasSize: 256, maxAtlases: 1) == nil)
        c.expect("packer.oversize.nil", TXAtlasPacker.pack(sizes: [SIMD2<Int>(300, 10)], atlasSize: 256, maxAtlases: 8) == nil)
        let h1: Int = TXAtlasPacker.atlasHeight(usedHeight: 435, atlasSize: 512)
        let h2: Int = TXAtlasPacker.atlasHeight(usedHeight: 100, atlasSize: 512)
        c.expect("packer.atlasHeight.435", h1 == 512, "\(h1)")
        c.expect("packer.atlasHeight.100", h2 == 128, "\(h2)")
    }

    // MARK: - Keyframe selector

    /// Acceptance, rejection reasons and thinning of `KeyframeSelector`.
    static func checkSelector(_ c: inout TXTestChecks) {
        var s = KeyframeSelector()
        let origin = SIMD3<Float>(0, 0, 0), moved = SIMD3<Float>(0.2, 0, 0)
        let d0 = s.consider(cameraToWorld: TXTestScenes.pose(yawDegrees: 0, translation: origin), timestamp: 0, exposureOffset: 0)
        c.expect("selector.firstAccepted", d0 == .accept, "\(d0)")
        let d1 = s.consider(cameraToWorld: TXTestScenes.pose(yawDegrees: 0, translation: origin), timestamp: 1, exposureOffset: 0)
        c.expect("selector.samePoseTooClose", d1 == .rejectTooClose, "\(d1)")
        let d2 = s.consider(cameraToWorld: TXTestScenes.pose(yawDegrees: 0, translation: moved), timestamp: 2, exposureOffset: 0)
        c.expect("selector.translationAccepted", d2 == .accept, "\(d2)")
        let d3 = s.consider(cameraToWorld: TXTestScenes.pose(yawDegrees: 15, translation: moved), timestamp: 3, exposureOffset: 0)
        c.expect("selector.rotationAccepted", d3 == .accept, "\(d3)")
        _ = s.consider(cameraToWorld: TXTestScenes.pose(yawDegrees: 15, translation: moved), timestamp: 4, exposureOffset: 0)
        let d4 = s.consider(cameraToWorld: TXTestScenes.pose(yawDegrees: 30, translation: moved), timestamp: 4.01, exposureOffset: 0)
        c.expect("selector.fastRotationBlur", d4 == .rejectBlur, "\(d4)")
        let d5 = s.consider(cameraToWorld: TXTestScenes.pose(yawDegrees: 30, translation: moved), timestamp: 5, exposureOffset: 3)
        c.expect("selector.exposure3EV", d5 == .rejectExposure, "\(d5)")
        let d6 = s.consider(cameraToWorld: TXTestScenes.pose(yawDegrees: 45, translation: moved), timestamp: 6, exposureOffset: 0)
        c.expect("selector.laterRotationAccepted", d6 == .accept, "\(d6)")
        let d7 = s.consider(cameraToWorld: TXTestScenes.pose(yawDegrees: 45, translation: SIMD3<Float>(1, 0, 0)),
                            timestamp: 6.05, exposureOffset: 0)
        c.expect("selector.tooSoon", d7 == .rejectTooSoon, "\(d7)")
        c.expect("selector.count", s.count == 4, "\(s.count)")

        var config = KeyframeSelector.Config()
        config.maxKeyframes = 3
        var t = KeyframeSelector(config: config)
        let xs: [Float] = [0, 0.2, 0.4, 0.6, 1.2]
        for (i, x) in xs.enumerated() {
            _ = t.consider(cameraToWorld: TXTestScenes.pose(yawDegrees: 0, translation: SIMD3<Float>(x, 0, 0)),
                           timestamp: Double(i), exposureOffset: nil)
        }
        c.expect("thinning.allAccepted", t.count == 5, "\(t.count)")
        let dropped: Int? = t.thinIfNeeded()
        c.expect("thinning.returnsIndex", dropped.map { $0 >= 1 && $0 <= 3 } ?? false, "\(String(describing: dropped))")
        c.expect("thinning.reducesCount", t.count == 4, "\(t.count)")
        _ = t.thinIfNeeded()
        c.expect("thinning.keepsFirstAndLast", t.count == 3 && t.keyframeTimestamps.first == 0 && t.keyframeTimestamps.last == 4,
                 "\(t.keyframeTimestamps)")
        c.expect("thinning.stopsAtMax", t.thinIfNeeded() == nil)
    }

    // MARK: - Sharpness and smoothing

    /// Sharpness of a flat image, weight range, and label smoothing on a hand-made strip.
    static func checkSharpnessAndSmoothing(_ c: inout TXTestChecks) {
        var flat = TXRGBImage(width: 64, height: 48)
        for y in 0..<48 { for x in 0..<64 { flat.setPixel(x, y, SIMD3<Float>(128, 128, 128)) } }
        if let cg = flat.makeCGImage(), let luma = TXLumaImage(image: cg) {
            let s: Float = TXViewSelection.sharpness(of: luma)
            c.expect("sharpness.flatIsZero", abs(s) < 1e-6, "\(s)")
        } else {
            c.expect("sharpness.flatIsZero", false, "could not make the flat image")
        }
        let w: [Float] = TXViewSelection.sharpnessWeights([10, 100, 50, 0.1, 400])
        c.expect("sharpness.weightsInRange", w.count == 5 && w.allSatisfy { $0 >= 0.5 && $0 <= 1 }, "\(w)")
        c.expect("sharpness.blurryGetsHalf", w.count == 5 && w[3] == 0.5 && w[4] == 1, "\(w)")

        let strip: TXMesh = TXTestScenes.stripMesh()
        let geometry = TXFaceGeometry(mesh: strip)
        let adjacency = TXAdjacency(mesh: strip)
        let special = 3
        var offsets: [Int32] = [0]
        var list: [TXViewCandidate] = []
        for f in 0..<strip.faceCount {
            list.append(TXViewCandidate(keyframe: 0, cosine: 1.0, pixelsPerMeter: 1000))
            list.append(TXViewCandidate(keyframe: 1, cosine: f == special ? 1.05 : 0.9, pixelsPerMeter: 1000))
            offsets.append(Int32(list.count))
        }
        let vis = TXVisibility(offsets: offsets, candidates: list)
        let ones = [Float](repeating: 1, count: 2)
        let raw = TXViewSelection.select(visibility: vis, adjacency: adjacency, geometry: geometry, weights: ones,
                                         targetPixelsPerMeter: 1, smoothness: 0.35, iterations: 0)
        c.expect("smoothing.rawPicksB", raw.count == strip.faceCount && raw[special] == 1, "\(raw)")
        let smooth = TXViewSelection.select(visibility: vis, adjacency: adjacency, geometry: geometry, weights: ones,
                                            targetPixelsPerMeter: 1)
        c.expect("smoothing.outlierBecomesA", smooth.count == strip.faceCount && smooth[special] == 0, "\(smooth)")
        c.expect("smoothing.allA", smooth.allSatisfy { $0 == 0 }, "\(smooth)")
    }

    // MARK: - Errors

    /// Invalid meshes, missing keyframes and cancellation make `bake` throw the right error.
    static func checkErrors(_ c: inout TXTestChecks, mesh: TXMesh, keyframes: [TXKeyframe]) {
        let empty: TXError? = bakeError(TextureBaker(), TXMesh(positions: [], indices: []), keyframes)
        c.expect("errors.emptyMesh", isInvalidMesh(empty), "\(String(describing: empty))")
        let triangle: [SIMD3<Float>] = [SIMD3<Float>(0, 0, -1), SIMD3<Float>(1, 0, -1), SIMD3<Float>(0, 1, -1)]
        let outOfRange: TXError? = bakeError(TextureBaker(), TXMesh(positions: triangle, indices: [0, 1, 5]), keyframes)
        c.expect("errors.indexOutOfRange", isInvalidMesh(outOfRange), "\(String(describing: outOfRange))")
        let none: TXError? = bakeError(TextureBaker(), mesh, [])
        c.expect("errors.noKeyframes", none == TXError.noKeyframes, "\(String(describing: none))")
        let baker = TextureBaker()
        baker.cancel()
        let cancelled: TXError? = bakeError(baker, mesh, keyframes)
        c.expect("errors.cancelled", cancelled == TXError.cancelled, "\(String(describing: cancelled))")
    }

    /// The `TXError` thrown by a bake, or nil when it succeeds or throws something else.
    static func bakeError(_ baker: TextureBaker, _ mesh: TXMesh, _ keyframes: [TXKeyframe]) -> TXError? {
        do {
            _ = try baker.bake(mesh: mesh, keyframes: keyframes, progress: nil)
            return nil
        } catch let error as TXError {
            return error
        } catch {
            return nil
        }
    }

    /// True for `TXError.invalidMesh` with any message.
    static func isInvalidMesh(_ error: TXError?) -> Bool {
        guard let error = error else { return false }
        switch error {
        case .invalidMesh(_):
            return true
        default:
            return false
        }
    }
}
