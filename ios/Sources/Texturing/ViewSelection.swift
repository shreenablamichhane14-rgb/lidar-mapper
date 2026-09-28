import Foundation
import simd

/// Chooses one keyframe per face: a data score per candidate view (view cosine, texel density,
/// keyframe sharpness) followed by a few passes of greedy label smoothing over the face
/// adjacency graph, the practical cousin of MRF view selection. Fewer label changes between
/// neighbours means fewer, larger charts and fewer visible seams.
enum TXViewSelection {
    /// Smallest and largest per-keyframe sharpness weight.
    static let weightRange: ClosedRange<Float> = 0.5...1

    /// Variance of the 4-neighbour Laplacian of a luma thumbnail (sharpness proxy, higher = sharper).
    ///
    /// The Laplacian `L = up + down + left + right - 4 * center` is evaluated at every interior
    /// pixel (the one-pixel border is skipped), and the population variance of `L` is returned in
    /// luma units squared (luma 0...255). Returns 0 for images smaller than 3 x 3 or when the
    /// value array does not match the size.
    static func sharpness(of luma: TXLumaImage) -> Float {
        let w: Int = luma.width
        let h: Int = luma.height
        guard w >= 3, h >= 3, luma.values.count >= w * h else { return 0 }
        let v: [Float] = luma.values
        var sum: Double = 0
        var sumSquares: Double = 0
        var count: Int = 0
        for y in 1..<(h - 1) {
            let row: Int = y * w
            for x in 1..<(w - 1) {
                let i: Int = row + x
                let lap: Float = v[i - 1] + v[i + 1] + v[i - w] + v[i + w] - 4 * v[i]
                if !lap.isFinite { continue }
                let d: Double = Double(lap)
                sum += d
                sumSquares += d * d
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let n: Double = Double(count)
        let mean: Double = sum / n
        let variance: Double = max(0, sumSquares / n - mean * mean)
        return Float(variance)
    }

    /// Per-keyframe weights in 0.5...1: sharpness normalized by the median over all keyframes, clamped.
    ///
    /// `weight = clamp(sharpness / median, 0.5, 1)`, so every keyframe at least as sharp as the
    /// median gets 1 and blurry ones are penalized by up to half. The median is taken over the
    /// finite, positive values only. When there is no such value (all zero, empty) every weight
    /// is 1; a non-finite or negative sharpness gets the lowest weight 0.5.
    static func sharpnessWeights(_ sharpness: [Float]) -> [Float] {
        let lower: Float = weightRange.lowerBound
        let upper: Float = weightRange.upperBound
        var valid: [Float] = []
        valid.reserveCapacity(sharpness.count)
        for s in sharpness where s.isFinite && s > 0 { valid.append(s) }
        guard !valid.isEmpty else {
            return [Float](repeating: upper, count: sharpness.count)
        }
        valid.sort()
        let mid: Int = valid.count / 2
        let median: Float
        if valid.count % 2 == 0 {
            median = 0.5 * (valid[mid - 1] + valid[mid])
        } else {
            median = valid[mid]
        }
        guard median > 0, median.isFinite else {
            return [Float](repeating: upper, count: sharpness.count)
        }
        var weights: [Float] = [Float](repeating: upper, count: sharpness.count)
        for i in 0..<sharpness.count {
            let s: Float = sharpness[i]
            if !s.isFinite || s < 0 {
                weights[i] = lower
                continue
            }
            let ratio: Float = s / median
            weights[i] = min(upper, max(lower, ratio))
        }
        return weights
    }

    /// Data score of one candidate: cosine * min(1, pixelsPerMeter / targetPixelsPerMeter)^0.5 * weight.
    ///
    /// The density factor saturates at 1 once the keyframe resolves the surface at least as finely
    /// as the atlas will store it, so a closer camera wins only while it adds real detail.
    /// A non-positive target treats every density as sufficient. Never negative; 0 for NaN input.
    static func score(_ c: TXViewCandidate, targetPixelsPerMeter: Float, weight: Float) -> Float {
        let cosine: Float = c.cosine.isFinite ? max(0, c.cosine) : 0
        let w: Float = weight.isFinite ? max(0, weight) : 0
        var density: Float = 1
        if targetPixelsPerMeter > 0 && targetPixelsPerMeter.isFinite {
            let ppm: Float = c.pixelsPerMeter.isFinite ? max(0, c.pixelsPerMeter) : 0
            let ratio: Float = min(1, ppm / targetPixelsPerMeter)
            density = ratio.squareRoot()
        }
        return cosine * density * w
    }

    /// Best keyframe per face (-1 when no candidate). Initial label = argmax score, then `iterations`
    /// passes of greedy smoothing: for each face pick argmax over its candidates of
    /// score + smoothness * (area-weighted fraction of neighbours currently using that keyframe) * bestScore(face).
    /// Deterministic (face order).
    ///
    /// Details:
    /// - The face count is `visibility.offsets.count - 1`.
    /// - `weights[k]` is the sharpness weight of keyframe `k`; a keyframe outside `weights` gets 1.
    /// - Smoothing updates labels in place in face order (Gauss-Seidel style), so later faces in a
    ///   pass already see the new labels of earlier faces. A pass that changes nothing ends early.
    /// - Neighbour weights are face areas from `geometry.areas`; when all neighbours have zero
    ///   area (or areas are missing) each neighbour counts equally. Untextured neighbours (-1)
    ///   count toward the total but vote for no keyframe.
    /// - Ties keep the earlier candidate (strictly greater wins).
    /// - Cost per pass is O(faces * candidates * neighbours), with no allocation inside the pass.
    static func select(visibility: TXVisibility, adjacency: TXAdjacency, geometry: TXFaceGeometry,
                       weights: [Float], targetPixelsPerMeter: Float,
                       smoothness: Float = 0.35, iterations: Int = 4) -> [Int32] {
        let faceCount: Int = max(0, visibility.offsets.count - 1)
        guard faceCount > 0 else { return [] }
        let candidates: [TXViewCandidate] = visibility.candidates
        let offsets: [Int32] = visibility.offsets

        // Data score of every candidate, parallel to `candidates`, and the best per face.
        var scores: [Float] = [Float](repeating: 0, count: candidates.count)
        var labels: [Int32] = [Int32](repeating: -1, count: faceCount)
        var bestScores: [Float] = [Float](repeating: 0, count: faceCount)
        for f in 0..<faceCount {
            let range: Range<Int> = candidateRange(offsets: offsets, face: f, total: candidates.count)
            var bestIndex: Int = -1
            var best: Float = -1
            for i in range {
                let c: TXViewCandidate = candidates[i]
                let k: Int = Int(c.keyframe)
                let w: Float = (k >= 0 && k < weights.count) ? weights[k] : 1
                let s: Float = score(c, targetPixelsPerMeter: targetPixelsPerMeter, weight: w)
                scores[i] = s
                if s > best {
                    best = s
                    bestIndex = i
                }
            }
            if bestIndex >= 0 {
                labels[f] = candidates[bestIndex].keyframe
                bestScores[f] = max(0, best)
            }
        }

        let lambda: Float = smoothness.isFinite ? max(0, smoothness) : 0
        guard lambda > 0, iterations > 0 else { return labels }

        let neighbourFaces: Int = max(0, adjacency.offsets.count - 1)
        let areas: [Float] = geometry.areas
        let neighbourList: [Int32] = adjacency.neighbors
        let neighbourOffsets: [Int32] = adjacency.offsets

        for _ in 0..<iterations {
            var changed: Bool = false
            for f in 0..<faceCount {
                let range: Range<Int> = candidateRange(offsets: offsets, face: f, total: candidates.count)
                // Only faces with a real choice can change.
                if range.count < 2 { continue }
                if f >= neighbourFaces { continue }
                let start: Int = max(0, Int(neighbourOffsets[f]))
                let end: Int = min(neighbourList.count, Int(neighbourOffsets[f + 1]))
                if end <= start { continue }

                // Total neighbour weight (area, or count when areas are unusable).
                var totalArea: Float = 0
                for j in start..<end {
                    totalArea += neighbourArea(Int(neighbourList[j]), areas: areas)
                }
                let useCounts: Bool = !(totalArea > 0)
                let total: Float = useCounts ? Float(end - start) : totalArea
                if !(total > 0) { continue }

                let bonusScale: Float = lambda * bestScores[f] / total
                var bestLabel: Int32 = labels[f]
                var best: Float = -Float.greatestFiniteMagnitude
                for i in range {
                    let k: Int32 = candidates[i].keyframe
                    var agreeing: Float = 0
                    for j in start..<end {
                        let nb: Int = Int(neighbourList[j])
                        if nb < 0 || nb >= faceCount || nb == f { continue }
                        if labels[nb] != k { continue }
                        agreeing += useCounts ? 1 : neighbourArea(nb, areas: areas)
                    }
                    let value: Float = scores[i] + bonusScale * agreeing
                    if value > best {
                        best = value
                        bestLabel = k
                    }
                }
                if bestLabel != labels[f] {
                    labels[f] = bestLabel
                    changed = true
                }
            }
            if !changed { break }
        }
        return labels
    }

    /// Index range of face `face`'s candidates, clamped to `0...total` so malformed offsets
    /// can never index out of bounds.
    private static func candidateRange(offsets: [Int32], face: Int, total: Int) -> Range<Int> {
        let lo: Int = min(max(0, Int(offsets[face])), total)
        let hi: Int = min(max(lo, Int(offsets[face + 1])), total)
        return lo..<hi
    }

    /// Area of face `face` used as a neighbour weight: 0 when out of range, negative or not finite.
    private static func neighbourArea(_ face: Int, areas: [Float]) -> Float {
        guard face >= 0, face < areas.count else { return 0 }
        let a: Float = areas[face]
        return (a.isFinite && a > 0) ? a : 0
    }
}
