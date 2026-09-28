import Foundation
import simd

/// Settings of `MeshConsolidator.consolidate` (docs/ARCHITECTURE.md 5.4). The defaults are the
/// full variant of `ConsolidateMeshStep`; the reduced variant sets `simplifyChunksBeforeMerge`
/// and a 150k view budget.
struct ConsolidationOptions: Equatable, Sendable {
    /// Vertices of neighboring chunks closer than this many meters are welded.
    var weldTolerance: Float = 0.005
    /// Islands with fewer triangles than this are floaters (the largest island is always kept).
    var minIslandTriangles = 50
    /// Islands with less area than this many square meters are floaters.
    var minIslandArea: Float = 0.01
    /// Holes whose boundary is shorter than this many meters are closed with inferred faces.
    var holeMaxPerimeter: Float = 0.5
    /// Most triangles in the view mesh (`ConsolidationResult.view`); 0 or less means no limit.
    var viewTriangleBudget = 300_000
    /// Advanced distance crop (build 6): faces that no camera position in `viewpoints` saw at a
    /// distance inside this window, in meters, are dropped from the derived meshes (raw data
    /// never changes). Nil means no crop.
    var depthWindow: ClosedRange<Float>? = nil
    /// Camera positions in world meters used by `depthWindow`, usually read from the pose
    /// tracks. With a window but no positions the crop is skipped and logged.
    var viewpoints: [SIMD3<Float>] = []
    /// Reduced variant (D17): each chunk is simplified to half its faces before merging, so the
    /// peak memory of the later stages scales down with the input.
    var simplifyChunksBeforeMerge = false

    /// The full-variant defaults.
    init() {}
}

/// Summary of one consolidation, stored as `derived/rooms/<r>/mesh_stats.json`.
struct MeshStats: Codable, Equatable, Sendable {
    /// Number of raw chunks (the latest snapshot per anchor) that went in.
    var chunkCount: Int
    /// Triangles of the measured mesh (`mesh.mchk`).
    var triangleCount: Int
    /// Triangles of the view mesh (`mesh_view.mchk`).
    var viewTriangleCount: Int
    /// Triangles of the inferred hole fills (`mesh_inferred.mchk`).
    var inferredTriangleCount: Int
    /// Measured triangles per ARMeshClassification raw value (0...7) written as text, for
    /// example "1" for wall.
    var classTriangleCounts: [String: Int]
    /// Lower corner of the measured mesh bounds, world meters (zero when the mesh is empty).
    var boundsMin: Vec3
    /// Upper corner of the measured mesh bounds, world meters (zero when the mesh is empty).
    var boundsMax: Vec3
}

/// `view` is simplified from `measured` only; `inferred` (small hole fills) stays at full
/// resolution in its own file; `floaters` are the islands `removingFloaters` dropped, kept so
/// Raw Scan shows the scan with its noise (simplified with the same budget share).
struct ConsolidationResult {
    /// Welded, cleaned world-space measured faces; never simplified; `isInferred` is nil.
    var measured: MeshWithAttributes
    /// Hole-fill faces only, full resolution; `isInferred` is all true.
    var inferred: MeshWithAttributes
    /// `measured` simplified to the view budget (or `measured` itself when under it).
    var view: MeshWithAttributes
    /// Small islands removed by cleanup, for Raw Scan only.
    var floaters: MeshWithAttributes
    /// Counts and bounds for `mesh_stats.json`.
    var stats: MeshStats
}

/// Turns the raw anchor-local mesh chunks of a room into derived world-space meshes: picks the
/// latest snapshot of every anchor, merges and welds them, removes floating islands (kept
/// apart), fills small holes (flagged inferred, kept apart) and simplifies a view copy of the
/// measured faces. Pure and nonisolated; call it off the main thread for real scans.
enum MeshConsolidator {
    /// Log category of this module.
    static let logCategory = "meshmodel"
    /// Raw chunk files larger than this are skipped as corrupt (ARKit chunks are well under
    /// 1 MB; the cap protects against a damaged or planted file).
    static let maxChunkFileBytes: Int64 = 64 * 1024 * 1024

    // MARK: - Public API

    /// Later folders win for the same anchorID; within a folder the highest updateCount wins.
    ///
    /// Reads every `mesh/*.mchk` file of each folder in order, one folder at a time, with
    /// `MeshChunkFile.decode`, and groups by the decoded anchor id (not the file name).
    /// Unreadable or corrupt files are skipped and logged; a folder without `mesh/` (for
    /// example `meshStripped`) contributes nothing. Chunks of anchors that ARKit removed during
    /// capture are kept (RESEARCH 3.1 gotcha 15). The result is ordered by first appearance
    /// (folder order, then file name), so it is deterministic.
    static func latestChunks(in folders: [RawScanFolder]) -> [MeshChunk] {
        var order: [UUID] = []
        var latest: [UUID: MeshChunk] = [:]
        for folder in folders {
            for chunk in folderChunks(folder) {
                if latest[chunk.anchorID] == nil { order.append(chunk.anchorID) }
                latest[chunk.anchorID] = chunk
            }
        }
        return order.compactMap { latest[$0] }
    }

