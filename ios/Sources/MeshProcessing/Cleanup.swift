import Foundation
import simd

/// Mesh cleanup for the derived meshes: connected components (union-find over shared
/// edges), floater removal, conservative non-manifold edge repair, winding repair by
/// breadth-first orientation propagation, and area-weighted normals.
///
/// Pure functions: inputs are never mutated, and face and vertex attributes follow their
/// faces and vertices (`MeshWithAttributes.keepingFaces`). All topology is built from
/// `EdgeTable` (flat sorted arrays), so the cost is O(n log n) in the triangle count; a
/// 1,000,000 triangle mesh takes roughly 1 s per step on an A15, dominated by the sort of
/// 3,000,000 edge entries.
enum MeshCleanup {
    /// Components with less area than this (square meters) are floaters by default.
    static let defaultMinimumArea: Float = 0.02
    /// Components with fewer triangles than this are floaters by default.
    static let defaultMinimumTriangles = 20

    /// Faces grouped into edge-connected components.
    struct Components: Equatable {
        /// Component id per face (0 ..< count), or -1 for a face with an out-of-range index.
        /// Ids follow the order of each component's first face.
        var faceComponent: [Int32]
        /// Number of components.
        var count: Int
        /// Triangle count per component.
        var triangleCounts: [Int]
        /// Surface area per component, in square meters (non-finite faces count as 0).
        var areas: [Float]

        /// Id of the component with the largest area (ties: more triangles, then the lower
        /// id), or nil when there are no components.
        var largest: Int? {
            guard count > 0 else { return nil }
            var best = 0
            for c in 1..<count where areas[c] > areas[best]
                || (areas[c] == areas[best] && triangleCounts[c] > triangleCounts[best]) {
                best = c
            }
            return best
        }
    }

    // MARK: - Components and floaters

    /// Edge-connected components by union-find: two faces are connected when they share an
    /// undirected edge (faces touching at a single vertex are not). Faces with an
    /// out-of-range index belong to no component (id -1).
    static func connectedComponents(_ mesh: TriangleMesh) -> Components {
        let faces = mesh.triangleCount
        var sets = UnionFind(count: faces)
        let table = EdgeTable(mesh: mesh)
        for e in 0..<table.edgeCount {
            let run = table.run(e)
            let firstFace = Int(table.slots[run.lowerBound]) / 3
            for k in run.dropFirst() {
                sets.union(firstFace, Int(table.slots[k]) / 3)
            }
        }
        var label = [Int32](repeating: -1, count: faces)
        var rootLabel = [Int32](repeating: -1, count: faces)
        var triangleCounts: [Int] = []
        var areaSums: [Double] = []
        for t in 0..<faces where mesh.triangle(t) != nil {
            let root = sets.find(t)
            if rootLabel[root] < 0 {
                rootLabel[root] = Int32(triangleCounts.count)
                triangleCounts.append(0)
                areaSums.append(0)
            }
            let c = Int(rootLabel[root])
            label[t] = Int32(c)
            triangleCounts[c] += 1
            let area = MeshTopology.area(mesh, t)
            if area.isFinite { areaSums[c] += Double(area) }
        }
        return Components(faceComponent: label, count: triangleCounts.count,
                          triangleCounts: triangleCounts, areas: areaSums.map { Float($0) })
    }

    /// The mesh without floaters: components with an area below `minimumArea` or fewer
    /// than `minimumTriangles` triangles are removed. The largest component (by area) is
    /// always kept, so a small object scan never disappears. Faces with an out-of-range
    /// index are dropped.
    static func removingFloaters(_ input: MeshWithAttributes, minimumArea: Float = MeshCleanup.defaultMinimumArea,
                                 minimumTriangles: Int = MeshCleanup.defaultMinimumTriangles) -> MeshWithAttributes {
        let components = connectedComponents(input.mesh)
        guard let largest = components.largest else { return input.keepingFaces([]) }
        var keepComponent = [Bool](repeating: false, count: components.count)
        for c in 0..<components.count {
            keepComponent[c] = c == largest
                || (components.areas[c] >= minimumArea && components.triangleCounts[c] >= minimumTriangles)
        }
        return input.keepingFaces(components.faceComponent.map { $0 >= 0 && keepComponent[Int($0)] })
    }

    /// Only the largest component by area (see `Components.largest`); an empty mesh when
    /// there is none.
    static func largestComponent(_ input: MeshWithAttributes) -> MeshWithAttributes {
        let components = connectedComponents(input.mesh)
        guard let largest = components.largest else { return input.keepingFaces([]) }
        let id = Int32(largest)
        return input.keepingFaces(components.faceComponent.map { $0 == id })
    }

    // MARK: - Non-manifold edges

    /// One face using an edge: its index and whether it runs from the smaller vertex index
    /// to the larger one.
    private struct EdgeUser {
        /// Face index.
        var face: Int
        /// True when the face traverses the edge from its smaller to its larger vertex.
        var forward: Bool
    }

