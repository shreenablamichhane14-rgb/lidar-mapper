import Foundation
import simd

/// The two halves of `MeshConsolidator.consolidate` and their helpers. `ConsolidateMeshStep`
/// calls `mergedWorldMesh` and `finish` separately so the decoded raw chunks are released
/// before floater removal, hole filling and simplification.
extension MeshConsolidator {
    /// Chunks with fewer faces than this are not simplified by the reduced variant.
    static let minimumFacesToHalve = 8
    /// Grid cell (meters) used to thin the camera positions of the depth window crop.
    static let viewpointCell: Float = 0.25
    /// Most camera positions the depth window crop tests per face.
    static let maxViewpoints = 512

    // MARK: - Stages

    /// Merge stage: converts the chunks (`mergeChunks`), halves each one first in the reduced
    /// variant, then `ChunkMerge.merge` with `options.weldTolerance` (which also drops
    /// degenerate and duplicate faces; earlier chunks win duplicates). Nil when cancelled.
    static func mergedWorldMesh(_ chunks: [MeshChunk], options: ConsolidationOptions,
                                isCancelled: () -> Bool) -> MeshWithAttributes? {
        if isCancelled() { return nil }
        var parts = mergeChunks(chunks)
        if options.simplifyChunksBeforeMerge {
            for i in parts.indices {
                if i % 16 == 0 && isCancelled() { return nil }
                parts[i] = halved(parts[i])
            }
        }
        if isCancelled() { return nil }
        return ChunkMerge.merge(parts, weldTolerance: options.weldTolerance)
    }

    /// Finish stage on a merged world mesh: optional depth window crop, floater split,
    /// small-hole fill (inferred faces split out), view simplification of the measured faces
    /// only, floaters simplified by the same share, and the stats. Nil when cancelled.
    static func finish(_ merged: MeshWithAttributes, chunkCount: Int, options: ConsolidationOptions,
                       isCancelled: () -> Bool) -> ConsolidationResult? {
        if isCancelled() { return nil }
        let world: MeshWithAttributes
        if let window = options.depthWindow {
            world = croppingToDepthWindow(merged, window: window, viewpoints: options.viewpoints)
        } else {
            world = merged
        }
        if isCancelled() { return nil }

        let islands = splittingFloaters(world, minimumArea: options.minIslandArea,
                                        minimumTriangles: options.minIslandTriangles)
        if isCancelled() { return nil }

        // HoleFill keeps every existing face and vertex in place and appends the new faces
        // (flagged inferred) at the end, so the measured faces are exactly the kept islands.
        var measured = islands.kept
        measured.isInferred = nil
        let inferred = inferredFaces(HoleFill.fillSmallHoles(measured, maxPerimeter: options.holeMaxPerimeter).mesh)
        if isCancelled() { return nil }

        let budget = options.viewTriangleBudget
        let overBudget = budget > 0 && measured.triangleCount > budget
        var view = overBudget ? simplified(measured, target: budget, strict: true) : measured
        view.isInferred = nil
        if isCancelled() { return nil }

        var floaters = islands.removed
        floaters.isInferred = nil
        if overBudget && floaters.triangleCount > 0 {
            let share = Double(budget) / Double(measured.triangleCount)
            let target = Swift.max(1, Int((Double(floaters.triangleCount) * share).rounded(.down)))
            if floaters.triangleCount > target {
                floaters = simplified(floaters, target: target, strict: false)
                floaters.isInferred = nil
            }
        }
        if isCancelled() { return nil }

        let stats = makeStats(chunkCount: chunkCount, measured: measured, view: view, inferred: inferred)
        return ConsolidationResult(measured: measured, inferred: inferred, view: view, floaters: floaters, stats: stats)
    }

    // MARK: - Helpers

    /// Reduced variant: the chunk simplified to half its faces (boundaries held by the default
    /// boundary weight so chunk borders still weld). Tiny chunks come back unchanged.
    static func halved(_ chunk: MergeChunk) -> MergeChunk {
        let faces = chunk.localMesh.triangleCount
        guard faces >= minimumFacesToHalve else { return chunk }
        let input = MeshWithAttributes(mesh: chunk.localMesh, faceClass: chunk.faceClass)
        let options = MeshSimplify.Options(targetTriangleCount: faces / 2)
        let result = MeshSimplify.simplify(input, options: options).mesh
        return MergeChunk(localMesh: result.mesh, anchorTransform: chunk.anchorTransform,
                          faceClass: result.faceClass, vertexColor: nil)
    }

    /// The faces seen by at least one camera position at a distance inside `window` (face
    /// centroid to position). Positions are thinned to one per `viewpointCell` grid cell and at
    /// most `maxViewpoints`. Without positions the mesh comes back unchanged and the skip is
    /// logged, because dropping everything would lose the scan.
    static func croppingToDepthWindow(_ mesh: MeshWithAttributes, window: ClosedRange<Float>,
                                      viewpoints: [SIMD3<Float>]) -> MeshWithAttributes {
        let points = decimatedViewpoints(viewpoints)
        guard !points.isEmpty else {
            LogStore.shared.write("depth window crop skipped: no camera positions", category: logCategory)
            return mesh
        }
        let low = Swift.max(window.lowerBound, 0)
        let high = Swift.max(window.upperBound, low)
        let lowSquared = low * low
        let highSquared = high * high
        let faces = mesh.triangleCount
        var keep = [Bool](repeating: false, count: faces)
        for t in 0..<faces {
            guard let centroid = MeshTopology.centroid(mesh.mesh, t) else { continue }
            for point in points {
                let d2 = simd_distance_squared(centroid, point)
                if d2 >= lowSquared && d2 <= highSquared {
                    keep[t] = true
                    break
                }
            }
        }
        let result = mesh.keepingFaces(keep)
        let dropped = faces - result.triangleCount
        if dropped > 0 {
            LogStore.shared.write("depth window \(low)...\(high) m dropped \(dropped) of \(faces) faces",
                                  category: logCategory)
        }
        return result
    }

