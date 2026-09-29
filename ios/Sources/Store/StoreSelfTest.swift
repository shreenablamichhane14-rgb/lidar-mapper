import Foundation
import simd

/// Plain-Swift checks for Store (no XCTest). Everything runs in a fresh folder under
/// `FileManager.default.temporaryDirectory` that is removed at the end (folders removed by
/// the code under test go through the trash and are deleted in the background); no ARKit,
/// camera or network, fixed dates and ids. `run()` returns one line per failing check
/// ("name: detail"); empty means all passed.
enum StoreSelfTest {
    /// Failing checks as "name: detail".
    static func run() -> [String] {
        let checks = Checks()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreSelfTest-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            return ["setup: \(StoreFiles.describe(error))"]
        }
        defer { try? FileManager.default.removeItem(at: base) }
        scanFolderChecks(checks, base: base)
        writerReaderChecks(checks, base: base)
        sealChecks(checks, base: base)
        discardRoomChecks(checks, base: base)
        manifestChecks(checks, base: base)
        editChecks(checks, base: base)
        editResetChecks(checks, base: base)
        usageChecks(checks, base: base)
        return checks.failures
    }

    /// InProgressScans: create, lookup, list, isSealed, discard.
    static func scanFolderChecks(_ t: Checks, base: URL) {
        let root = base.appendingPathComponent("InProgressA", isDirectory: true)
        let first = scanInfo(1)
        do {
            let folder = try InProgressScans.create(first, root: root)
            let allSubfolders = InProgressScans.subfolders.allSatisfy {
                StoreFiles.isDirectory(folder.url.appendingPathComponent($0, isDirectory: true))
            }
            t.check("create.subfolders", allSubfolders)
            t.check("create.scanJSON", RawScanReader(folder: folder).info() == first)
            var fresh = URL(fileURLWithPath: folder.url.path, isDirectory: true)
            fresh.removeAllCachedResourceValues()
            let values = try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey])
            t.check("create.excludedFromBackup", values.isExcludedFromBackup == true)
            t.check("create.existingThrows", throwsError { _ = try InProgressScans.create(first, root: root) })
            t.check("folder.lookup", (try? InProgressScans.folder(for: first.scanID, root: root)) == folder)
            t.check("folder.missingThrows", throwsError { _ = try InProgressScans.folder(for: fixedID(77), root: root) })

            let second = scanInfo(2)
            let sealedFolder = try InProgressScans.create(second, root: root)
            try ProjectStore.sealRawFolder(sealedFolder.url, now: fixedDate(3))
            let unreadable = root.appendingPathComponent(fixedID(3).uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: false)
            try Data("{ not json".utf8).write(to: unreadable.appendingPathComponent(InProgressScanInfo.fileName))
            let stray = root.appendingPathComponent("not-a-scan", isDirectory: true)
            try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: false)
            let listed = InProgressScans.list(root: root).map { $0.scanID }
            t.check("list.sealedAndUnsealed", listed == [first.scanID, second.scanID], "\(listed.count) listed")
            let sealedFlag = InProgressScans.isSealed(scanID: second.scanID, root: root)
            let unsealedFlag = InProgressScans.isSealed(scanID: first.scanID, root: root)
            t.check("isSealed", sealedFlag && !unsealedFlag)

            try InProgressScans.discard(scanID: first.scanID, root: root)
            t.check("discard.removesFolder", !StoreFiles.exists(folder.url))
            t.check("discard.idempotent", !throwsError { try InProgressScans.discard(scanID: first.scanID, root: root) })
        } catch {
            t.fail("scanFolders", error)
        }
    }

    /// RawScanWriter and RawScanReader: JSON Lines, torn and corrupt lines, unsafe paths,
    /// pose track, mesh chunks, atomic files, no parent creation, nested work, close.
    static func writerReaderChecks(_ t: Checks, base: URL) {
        let root = base.appendingPathComponent("InProgressB", isDirectory: true)
        do {
            let folder = try InProgressScans.create(scanInfo(10), root: root)
            let writer = RawScanWriter(folder: folder)
            let reader = RawScanReader(folder: folder)
            let records = [keyframe(1), keyframe(2), keyframe(3)]
            for record in records {
                writer.appendJSONLine(record, to: folder.keyframesLogURL)
            }
            t.check("writer.flush", waitFlush(writer))
            let firstRead = try reader.keyframes()
            t.check("jsonl.roundTrip3", firstRead == records, "\(firstRead.count) read")
            t.check("writer.counters", writer.bytesWritten > 0 && writer.failureCount == 0)

            var badPath = keyframe(4)
            badPath.imageFile = "../../etc/x"
            writer.appendJSONLine(badPath, to: folder.keyframesLogURL)
            writer.appendBytes(Data("{\"index\":5,\"timest".utf8), to: folder.keyframesLogURL)
            _ = waitFlush(writer)
            let rawLines = try RawScanReader.jsonLines(KeyframeRecord.self, at: folder.keyframesLogURL)
            t.check("jsonl.tornLastLineIgnored", rawLines.records.count == 4 && rawLines.skipped == 1,
                    "\(rawLines.records.count) records, \(rawLines.skipped) skipped")
            let safeRead = try reader.keyframes()
            t.check("reader.unsafePathDropped", safeRead == records, "\(safeRead.count) read")
            let recordLines = PackageCheck.recordProblems(folder)
            t.check("packageCheck.unsafeRecordPath", recordLines.contains { $0.hasPrefix("keyframe 4: unsafe") })

            let e1 = CaptureEvent(t: 1, kind: .note, detail: "first")
            let e3 = CaptureEvent(t: 3, kind: .tracking, detail: "third")
            writer.appendJSONLine(e1, to: folder.eventsLogURL)
            writer.appendBytes(Data("{\"t\":2,\"kind\":\"bogus\"}\n".utf8), to: folder.eventsLogURL)
            writer.appendJSONLine(e3, to: folder.eventsLogURL)
            _ = waitFlush(writer)
            let events = try RawScanReader.jsonLines(CaptureEvent.self, at: folder.eventsLogURL)
            t.check("jsonl.corruptMiddleSkipped", events.records == [e1, e3] && events.skipped == 1)

            var header = ByteWriter()
            PoseTrackFile.appendHeader(to: &header)
            writer.appendBytes(header.data, to: folder.poseTrackURL)
            var pose = matrix_identity_float4x4
            pose.columns.3 = SIMD4<Float>(0.5, 1.2, -2, 1)
            let p1 = PoseSample(timestamp: 10.5, transform: pose, tracking: 2, thermal: 0, exposureDuration: 0.01)
            let p2 = PoseSample(timestamp: 10.6, transform: matrix_identity_float4x4, tracking: 1, thermal: 1, exposureDuration: 0.02)
            var body = ByteWriter()
            PoseTrackFile.append(p1, to: &body)
            PoseTrackFile.append(p2, to: &body)
            writer.appendBytes(body.data, to: folder.poseTrackURL)
            _ = waitFlush(writer)
            let poses = try reader.poseSamples()
            t.check("poseTrack.twoSamples", poses == [p1, p2], "\(poses.count) samples")

            let chunk = MeshChunk(anchorID: fixedID(20), transform: pose, updateCount: 2,
                                  positions: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)],
                                  indices: [0, 1, 2])
            writer.writeFile(MeshChunkFile.encode(chunk), to: folder.meshChunkURL(anchor: chunk.anchorID))
            writer.writeFile(Data("MCHKbad".utf8), to: folder.meshChunkURL(anchor: fixedID(21)))
            _ = waitFlush(writer)
            t.check("meshChunks.skipCorrupt", reader.meshChunks() == [chunk])
            t.check("meshChunks.strictIsEmpty", reader.meshChunks(skipCorrupt: false).isEmpty)

            fileChecks(t, folder: folder, writer: writer, event: e1)
        } catch {
            t.fail("writerReader", error)
        }
    }

    /// Atomic whole-file writes, no parent creation, nested work, and close.
    static func fileChecks(_ t: Checks, folder: RawScanFolder, writer: RawScanWriter, event: CaptureEvent) {
        let blob = folder.url.appendingPathComponent("blob.bin", isDirectory: false)
        writer.writeFile(Data(repeating: 1, count: 4096), to: blob)
        writer.writeFile(Data(repeating: 2, count: 100), to: blob)
        _ = waitFlush(writer)
        t.check("writeFile.replacesWhole", (try? Data(contentsOf: blob)) == Data(repeating: 2, count: 100))
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.url.path)) ?? [])
        let expected: Set<String> = ["scan.json", "mesh", "keyframes", "depth", "photos", "keyframes.jsonl",
                                     "events.jsonl", "poses.ptrk", "blob.bin"]
        t.check("writeFile.noTemporaryFiles", names == expected, names.sorted().joined(separator: ","))

        let ghost = folder.url.appendingPathComponent("ghost", isDirectory: true)
        let failuresBefore = writer.failureCount
        writer.writeFile(Data([1, 2, 3]), to: ghost.appendingPathComponent("x.bin", isDirectory: false))
        writer.appendJSONLine(event, to: ghost.appendingPathComponent("y.jsonl", isDirectory: false))
        _ = waitFlush(writer)
        t.check("write.neverCreatesParents", !StoreFiles.exists(ghost) && writer.failureCount == failuresBefore + 2)

        let failing = writer.failureCount
        writer.perform { throw MapperError.ioFailed("self-test") }
        _ = waitFlush(writer)
        t.check("perform.errorCounted", writer.failureCount == failing + 1)

        let nested = folder.url.appendingPathComponent("nested.bin", isDirectory: false)
        writer.perform { writer.writeFile(Data([9]), to: nested) }
        writer.close()
        writer.appendJSONLine(keyframe(6), to: folder.keyframesLogURL)
        _ = waitFlush(writer)
        t.check("perform.nestedWriteBeforeClose", StoreFiles.exists(nested))
        t.check("close.dropsLaterWrites", writer.droppedAfterClose == 1, "\(writer.droppedAfterClose) dropped")
        let after = try? RawScanReader.jsonLines(KeyframeRecord.self, at: folder.keyframesLogURL)
        t.check("close.nothingWritten", after?.records.count == 4)
    }
}