    /// Conservative repair of edges shared by more than two faces: on each such edge the
    /// largest face is kept together with the largest face that traverses the edge in the
    /// opposite direction (a consistently wound partner; the second largest when there is
    /// none), and only the other faces on that edge are removed. Edges are processed in
    /// key order and removed faces no longer count, so no more faces go than needed.
    /// Manifold meshes come back unchanged apart from dropping faces with an out-of-range
    /// index.
    static func removingNonManifoldEdges(_ input: MeshWithAttributes) -> MeshWithAttributes {
        let mesh = input.mesh
        let faces = mesh.triangleCount
        var alive = [Bool](repeating: false, count: faces)
        var areas = [Float](repeating: 0, count: faces)
        for t in 0..<faces where mesh.triangle(t) != nil {
            alive[t] = true
            let area = MeshTopology.area(mesh, t)
            areas[t] = area.isFinite ? area : 0
        }
        let table = EdgeTable(mesh: mesh)
        var users: [EdgeUser] = []
        for e in 0..<table.edgeCount {
            let run = table.run(e)
            guard run.count > 2 else { continue }
            let (lo, hi) = MeshTopology.edgeVertices(table.keys[run.lowerBound])
            guard lo != hi else { continue }
            users.removeAll(keepingCapacity: true)
            for k in run {
                let face = Int(table.slots[k]) / 3
                guard alive[face], !users.contains(where: { $0.face == face }) else { continue }
                users.append(EdgeUser(face: face, forward: table.directed(k, in: mesh).0 == lo))
            }
            guard users.count > 2 else { continue }
            users.sort { a, b in
                areas[a.face] > areas[b.face] || (areas[a.face] == areas[b.face] && a.face < b.face)
            }
            let keeper = users[0]
            let partner = users.dropFirst().first(where: { $0.forward != keeper.forward }) ?? users[1]
            for user in users where user.face != keeper.face && user.face != partner.face {
                alive[user.face] = false
            }
        }
        return input.keepingFaces(alive)
    }

    // MARK: - Winding

    /// Makes the winding consistent within every component by breadth-first propagation
    /// across manifold edges (edges shared by exactly two faces): a neighbor that traverses
    /// the shared edge in the same direction gets the opposite flip state. Then each
    /// component is oriented as a whole: a closed component (every edge manifold) so its
    /// signed volume is positive (outward), an open one so the majority of its original
    /// area keeps its winding. Only the corner order of faces changes (corners 1 and 2
    /// swap): face order, vertices and attributes are untouched, and faces with an
    /// out-of-range index are left as they are. Non-orientable input (a Moebius strip) keeps
    /// the first orientation reached for each face.
    static func fixingWinding(_ input: MeshWithAttributes) -> MeshWithAttributes {
        let mesh = input.mesh
        let faces = mesh.triangleCount
        guard faces > 0 else { return input }
        let links = WindingLinks(mesh: mesh)

        var flip = [Bool](repeating: false, count: faces)
        var visited = [Bool](repeating: false, count: faces)
        var queue: [Int] = []
        var indices = mesh.indices
        for seed in 0..<faces where !visited[seed] && mesh.triangle(seed) != nil {
            queue.removeAll(keepingCapacity: true)
            queue.append(seed)
            visited[seed] = true
            var cursor = 0
            var closed = true
            while cursor < queue.count {
                let f = queue[cursor]
                cursor += 1
                if !links.closedFace[f] { closed = false }
                for s in links.start[f]..<links.start[f + 1] {
                    let g = Int(links.neighbor[s])
                    guard !visited[g] else { continue }
                    visited[g] = true
                    flip[g] = flip[f] != links.sameDirection[s]
                    queue.append(g)
                }
            }
            let invert = closed ? componentVolume(mesh, queue, flip) < 0 : flippedAreaWins(mesh, queue, flip)
            for f in queue where flip[f] != invert {
                indices.swapAt(3 * f + 1, 3 * f + 2)
            }
        }
        var output = input
        output.mesh = TriangleMesh(positions: mesh.positions, indices: indices)
        return output
    }

    /// Face adjacency over manifold edges in compressed rows: the neighbors of face f are
    /// `neighbor[start[f] ..< start[f + 1]]`, with `sameDirection` true when both faces run
    /// the shared edge the same way (inconsistent winding).
    private struct WindingLinks {
        /// Row starts, `faceCount + 1` entries.
        var start: [Int]
        /// Neighbor face per entry.
        var neighbor: [Int32]
        /// Per entry: true when the two faces traverse the shared edge in the same direction.
        var sameDirection: [Bool]
        /// Per face: true when all three of its edges are shared by exactly two faces.
        var closedFace: [Bool]