    /// Finite camera positions thinned to the first one per `viewpointCell` cell, then evenly
    /// subsampled to at most `maxViewpoints`, in input order.
    static func decimatedViewpoints(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        let limit: Float = 1_000_000
        var seen = Set<SIMD3<Int32>>()
        var kept: [SIMD3<Float>] = []
        for p in points where p.x.isFinite && p.y.isFinite && p.z.isFinite {
            let scaled = (p / viewpointCell).rounded(.down)
            let q = simd_clamp(scaled, SIMD3<Float>(repeating: -limit), SIMD3<Float>(repeating: limit))
            let key = SIMD3<Int32>(Int32(q.x), Int32(q.y), Int32(q.z))
            if seen.insert(key).inserted { kept.append(p) }
        }
        guard kept.count > maxViewpoints else { return kept }
        let every = (kept.count + maxViewpoints - 1) / maxViewpoints
        var thinned: [SIMD3<Float>] = []
        var i = 0
        while i < kept.count {
            thinned.append(kept[i])
            i += every
        }
        return thinned
    }

    /// Splits a mesh by the rule of `MeshCleanup.removingFloaters`: edge-connected components
    /// with less area than `minimumArea` or fewer than `minimumTriangles` triangles are
    /// removed, except the largest component, which is always kept. Both sides are compacted
    /// with `keepingFaces`; faces with an out-of-range index are in neither.
    static func splittingFloaters(_ mesh: MeshWithAttributes, minimumArea: Float,
                                  minimumTriangles: Int) -> (kept: MeshWithAttributes, removed: MeshWithAttributes) {
        let components = MeshCleanup.connectedComponents(mesh.mesh)
        guard let largest = components.largest else {
            return (mesh.keepingFaces([]), mesh.keepingFaces([]))
        }
        var keepComponent = [Bool](repeating: false, count: components.count)
        for c in 0..<components.count {
            let bigEnough = components.areas[c] >= minimumArea && components.triangleCounts[c] >= minimumTriangles
            keepComponent[c] = c == largest || bigEnough
        }
        let faces = mesh.triangleCount
        var keep = [Bool](repeating: false, count: faces)
        var drop = [Bool](repeating: false, count: faces)
        for (t, component) in components.faceComponent.enumerated() where component >= 0 && t < faces {
            if keepComponent[Int(component)] {
                keep[t] = true
            } else {
                drop[t] = true
            }
        }
        return (mesh.keepingFaces(keep), mesh.keepingFaces(drop))
    }

    /// The faces of a `HoleFill` result flagged inferred (all true in the result), compacted;
    /// an empty mesh with `isInferred == []` when there are none.
    static func inferredFaces(_ filled: MeshWithAttributes) -> MeshWithAttributes {
        guard let flags = filled.isInferred, flags.contains(true) else {
            let noClasses: [UInt8]? = filled.faceClass == nil ? nil : []
            return MeshWithAttributes(mesh: TriangleMesh(), faceClass: noClasses, vertexColor: nil, isInferred: [])
        }
        var inferred = filled.keepingFaces(flags)
        inferred.vertexColor = nil
        inferred.isInferred = [Bool](repeating: true, count: inferred.triangleCount)
        return inferred
    }

    /// `MeshSimplify` to `target` faces with class boundaries preserved. With `strict`, a
    /// result still over the target gets a second, relaxed pass (class boundaries free, weak
    /// boundary hold); a result still over after that is logged and kept.
    static func simplified(_ mesh: MeshWithAttributes, target: Int, strict: Bool) -> MeshWithAttributes {
        let first = MeshSimplify.Options(targetTriangleCount: target, preserveClassBoundaries: true)
        var result = MeshSimplify.simplify(mesh, options: first).mesh
        guard strict && result.triangleCount > target else { return result }
        let relaxed = MeshSimplify.Options(targetTriangleCount: target, boundaryWeight: 10,
                                           preserveClassBoundaries: false, minimumNormalDot: 0)
        result = MeshSimplify.simplify(result, options: relaxed).mesh
        if result.triangleCount > target {
            LogStore.shared.write("view mesh has \(result.triangleCount) faces, over its budget of \(target)",
                                  category: logCategory)
        }
        return result
    }

    /// Counts and bounds of a consolidation. Class counts are over the measured faces; a mesh
    /// without classes counts every face as unclassified.
    static func makeStats(chunkCount: Int, measured: MeshWithAttributes, view: MeshWithAttributes,
                          inferred: MeshWithAttributes) -> MeshStats {
        let faces = measured.triangleCount
        var counts: [String: Int] = [:]
        if let classes = measured.faceClass, classes.count == faces {
            var histogram = [Int](repeating: 0, count: 256)
            for value in classes { histogram[Int(value)] += 1 }
            for (value, count) in histogram.enumerated() where count > 0 {
                counts[String(value)] = count
            }
        } else if faces > 0 {
            counts[String(MeshWithAttributes.unclassified)] = faces
        }
        let box = measured.mesh.boundingBox
        let lower = box.isEmpty ? Vec3.zero : Vec3(box.min)
        let upper = box.isEmpty ? Vec3.zero : Vec3(box.max)
        return MeshStats(chunkCount: chunkCount, triangleCount: faces, viewTriangleCount: view.triangleCount,
                         inferredTriangleCount: inferred.triangleCount, classTriangleCounts: counts,
                         boundsMin: lower, boundsMax: upper)
    }
}
