import Foundation
import simd

/// Per-keyframe brightness gains that make overlapping keyframes agree.
enum TXExposure {
    /// Smallest gain returned.
    static let minGain: Float = 0.5
    /// Largest gain returned.
    static let maxGain: Float = 2
    /// Most log-ratio samples kept per keyframe pair (faces are strided, so they spread out).
    static let maxSamplesPerPair = 512
    /// Faces are visited with a stride so at most about this many are sampled.
    static let maxFacesSampled = 200_000
    /// Luma samples darker than this are ignored (noise, crushed blacks, log of zero).
    private static let minLuma: Float = 8
    /// Luma samples brighter than this are ignored (clipped highlights).
    private static let maxLuma: Float = 250

    /// Per-keyframe multiplicative gains (1 = unchanged). For each face with >= 2 candidates,
    /// samples luma at the face centroid in each seeing keyframe (lumas[k].sample(sourcePixel:));
    /// collects log-ratios per keyframe pair and takes the median per pair; then solves
    /// minimize sum_pairs w_ij (g_i - g_j + median(log L_i - log L_j))^2 + lambda * sum g_i^2
    /// with w_ij = sample count and lambda = 0.01 * max w, by dense normal equations and
    /// Cholesky. The log gains are then shifted so the median gain over the keyframes that
    /// have overlaps is exactly 1 (absolute colours are not shifted, only made consistent).
    /// Gains = exp(g) clamped to 0.5...2. Keyframes with no overlaps get 1. Luma samples
    /// below 8 or above 250 are skipped. Deterministic (pairs are summed in sorted key order).
    static func solveGains(visibility: TXVisibility, geometry: TXFaceGeometry, cameras: [TXCamera],
                           lumas: [TXLumaImage?]) -> [Float] {
        let count: Int = cameras.count
        var gains = [Float](repeating: 1, count: count)
        if count < 2 { return gains }
        let faceCount: Int = min(geometry.centroids.count, visibility.offsets.count - 1)
        if faceCount <= 0 { return gains }
        let stride: Int = max(1, faceCount / maxFacesSampled)
        var pairSamples: [Int: [Float]] = [:]
        var keys: [Int] = []
        var logs: [Float] = []
        var f: Int = 0
        while f < faceCount {
            let candidates = visibility.candidates(forFace: f)
            if candidates.count >= 2 {
                keys.removeAll(keepingCapacity: true)
                logs.removeAll(keepingCapacity: true)
                for candidate in candidates {
                    let k = Int(candidate.keyframe)
                    guard k >= 0, k < count, k < lumas.count, let luma = lumas[k] else { continue }
                    guard let projected = cameras[k].project(geometry.centroids[f]) else { continue }
                    let pixel = SIMD2<Float>(projected.x, projected.y)
                    guard cameras[k].contains(pixel) else { continue }
                    let value: Float = luma.sample(sourcePixel: pixel)
                    guard value.isFinite, value >= minLuma, value <= maxLuma else { continue }
                    keys.append(k)
                    logs.append(Float(log(Double(value))))
                }
                if keys.count >= 2 {
                    for a in 0..<(keys.count - 1) {
                        for b in (a + 1)..<keys.count where keys[a] != keys[b] {
                            let low: Int = min(keys[a], keys[b])
                            let high: Int = max(keys[a], keys[b])
                            // log L_low - log L_high
                            let ratio: Float = keys[a] < keys[b] ? logs[a] - logs[b] : logs[b] - logs[a]
                            let key: Int = low * count + high
                            if (pairSamples[key]?.count ?? 0) < maxSamplesPerPair {
                                pairSamples[key, default: []].append(ratio)
                            }
                        }
                    }
                }
            }
            f += stride
        }
        if pairSamples.isEmpty { return gains }

        var matrix = [Double](repeating: 0, count: count * count)
        var rhs = [Double](repeating: 0, count: count)
        var involved = [Bool](repeating: false, count: count)
        var maxWeight: Double = 0
        for key in pairSamples.keys.sorted() {
            guard let samples = pairSamples[key], !samples.isEmpty else { continue }
            let median = Double(TXExposure.median(samples))
            let weight = Double(samples.count)
            let i: Int = key / count
            let j: Int = key % count
            involved[i] = true
            involved[j] = true
            maxWeight = max(maxWeight, weight)
            matrix[i * count + i] += weight
            matrix[j * count + j] += weight
            matrix[i * count + j] -= weight
            matrix[j * count + i] -= weight
            rhs[i] -= weight * median
            rhs[j] += weight * median
        }
        let lambda: Double = max(1e-6, 0.01 * maxWeight)
        for i in 0..<count { matrix[i * count + i] += lambda }
        guard let solution = TXExposure.choleskySolve(matrix, rhs, size: count) else { return gains }
        var involvedLogs: [Float] = []
        for i in 0..<count where involved[i] && solution[i].isFinite {
            involvedLogs.append(Float(solution[i]))
        }
        if involvedLogs.isEmpty { return gains }
        // Median normalization: the median log gain becomes 0, so the median gain is exactly 1
        // (for an even count, the geometric mean of the two middle gains is 1).
        let shift = Double(TXExposure.median(involvedLogs))
        for i in 0..<count where involved[i] && solution[i].isFinite {
            let gain = Float(exp(solution[i] - shift))
            gains[i] = min(max(gain, minGain), maxGain)
        }
        return gains
    }

    /// Median of a non-empty list (mean of the two middle values for an even count); 0 if empty.
    static func median(_ values: [Float]) -> Float {
        if values.isEmpty { return 0 }
        let sorted = values.sorted()
        let mid: Int = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[mid] }
        return (sorted[mid - 1] + sorted[mid]) * 0.5
    }

    /// Solves `matrix * x = rhs` for a symmetric positive definite row-major `size` x `size`
    /// matrix by Cholesky factorization; nil when the matrix is not positive definite.
    static func choleskySolve(_ matrix: [Double], _ rhs: [Double], size n: Int) -> [Double]? {
        guard n > 0, matrix.count >= n * n, rhs.count >= n else { return nil }
        var l = matrix
        for j in 0..<n {
            var diagonal: Double = l[j * n + j]
            for p in 0..<j { diagonal -= l[j * n + p] * l[j * n + p] }
            guard diagonal > 1e-12 else { return nil }
            let root: Double = diagonal.squareRoot()
            l[j * n + j] = root
            for i in (j + 1)..<n {
                var value: Double = l[i * n + j]
                for p in 0..<j { value -= l[i * n + p] * l[j * n + p] }
                l[i * n + j] = value / root
            }
        }
        var y = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var value: Double = rhs[i]
            for p in 0..<i { value -= l[i * n + p] * y[p] }
            y[i] = value / l[i * n + i]
        }
        var x = [Double](repeating: 0, count: n)
        var i: Int = n - 1
        while i >= 0 {
            var value: Double = y[i]
            for p in (i + 1)..<n { value -= l[p * n + i] * x[p] }
            x[i] = value / l[i * n + i]
            i -= 1
        }
        return x
    }
}