        /// Builds the links of `mesh` from its edge table.
        init(mesh: TriangleMesh) {
            let faces = mesh.triangleCount
            let table = EdgeTable(mesh: mesh)
            var pairA: [Int32] = [], pairB: [Int32] = [], pairSame: [Bool] = []
            pairA.reserveCapacity(table.edgeCount)
            pairB.reserveCapacity(table.edgeCount)
            pairSame.reserveCapacity(table.edgeCount)
            var closed = [Bool](repeating: true, count: faces)
            var degree = [Int](repeating: 0, count: faces)
            for e in 0..<table.edgeCount {
                let run = table.run(e)
                let first = run.lowerBound
                let f = Int(table.slots[first]) / 3
                let g = run.count == 2 ? Int(table.slots[first + 1]) / 3 : f
                let (lo, hi) = MeshTopology.edgeVertices(table.keys[first])
                guard run.count == 2, f != g, lo != hi else {
                    for k in run { closed[Int(table.slots[k]) / 3] = false }
                    continue
                }
                pairA.append(Int32(f))
                pairB.append(Int32(g))
                pairSame.append(table.directed(first, in: mesh).0 == table.directed(first + 1, in: mesh).0)
                degree[f] += 1
                degree[g] += 1
            }
            var rowStart = [Int](repeating: 0, count: faces + 1)
            for f in 0..<faces {
                rowStart[f + 1] = rowStart[f] + degree[f]
            }
            var fill = Array(rowStart.prefix(faces))
            var neighbors = [Int32](repeating: 0, count: rowStart[faces])
            var same = [Bool](repeating: false, count: rowStart[faces])
            for p in 0..<pairA.count {
                let a = Int(pairA[p]), b = Int(pairB[p])
                neighbors[fill[a]] = pairB[p]
                same[fill[a]] = pairSame[p]
                fill[a] += 1
                neighbors[fill[b]] = pairA[p]
                same[fill[b]] = pairSame[p]
                fill[b] += 1
            }
            start = rowStart
            neighbor = neighbors
            sameDirection = same
            closedFace = closed
        }
    }

    /// Six times the signed volume of the faces `component` with `flip` applied, relative to
    /// the component's first vertex, in Double.
    private static func componentVolume(_ mesh: TriangleMesh, _ component: [Int], _ flip: [Bool]) -> Double {
        guard let seed = component.first, let reference = mesh.triangle(seed)?.0 else { return 0 }
        let origin = SIMD3<Double>(reference)
        var sum = 0.0
        for f in component {
            guard let corners = mesh.triangle(f) else { continue }
            let a = SIMD3<Double>(corners.0) - origin
            let b = SIMD3<Double>(corners.1) - origin
            let c = SIMD3<Double>(corners.2) - origin
            let v = simd_dot(a, simd_cross(b, c))
            guard v.isFinite else { continue }
            sum += flip[f] ? -v : v
        }
        return sum
    }

    /// True when the faces of `component` marked in `flip` hold more area than the others,
    /// so inverting the whole component keeps the majority's original winding.
    private static func flippedAreaWins(_ mesh: TriangleMesh, _ component: [Int], _ flip: [Bool]) -> Bool {
        var flipped = 0.0, kept = 0.0
        for f in component {
            let area = Double(MeshTopology.area(mesh, f))
            guard area.isFinite else { continue }
            if flip[f] { flipped += area } else { kept += area }
        }
        return flipped > kept
    }

    // MARK: - Normals and the full pass

    /// Area-weighted vertex normals (Geometry's `TriangleMesh.vertexNormals`): each face adds
    /// its unnormalized cross product to its corners; vertices without a non-degenerate
    /// face get `TriangleMesh.fallbackNormal`. Recompute after any cleanup step.
    static func normals(_ mesh: TriangleMesh) -> [SIMD3<Float>] {
        mesh.vertexNormals
    }

    /// Unit normal per face, `TriangleMesh.fallbackNormal` for degenerate faces and faces
    /// with an out-of-range index.
    static func faceNormals(_ mesh: TriangleMesh) -> [SIMD3<Float>] {
        (0..<mesh.triangleCount).map { t in
            let vector = MeshTopology.areaVector(mesh, t)
            let length = simd_length(vector)
            return length > 0 && length.isFinite ? vector / length : TriangleMesh.fallbackNormal
        }
    }

    /// The full cleanup pass: degenerate and duplicate faces removed
    /// (`ChunkMerge.removingDegenerateAndDuplicateFaces`), non-manifold edges repaired,
    /// floaters removed, then the winding made consistent and outward. Normals are not
    /// stored; compute them with `normals(_:)` on the result.
    static func cleaned(_ input: MeshWithAttributes, minimumArea: Float = MeshCleanup.defaultMinimumArea,
                        minimumTriangles: Int = MeshCleanup.defaultMinimumTriangles) -> MeshWithAttributes {
        let tidy = ChunkMerge.removingDegenerateAndDuplicateFaces(input)
        let manifold = removingNonManifoldEdges(tidy)
        let solid = removingFloaters(manifold, minimumArea: minimumArea, minimumTriangles: minimumTriangles)
        return fixingWinding(solid)
    }
}
