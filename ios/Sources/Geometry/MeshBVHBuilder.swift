import Foundation
import simd

/// Top-down binned SAH construction for `MeshBVH`. Uses an explicit task stack (no
/// recursion) and in-place partitioning of one triangle order array. Each level costs
/// O(n), and the depth cap bounds pathological inputs, giving O(n log n) in practice.
enum MeshBVHBuilder {
    /// Pending subtree: node slot to fill and its range of the order array.
    private struct BuildTask {
        var node: Int
        var first: Int
        var count: Int
        var depth: Int
    }

    /// Nodes and leaf-ordered triangle ids for `mesh`.
    static func build(_ mesh: TriangleMesh) -> (nodes: [MeshBVH.Node], order: [UInt32]) {
        let triangleCount = mesh.triangleCount
        var order: [UInt32] = []
        order.reserveCapacity(triangleCount)
        var boxMin = [SIMD3<Float>](repeating: .zero, count: triangleCount)
        var boxMax = [SIMD3<Float>](repeating: .zero, count: triangleCount)
        var centroid = [SIMD3<Float>](repeating: .zero, count: triangleCount)
        for t in 0..<triangleCount {
            guard let corners = mesh.triangle(t) else { continue }
            let (a, b, c) = corners
            let lo = simd_min(a, simd_min(b, c))
            let hi = simd_max(a, simd_max(b, c))
            guard lo.x.isFinite, lo.y.isFinite, lo.z.isFinite,
                  hi.x.isFinite, hi.y.isFinite, hi.z.isFinite else { continue }
            order.append(UInt32(t))
            boxMin[t] = lo
            boxMax[t] = hi
            centroid[t] = (a + b + c) / 3
        }
        guard !order.isEmpty else { return ([], []) }

        let leafSize = MeshBVH.maxLeafSize
        let bins = MeshBVH.binCount
        var nodes: [MeshBVH.Node] = []
        nodes.reserveCapacity(2 * (order.count / leafSize) + 1)
        nodes.append(emptyNode)
        var tasks = [BuildTask(node: 0, first: 0, count: order.count, depth: 0)]

        // Scratch reused by every node.
        var binCounts = [Int](repeating: 0, count: bins)
        var binMin = [SIMD3<Float>](repeating: .zero, count: bins)
        var binMax = [SIMD3<Float>](repeating: .zero, count: bins)
        var leftCost = [Float](repeating: 0, count: bins)
        var leftCount = [Int](repeating: 0, count: bins)
        let infinity = SIMD3<Float>(repeating: .infinity)

        while let task = tasks.popLast() {
            let first = task.first
            let end = first + task.count
            var lo = infinity, hi = -infinity, centerLo = infinity, centerHi = -infinity
            for k in first..<end {
                let t = Int(order[k])
                lo = simd_min(lo, boxMin[t])
                hi = simd_max(hi, boxMax[t])
                centerLo = simd_min(centerLo, centroid[t])
                centerHi = simd_max(centerHi, centroid[t])
            }
            var node = MeshBVH.Node(minX: lo.x, minY: lo.y, minZ: lo.z, maxX: hi.x, maxY: hi.y, maxZ: hi.z,
                                    leftOrFirst: UInt32(first), count: UInt32(task.count))
            if task.count <= leafSize || task.depth >= MeshBVH.maxDepth {
                nodes[task.node] = node
                continue
            }

            // Binned SAH over all three axes; cost = area(left) * n(left) + area(right) * n(right).
            let extent = centerHi - centerLo
            var bestCost = Float.infinity
            var bestAxis = -1
            var bestSplit = 0
            for axis in 0..<3 where extent[axis] > 0 {
                let scale = Float(bins) / extent[axis]
                guard scale.isFinite else { continue }
                for b in 0..<bins {
                    binCounts[b] = 0
                    binMin[b] = infinity
                    binMax[b] = -infinity
                }
                for k in first..<end {
                    let t = Int(order[k])
                    let b = bin(centroid[t][axis], centerLo[axis], scale, bins)
                    binCounts[b] += 1
                    binMin[b] = simd_min(binMin[b], boxMin[t])
                    binMax[b] = simd_max(binMax[b], boxMax[t])
                }
                var sweepLo = infinity, sweepHi = -infinity, running = 0
                for b in 0..<(bins - 1) {
                    running += binCounts[b]
                    sweepLo = simd_min(sweepLo, binMin[b])
                    sweepHi = simd_max(sweepHi, binMax[b])
                    leftCount[b] = running
                    leftCost[b] = running > 0 ? halfArea(sweepLo, sweepHi) * Float(running) : 0
                }
                sweepLo = infinity
                sweepHi = -infinity
                running = 0
                for b in stride(from: bins - 1, through: 1, by: -1) {
                    running += binCounts[b]
                    sweepLo = simd_min(sweepLo, binMin[b])
                    sweepHi = simd_max(sweepHi, binMax[b])
                    guard running > 0, leftCount[b - 1] > 0 else { continue }
                    let cost = leftCost[b - 1] + halfArea(sweepLo, sweepHi) * Float(running)
                    if cost < bestCost {
                        bestCost = cost
                        bestAxis = axis
                        bestSplit = b
                    }
                }
            }

            // Default: halve the range (only used when all centroids coincide).
            var mid = first + task.count / 2
            if bestAxis >= 0 {
                let scale = Float(bins) / extent[bestAxis]
                var i = first
                var j = end - 1
                while i <= j {
                    let t = Int(order[i])
                    if bin(centroid[t][bestAxis], centerLo[bestAxis], scale, bins) < bestSplit {
                        i += 1
                    } else {
                        order.swapAt(i, j)
                        j -= 1
                    }
                }
                if i > first && i < end { mid = i }
            }

            let left = nodes.count
            nodes.append(emptyNode)
            nodes.append(emptyNode)
            node.leftOrFirst = UInt32(left)
            node.count = 0
            nodes[task.node] = node
            tasks.append(BuildTask(node: left + 1, first: mid, count: end - mid, depth: task.depth + 1))
            tasks.append(BuildTask(node: left, first: first, count: mid - first, depth: task.depth + 1))
        }
        return (nodes, order)
    }

    /// Placeholder filled in when its task is processed.
    private static let emptyNode = MeshBVH.Node(minX: 0, minY: 0, minZ: 0, maxX: 0, maxY: 0, maxZ: 0,
                                                leftOrFirst: 0, count: 0)

    /// SAH bin of a centroid coordinate. The same function is used for binning and for
    /// partitioning so both agree exactly.
    @inline(__always)
    private static func bin(_ value: Float, _ lowest: Float, _ scale: Float, _ bins: Int) -> Int {
        Swift.min(bins - 1, Swift.max(0, Int((value - lowest) * scale)))
    }

    /// Half the surface area of a box (the constant factor does not change SAH decisions).
    @inline(__always)
    private static func halfArea(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> Float {
        let e = hi - lo
        return e.x * e.y + e.y * e.z + e.z * e.x
    }
}