    /// Converts Core chunks to MeshProcessing merge inputs: the anchor-local triangles, the
    /// anchor transform and the per-face classes (nil when a chunk has none or the wrong count).
    static func mergeChunks(_ chunks: [MeshChunk]) -> [MergeChunk] {
        chunks.map { chunk in
            let hasClasses = !chunk.classes.isEmpty && chunk.classes.count == chunk.faceCount
            return MergeChunk(localMesh: chunk.toTriangleMesh(world: false), anchorTransform: chunk.transform,
                              faceClass: hasClasses ? chunk.classes : nil, vertexColor: nil)
        }
    }

    /// ChunkMerge.merge, removingDegenerateAndDuplicateFaces, MeshCleanup.removingFloaters (the
    /// removed faces become `floaters`), HoleFill.fillSmallHoles (inferred faces split out),
    /// MeshSimplify of the measured faces only to viewTriangleBudget.
    ///
    /// Returns nil only when `isCancelled` returns true at one of the checks between stages.
    /// `ChunkMerge.merge` already ends with `removingDegenerateAndDuplicateFaces`, so that pass
    /// is not repeated. See `mergedWorldMesh` and `finish` for the two halves; the step calls
    /// them separately so the raw chunks are released before the heavy stages.
    static func consolidate(_ chunks: [MeshChunk], options: ConsolidationOptions,
                            isCancelled: () -> Bool) -> ConsolidationResult? {
        guard let merged = mergedWorldMesh(chunks, options: options, isCancelled: isCancelled) else { return nil }
        return finish(merged, chunkCount: chunks.count, options: options, isCancelled: isCancelled)
    }

    /// World transform only, no weld; for the quality check at Done (under 1 s for 500k faces).
    ///
    /// Positions are transformed by each chunk's anchor transform and appended; faces with an
    /// out-of-range index are dropped; a mirroring transform reverses the winding. Face classes
    /// are kept when any chunk has them (padded with unclassified for the others).
    static func fastWorldMesh(_ chunks: [MeshChunk]) -> MeshWithAttributes {
        var vertexTotal = 0
        var faceTotal = 0
        var hasClass = false
        for chunk in chunks {
            vertexTotal += chunk.positions.count
            faceTotal += chunk.faceCount
            if !chunk.classes.isEmpty && chunk.classes.count == chunk.faceCount { hasClass = true }
        }
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(vertexTotal)
        var indices: [UInt32] = []
        indices.reserveCapacity(3 * faceTotal)
        var classes: [UInt8] = []
        if hasClass { classes.reserveCapacity(faceTotal) }

        for chunk in chunks {
            let m = chunk.transform
            let base = UInt32(truncatingIfNeeded: positions.count)
            let limit = UInt32(truncatingIfNeeded: chunk.positions.count)
            for p in chunk.positions {
                let h = simd_mul(m, SIMD4<Float>(p, 1))
                positions.append(SIMD3<Float>(h.x, h.y, h.z))
            }
            let mirrored = simd_determinant(m) < 0
            let chunkClasses: [UInt8] = chunk.classes.count == chunk.faceCount ? chunk.classes : []
            for t in 0..<chunk.faceCount {
                let a = chunk.indices[3 * t]
                let b = chunk.indices[3 * t + 1]
                let c = chunk.indices[3 * t + 2]
                guard a < limit, b < limit, c < limit else { continue }
                indices.append(base + a)
                indices.append(base + (mirrored ? c : b))
                indices.append(base + (mirrored ? b : c))
                if hasClass {
                    classes.append(t < chunkClasses.count ? chunkClasses[t] : MeshWithAttributes.unclassified)
                }
            }
        }
        return MeshWithAttributes(mesh: TriangleMesh(positions: positions, indices: indices),
                                  faceClass: hasClass ? classes : nil)
    }

    // MARK: - Chunk files

    /// The chunks of one folder, one per anchor id (the highest `updateCount`; on a tie the
    /// first file by name), ordered by file name.
    static func folderChunks(_ folder: RawScanFolder) -> [MeshChunk] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder.meshURL,
                                                                     includingPropertiesForKeys: keys,
                                                                     options: [.skipsHiddenFiles]) else {
            return []
        }
        let files = urls.filter { $0.pathExtension.lowercased() == "mchk" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var order: [UUID] = []
        var best: [UUID: MeshChunk] = [:]
        var skipped = 0
        for url in files {
            guard let chunk = decodeChunk(at: url) else {
                skipped += 1
                continue
            }
            if let existing = best[chunk.anchorID] {
                if chunk.updateCount > existing.updateCount { best[chunk.anchorID] = chunk }
            } else {
                order.append(chunk.anchorID)
                best[chunk.anchorID] = chunk
            }
        }
        if skipped > 0 {
            LogStore.shared.write("skipped \(skipped) unreadable mesh chunk file(s) in \(folder.url.lastPathComponent)",
                                  category: logCategory)
        }
        return order.compactMap { best[$0] }
    }

    /// Decodes one `.mchk` file, or nil (logged) when it is not a regular file, is larger than
    /// `maxChunkFileBytes`, cannot be read or is malformed.
    static func decodeChunk(at url: URL) -> MeshChunk? {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { return nil }
            let size = Int64(values.fileSize ?? 0)
            guard size <= maxChunkFileBytes else {
                LogStore.shared.write("mesh chunk \(url.lastPathComponent) too large (\(size) bytes)", category: logCategory)
                return nil
            }
            return try MeshChunkFile.decode(try Data(contentsOf: url))
        } catch {
            LogStore.shared.write("mesh chunk \(url.lastPathComponent) unreadable: \(error)", category: logCategory)
            return nil
        }
    }
}
