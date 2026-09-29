import Foundation
import simd

/// Plain-Swift checks for MeshRecord (no XCTest). Synthetic `MeshChunk` values go through
/// `MeshStore.ingest(_:)` into scan folders under `FileManager.default.temporaryDirectory`
/// (removed at the end); no ARKit session, camera or network, fixed anchor ids and frame
/// times. The ARKit copy path is covered on device. `run()` returns one line per failing
/// check ("name: detail"); empty means all passed.
enum MeshRecordSelfTest {
    /// Failure lines and the number of checks run.
    final class Checks {
        /// Failure lines.
        private(set) var failures: [String] = []
        /// Checks run so far.
        private(set) var count = 0

        /// Records a failure when `condition` is false.
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            count += 1
            if !condition { failures.append(detail.isEmpty ? name : "\(name): \(detail)") }
        }
    }

    /// Frame time the test recordings start at.
    static let start: TimeInterval = 100

    /// Failing checks as "name: detail".
    static func run() -> [String] {
        let checks = Checks()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshRecordSelfTest-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            return ["setup: \(error.localizedDescription)"]
        }
        defer { try? FileManager.default.removeItem(at: base) }
        helperChecks(checks)
        do {
            try recordingChecks(checks, base: base)
            try edgeChecks(checks, base: base)
        } catch {
            checks.check("setup.folders", false, error.localizedDescription)
        }
        return checks.failures
    }

    // MARK: - Pure helpers

    /// World bounds, resident bytes and the saturating update count.
    static func helperChecks(_ t: Checks) {
        let chunk = square(anchor: 9, transform: rotatedTransform)
        let bounds = MeshStore.worldBounds(of: chunk)
        let low = isNear(bounds.min, SIMD3<Float>(1, 2, 2))
        let high = isNear(bounds.max, SIMD3<Float>(1, 3, 3))
        t.check("bounds.worldSpace", low && high, "min \(bounds.min) max \(bounds.max)")
        // 8 vectors of 16 bytes (4 positions, 4 normals), 6 UInt32 indices, 2 class bytes.
        let vectorBytes: Int = 8 * 16
        let expected: Int = vectorBytes + 6 * 4 + 2
        t.check("residentBytes.formula", MeshStore.residentBytes(of: chunk) == expected,
                "\(MeshStore.residentBytes(of: chunk)) != \(expected)")
        t.check("updateCount.saturates", MeshStore.nextUpdateCount(after: UInt32.max) == UInt32.max)
    }

    // MARK: - Recording, flush, stale, finish, evict

    /// The main recording flow in one folder whose `mesh/` subfolder is made by the first flush.
    static func recordingChecks(_ t: Checks, base: URL) throws {
        let folder = try makeFolder(in: base, name: "main", withMesh: false)
        let store = MeshStore()
        t.check("idle.notDue", !store.flushDue(now: start + 10))
        store.ingest(square(anchor: 1))
        t.check("idle.ingestIgnored", store.index.isEmpty && store.currentChunks().isEmpty)

        store.beginRecording(into: folder, profile: profile, startTimestamp: start)
        store.ingest(square(anchor: 1))
        let first = store.index[anchorID(1)]
        t.check("ingest.dirty", first?.isDirty == true && first?.isStale == false)
        t.check("ingest.updateCount", first?.updateCount == 1, "\(String(describing: first?.updateCount))")
        t.check("ingest.counts", store.stats.meshAnchors == 1 && store.stats.meshFaces == 2,
                "anchors \(store.stats.meshAnchors) faces \(store.stats.meshFaces)")
        t.check("ingest.resident", store.residentBytes == MeshStore.residentBytes(of: square(anchor: 1)))

        let bigger = strip(anchor: 1, quads: 3)
        store.ingest(bigger)
        let second = store.index[anchorID(1)]
        let live = store.currentChunks()
        t.check("reingest.replaces", live.count == 1 && live.first?.positions == bigger.positions, "\(live.count) chunks")
        t.check("reingest.bumpsUpdate", second?.updateCount == 2, "\(String(describing: second?.updateCount))")
        t.check("reingest.faces", store.stats.meshFaces == 6 && store.stats.meshAnchors == 1,
                "faces \(store.stats.meshFaces)")

        store.ingest(square(anchor: 2, transform: rotatedTransform))
        let rotated = store.index[anchorID(2)]
        let rotatedLow = isNear(rotated?.boundsMin, SIMD3<Float>(1, 2, 2))
        let rotatedHigh = isNear(rotated?.boundsMax, SIMD3<Float>(1, 3, 3))
        t.check("ingest.worldBounds", rotatedLow && rotatedHigh)
        store.ingest(MeshChunk(anchorID: anchorID(5), transform: matrix_identity_float4x4, updateCount: 0,
                               positions: [], indices: []))
        t.check("ingest.emptySkipped", store.index[anchorID(5)] == nil)

        t.check("flushDue.before3s", !store.flushDue(now: start + 2.9))
        t.check("flushDue.after3s", store.flushDue(now: start + MeshStore.flushInterval))
        store.tick(now: start + MeshStore.flushInterval)
        t.check("flush.wait", waitWrites(store))
        t.check("flush.createsMeshFolder", isDirectory(folder.meshURL))
        t.check("flush.onePerDirty", chunkFiles(folder).count == 2, "\(chunkFiles(folder).count) files")
        t.check("flush.clearsDirty", store.index.values.allSatisfy { !$0.isDirty })
        let decoded = readChunk(folder, anchor: 1)
        t.check("flush.anchorLocal", decoded?.positions == bigger.positions && decoded?.updateCount == 2,
                "\(String(describing: decoded?.updateCount))")
        let decodedRotated = readChunk(folder, anchor: 2)
        let transformKept = decodedRotated.map { Transform4($0.transform) == Transform4(rotatedTransform) } ?? false
        t.check("flush.transformKept", transformKept && decodedRotated?.positions == square(anchor: 2).positions)
        t.check("flushDue.cleanNotDue", !store.flushDue(now: start + 20))

        store.markStale([anchorID(1)])
        t.check("stale.marked", store.index[anchorID(1)]?.isStale == true)
        store.flushNow()
        t.check("stale.wait", waitWrites(store))
        t.check("stale.keepsFile", readChunk(folder, anchor: 1)?.updateCount == 2)
        t.check("stale.keepsChunk", store.currentChunks().contains { $0.anchorID == anchorID(1) })
        store.ingest(square(anchor: 1))
        let back = store.index[anchorID(1)]
        t.check("stale.readopted", back?.isStale == false && back?.updateCount == 3)

        store.flushNow()
        t.check("flushNow.wait", waitWrites(store))
        t.check("flushNow.writes", readChunk(folder, anchor: 1)?.updateCount == 3)
        t.check("flushNow.keepsRecording", store.isRecording)

        store.ingest(square(anchor: 3))
        let finished = waitFinish(store)
        t.check("finish.completes", finished)
        t.check("finish.flushesDirty", readChunk(folder, anchor: 3)?.updateCount == 1)
        t.check("finish.stopsRecording", !store.isRecording && !store.flushDue(now: start + 100))
        store.ingest(square(anchor: 4))
        store.flushNow()
        t.check("finish.laterWait", waitWrites(store))
        t.check("finish.ingestAfterWritesNothing", readChunk(folder, anchor: 4) == nil && store.index[anchorID(4)] == nil)
        t.check("finish.fileCount", chunkFiles(folder).count == 3, "\(chunkFiles(folder).count) files")
        t.check("finish.noFailures", store.stats.writeFailures == 0, "\(store.stats.writeFailures) failures")
        t.check("finish.secondCallCompletes", waitFinish(store))

        let before = store.index
        (store as ScanRecorder).releaseMemory()
        t.check("evict.emptiesChunks", store.currentChunks().isEmpty && store.residentBytes == 0)
        t.check("evict.keepsIndex", store.index.count == before.count && store.index.values.allSatisfy { $0.isEvicted },
                "\(store.index.count) of \(before.count)")
        t.check("evict.keepsStats", store.stats.meshAnchors == 3)
        store.evict()
        t.check("evict.twiceHarmless", store.currentChunks().isEmpty && store.index.count == before.count)
    }

    // MARK: - Edge cases

    /// Restart into a new folder, eviction while recording, and a discarded folder.
    static func edgeChecks(_ t: Checks, base: URL) throws {
        let store = MeshStore()
        t.check("finish.neverBegan", waitFinish(store))

        let first = try makeFolder(in: base, name: "restartA", withMesh: true)
        let second = try makeFolder(in: base, name: "restartB", withMesh: true)
        store.beginRecording(into: first, profile: profile, startTimestamp: start)
        store.ingest(square(anchor: 6))
        store.evict()
        t.check("evict.ignoredWhileRecording", store.currentChunks().count == 1)
        store.beginRecording(into: second, profile: profile, startTimestamp: start)
        t.check("restart.resets", store.index.isEmpty && store.residentBytes == 0 && store.isRecording)
        store.ingest(square(anchor: 7))
        t.check("restart.finish", waitFinish(store))
        t.check("restart.leftoverFlushed", readChunk(first, anchor: 6) != nil)
        t.check("restart.newFolder", readChunk(second, anchor: 7) != nil && readChunk(first, anchor: 7) == nil)

        let doomed = try makeFolder(in: base, name: "discarded", withMesh: true)
        let lost = MeshStore()
        lost.beginRecording(into: doomed, profile: profile, startTimestamp: start)
        lost.ingest(square(anchor: 8))
        try FileManager.default.removeItem(at: doomed.url)
        lost.flushNow()
        t.check("discarded.wait", waitWrites(lost))
        t.check("discarded.notRecreated", !FileManager.default.fileExists(atPath: doomed.url.path))
        t.check("discarded.failureCounted", lost.stats.writeFailures >= 1, "\(lost.stats.writeFailures)")
        t.check("discarded.finish", waitFinish(lost))
    }

    // MARK: - Fixtures

    /// Profile used by every test recording.
    static let profile = ScanProfile(mode: .room, settings: .defaults(for: .room))

    /// 90 degrees about +y, then a move to (1, 2, 3): local (1, 0, 0) lands at (1, 2, 2).
    static let rotatedTransform = simd_float4x4(columns: (SIMD4<Float>(0, 0, -1, 0), SIMD4<Float>(0, 1, 0, 0),
                                                          SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(1, 2, 3, 1)))

    /// A fixed anchor identifier.
    static func anchorID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012ld", n)) ?? UUID()
    }

    /// A unit square in the local xy plane: 4 vertices with normals, 2 faces with classes.
    static func square(anchor: Int, transform: simd_float4x4 = matrix_identity_float4x4) -> MeshChunk {
        let positions: [SIMD3<Float>] = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0),
                                         SIMD3<Float>(1, 1, 0), SIMD3<Float>(0, 1, 0)]
        let normals = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 1), count: 4)
        return MeshChunk(anchorID: anchorID(anchor), transform: transform, updateCount: 0, positions: positions,
                         normals: normals, indices: [0, 1, 2, 0, 2, 3], classes: [1, 2])
    }

    /// A strip of `quads` unit squares along x (2 faces each), without normals or classes.
    static func strip(anchor: Int, quads: Int) -> MeshChunk {
        var positions: [SIMD3<Float>] = []
        for column in 0...quads {
            let x = Float(column)
            positions.append(SIMD3<Float>(x, 0, 0))
            positions.append(SIMD3<Float>(x, 1, 0))
        }
        var indices: [UInt32] = []
        for quad in 0..<quads {
            let a = UInt32(quad * 2)
            let b: UInt32 = a + 1, c: UInt32 = a + 2, d: UInt32 = a + 3
            let corners: [UInt32] = [a, c, d, a, d, b]
            indices.append(contentsOf: corners)
        }
        return MeshChunk(anchorID: anchorID(anchor), transform: matrix_identity_float4x4, updateCount: 0,
                         positions: positions, indices: indices)
    }

    /// A scan folder under `base`, with or without its `mesh/` subfolder.
    static func makeFolder(in base: URL, name: String, withMesh: Bool) throws -> RawScanFolder {
        let folder = RawScanFolder(url: base.appendingPathComponent(name, isDirectory: true))
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        if withMesh {
            try FileManager.default.createDirectory(at: folder.meshURL, withIntermediateDirectories: true)
        }
        return folder
    }

    /// Waits (at most 5 s) until the store's writer ran everything queued so far.
    static func waitWrites(_ store: MeshStore) -> Bool {
        let done = DispatchSemaphore(value: 0)
        store.flushWrites(completion: { done.signal() })
        return done.wait(timeout: .now() + 5) == .success
    }

    /// Calls `finishRecording` and waits (at most 5 s) for its completion.
    static func waitFinish(_ store: MeshStore) -> Bool {
        let done = DispatchSemaphore(value: 0)
        store.finishRecording(completion: { done.signal() })
        return done.wait(timeout: .now() + 5) == .success
    }

    /// The decoded chunk file of an anchor, or nil when missing or unreadable.
    static func readChunk(_ folder: RawScanFolder, anchor: Int) -> MeshChunk? {
        guard let data = try? Data(contentsOf: folder.meshChunkURL(anchor: anchorID(anchor))) else { return nil }
        return try? MeshChunkFile.decode(data)
    }

    /// The `.mchk` files in the folder's `mesh/` (temporary files of atomic writes excluded).
    static func chunkFiles(_ folder: RawScanFolder) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.meshURL.path)) ?? []
        return names.filter { $0.hasSuffix(".mchk") && !$0.hasPrefix(".") }
    }

    /// True when `url` is an existing folder.
    static func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }

    /// True when both vectors exist and differ by at most 1e-5 per component.
    static func isNear(_ a: SIMD3<Float>?, _ b: SIMD3<Float>) -> Bool {
        guard let a else { return false }
        let delta = simd_abs(a - b)
        return delta.max() <= 1e-5
    }
}
