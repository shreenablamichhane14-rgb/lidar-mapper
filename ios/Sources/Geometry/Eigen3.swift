import Foundation
import simd

/// Eigen decomposition of 3x3 symmetric matrices by cyclic Jacobi rotations, computed in
/// Double internally. Used for plane fitting and oriented boxes (PCA of point covariances).
enum SymmetricEigen3 {
    /// Upper bound on full Jacobi sweeps. 3x3 matrices converge in well under 10.
    static let maxSweeps = 32
    /// Stop when the off-diagonal energy falls below this fraction of the diagonal energy.
    static let relativeTolerance: Double = 1e-30

    /// Eigenvalues sorted ascending and the matching unit eigenvectors as the columns of
    /// `vectors` (column i belongs to value i). The columns form a right-handed rotation
    /// (determinant +1); each column's sign is otherwise arbitrary. The input is assumed
    /// symmetric; it is symmetrized first to absorb rounding.
    static func decompose(_ m: simd_float3x3) -> (values: SIMD3<Float>, vectors: simd_float3x3) {
        // a[row][col] in Double; simd matrices are column major, so m[col][row].
        var a = [[Double]](repeating: [0, 0, 0], count: 3)
        for r in 0..<3 {
            for c in 0..<3 {
                a[r][c] = 0.5 * (Double(m[c][r]) + Double(m[r][c]))
            }
        }
        var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]

        for _ in 0..<maxSweeps {
            let off = a[0][1] * a[0][1] + a[0][2] * a[0][2] + a[1][2] * a[1][2]
            let diagonal = a[0][0] * a[0][0] + a[1][1] * a[1][1] + a[2][2] * a[2][2]
            if off == 0 || off <= relativeTolerance * diagonal { break }
            for (p, q) in [(0, 1), (0, 2), (1, 2)] {
                let apq = a[p][q]
                if apq == 0 { continue }
                let theta = (a[q][q] - a[p][p]) / (2 * apq)
                let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                let c = 1 / (t * t + 1).squareRoot()
                let s = t * c
                a[p][p] -= t * apq
                a[q][q] += t * apq
                a[p][q] = 0
                a[q][p] = 0
                let r = 3 - p - q
                let arp = a[r][p]
                let arq = a[r][q]
                a[r][p] = c * arp - s * arq
                a[p][r] = a[r][p]
                a[r][q] = s * arp + c * arq
                a[q][r] = a[r][q]
                for k in 0..<3 {
                    let vkp = v[k][p]
                    let vkq = v[k][q]
                    v[k][p] = c * vkp - s * vkq
                    v[k][q] = s * vkp + c * vkq
                }
            }
        }

        let raw = [a[0][0], a[1][1], a[2][2]]
        let order = [0, 1, 2].sorted { raw[$0] < raw[$1] }
        func column(_ i: Int) -> SIMD3<Double> {
            SIMD3<Double>(v[0][i], v[1][i], v[2][i])
        }
        let c0 = simd_normalize(column(order[0]))
        let c1 = simd_normalize(column(order[1]))
        // Rebuilding the last column from the first two makes the basis right-handed; it
        // only flips the sign of an already orthonormal eigenvector.
        let c2 = simd_cross(c0, c1)
        let values = SIMD3<Float>(Float(raw[order[0]]), Float(raw[order[1]]), Float(raw[order[2]]))
        let vectors = simd_float3x3(SIMD3<Float>(c0), SIMD3<Float>(c1), SIMD3<Float>(c2))
        return (values, vectors)
    }

    /// Mean and covariance (divided by n) of a point set, accumulated in Double so points
    /// meters from the origin keep their precision. Nil for an empty or non-finite set.
    static func covariance(of points: [SIMD3<Float>]) -> (mean: SIMD3<Float>, covariance: simd_float3x3)? {
        guard !points.isEmpty else { return nil }
        var sum = SIMD3<Double>.zero
        for p in points {
            sum += SIMD3<Double>(p)
        }
        let mean = sum / Double(points.count)
        guard mean.x.isFinite, mean.y.isFinite, mean.z.isFinite else { return nil }
        var xx = 0.0, xy = 0.0, xz = 0.0, yy = 0.0, yz = 0.0, zz = 0.0
        for p in points {
            let r = SIMD3<Double>(p) - mean
            xx += r.x * r.x
            xy += r.x * r.y
            xz += r.x * r.z
            yy += r.y * r.y
            yz += r.y * r.z
            zz += r.z * r.z
        }
        let inv = 1 / Double(points.count)
        let matrix = simd_float3x3(
            SIMD3<Float>(Float(xx * inv), Float(xy * inv), Float(xz * inv)),
            SIMD3<Float>(Float(xy * inv), Float(yy * inv), Float(yz * inv)),
            SIMD3<Float>(Float(xz * inv), Float(yz * inv), Float(zz * inv))
        )
        return (SIMD3<Float>(mean), matrix)
    }
}