/// Self-test helpers: result collection, fixed ids and dates, fixtures and waits.
extension StoreSelfTest {
    /// Collects results on the test thread.
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

        /// Records a failure for an unexpected error.
        func fail(_ name: String, _ error: Error) {
            count += 1
            failures.append("\(name): unexpected error \(StoreFiles.describe(error))")
        }
    }

    /// Thread-safe counter for the concurrent manifest check.
    final class Counter: @unchecked Sendable {
        /// Protects `count`.
        private let lock = NSLock()
        /// The count.
        private var count = 0

        /// Adds one.
        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        /// The current count.
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    /// A fixed UUID for `n` (deterministic ids).
    static func fixedID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012ld", n)) ?? UUID()
    }

    /// A fixed date `seconds` after a fixed epoch (whole seconds survive ISO 8601).
    static func fixedDate(_ seconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(1_790_000_000 + seconds))
    }

    /// A scan record numbered `n` (scan id `fixedID(n)`, started at `fixedDate(n)`).
    static func scanInfo(_ n: Int) -> InProgressScanInfo {
        InProgressScanInfo(scanID: fixedID(n), projectID: fixedID(900), sessionID: fixedID(800), roomID: fixedID(5000 + n),
                           kind: .room, mode: .room, startedAt: fixedDate(n))
    }

    /// A keyframe record with the standard image and depth paths for `index`.
    static func keyframe(_ index: Int) -> KeyframeRecord {
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4<Float>(Float(index) * 0.25, 1.5, -0.5, 1)
        let intrinsics = Intrinsics(fx: 1450, fy: 1452, cx: 958, cy: 721, width: 1920, height: 1440)
        return KeyframeRecord(index: index, timestamp: Double(index) * 0.5, transform: Transform4(pose),
                              intrinsics: intrinsics, imageFile: RawScanFolder.keyframeImagePath(index),
                              depthFile: RawScanFolder.depthPath(index), exposureDuration: 0.01, exposureOffset: 0,
                              ambientIntensity: 1000, angularSpeed: 0.1, trackingNormal: true)
    }

    /// A captured room record in `session`.
    static func roomRecord(_ id: UUID, session: UUID) -> RoomRecord {
        RoomRecord(id: id, name: "", sessionID: session, floorIndex: 0, status: .captured, capturedRoomID: nil,
                   quality: nil, hasMeshPass: false, keyframeCount: 1, capturedAt: fixedDate(10),
                   frameLink: .projectFrame(sessionID: session))
    }

    /// Waits (at most 5 s) until the writer ran everything queued so far.
    static func waitFlush(_ writer: RawScanWriter) -> Bool {
        let done = DispatchSemaphore(value: 0)
        writer.flush(completion: { done.signal() })
        return done.wait(timeout: .now() + 5) == .success
    }

    /// True when `body` throws.
    static func throwsError(_ body: () throws -> Void) -> Bool {
        do {
            try body()
            return false
        } catch {
            return true
        }
    }

    /// A package `<id>.mapperproj` directly under `base` with its four folders and a manifest
    /// created at `fixedDate(created)`.
    static func makePackage(in base: URL, created: Int) throws -> (ProjectPackage, ProjectManifest) {
        let manifest = ProjectManifest.new(kind: .room, name: "Self Test", now: fixedDate(created))
        let name = manifest.id.uuidString + "." + ProjectPackage.fileExtension
        let package = ProjectPackage(root: base.appendingPathComponent(name, isDirectory: true))
        for folder in [package.rawURL, package.derivedURL, package.editsURL, package.exportsURL] {
            try ProjectStore.ensureDirectory(folder)
        }
        try ProjectStore.writeManifest(manifest, to: package)
        return (package, manifest)
    }
}
