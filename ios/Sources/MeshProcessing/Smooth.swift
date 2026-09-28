import Foundation
import simd

/// Taubin (lambda, mu) smoothing: a shrinking Laplacian step followed by an inflating one,
/// which removes noise while keeping the volume. Boundary vertices stay fixed.
enum MeshSmooth {
    /// Shrinking step factor.
    static let defaultLambda: Float = 0.5
    /// Inflating step factor (negative, slightly larger in magnitude than lambda).
    static let defaultMu: Float = -0.53
    /// Number of (lambda, mu) pairs.
    static let defaultIterations: Int = 5

    /// Runs `iterations` pairs of uniform umbrella Laplacian steps (move each vertex by
    /// `factor` times the offset to the mean of its edge neighbors), first with `lambda`,
    /// then with `mu`. Vertices on an edge not shared by exactly two faces (boundary or
    /// non-manifold) do not move, and neither do isolated vertices. Topology, indices and
    /// all attributes are unchanged. The input is never mutated.
    static func taubin(_ input: MeshWithAttributes, iterations: Int = MeshSmooth.defaultIterations,
                       lambda: Float = MeshSmooth.defaultLambda, mu: Float = MeshSmooth.defaultMu) -> MeshWithAttributes {
        let mesh = input.mesh
        let vertexCount = mesh.positions.count
        guard iterations > 0, vertexCount > 0, mesh.triangleCount > 0 else { return input }
        let table = EdgeTable(mesh: mesh)

        // Pass 1: degree per vertex and fixed vertices.
        var fixed = [Bool](repeating: false, count: vertexCount)
        var degree = [Int](repeating: 0, count: vertexCount)
        for e in 0..<table.edgeCount {
            let run = table.run(e)
            let (a, b) = MeshTopology.edgeVertices(table.keys[run.lowerBound])
            guard a != b else { continue }
            var uses = 0
            var lastFace = -1
            for k in run {
                let face = Int(table.slots[k]) / 3
                if face != lastFace {
                    uses += 1
                    lastFace = face
                }
            }
            if uses != 2 {
                fixed[Int(a)] = true
                fixed[Int(b)] = true
            }
            degree[Int(a)] += 1
            degree[Int(b)] += 1
        }

        // Pass 2: CSR neighbor lists.
        var start = [Int](repeating: 0, count: vertexCount + 1)
        for v in 0..<vertexCount {
            start[v + 1] = start[v] + degree[v]
        }
        var fill = Array(start.prefix(vertexCount))
        var neighbors = [UInt32](repeating: 0, count: start[vertexCount])
        for e in 0..<table.edgeCount {
            let (a, b) = MeshTopology.edgeVertices(table.keys[table.runStarts[e]])
            guard a != b else { continue }
            neighbors[fill[Int(a)]] = b
            fill[Int(a)] += 1
            neighbors[fill[Int(b)]] = a
            fill[Int(b)] += 1
        }

        var current = mesh.positions
        var scratch = current
        let factors = [lambda, mu]
        for _ in 0..<iterations {
            for factor in factors {
                for v in 0..<vertexCount {
                    let lo = start[v], hi = start[v + 1]
                    guard !fixed[v], hi > lo else {
                        scratch[v] = current[v]
                        continue
                    }
                    var sum = SIMD3<Float>.zero
                    for s in lo..<hi {
                        sum += current[Int(neighbors[s])]
                    }
                    let mean = sum / Float(hi - lo)
                    let moved = current[v] + factor * (mean - current[v])
                    scratch[v] = moved.x.isFinite && moved.y.isFinite && moved.z.isFinite ? moved : current[v]
                }
                swap(&current, &scratch)
            }
        }
        var result = input
        result.mesh = TriangleMesh(positions: current, indices: mesh.indices)
        return result
    }
}
