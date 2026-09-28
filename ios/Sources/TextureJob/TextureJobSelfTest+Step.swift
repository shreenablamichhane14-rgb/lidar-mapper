import CoreGraphics
import Foundation
import simd

/// TextureJob self-test cases for the slippable parts: `KeyframeLoader` (pure rules and real
/// files) and `TextureLowStep` (pure rules, input hash, and whole runs on a synthetic room:
/// one quad seen by one 160 x 120 keyframe). If those two types slip to build 5, this file
/// and the four calls in `run()` go with them.
extension TextureJobSelfTest {
    // MARK: - KeyframeLoader rules

    /// `subsample`, `candidates`, `isUsable` and `aspectMatches`.
    static func inputCases(_ r: Recorder) {
        r.check("loader.subsampleEven", KeyframeLoader.subsample(count: 10, max: 4) == [0, 3, 6, 9],
                "\(KeyframeLoader.subsample(count: 10, max: 4))")
        r.check("loader.subsampleAll", KeyframeLoader.subsample(count: 3, max: 5) == [0, 1, 2])
        r.check("loader.subsampleEmpty", KeyframeLoader.subsample(count: 0, max: 5).isEmpty
                && KeyframeLoader.subsample(count: 5, max: 0).isEmpty)
        r.check("loader.subsampleOne", KeyframeLoader.subsample(count: 7, max: 1) == [3])
        let big = KeyframeLoader.subsample(count: 1000, max: 150)
        var increasing = true
        for i in 1..<big.count where big[i] <= big[i - 1] { increasing = false }
        r.check("loader.subsampleSpread", big.count == 150 && big.first == 0 && big.last == 999 && increasing,
                "\(big.count) picks, first \(String(describing: big.first)), last \(String(describing: big.last))")

        var records: [KeyframeRecord] = []
        records.append(keyframeRecord(index: 2, x: 0.2))
        records.append(keyframeRecord(index: 0, x: 0))
        var limited = keyframeRecord(index: 1, x: 0.1)
        limited.trackingNormal = false
        records.append(limited)
        var noFocal = keyframeRecord(index: 3, x: 0.3)
        noFocal.intrinsics.fx = 0
        records.append(noFocal)
        var badPose = keyframeRecord(index: 4, x: 0.4)
        badPose.transform = Transform4(elements: [Float](repeating: Float.nan, count: 16)) ?? Transform4.identity
        records.append(badPose)
        let kept = KeyframeLoader.candidates(records).map { $0.index }
        r.check("loader.candidates", kept == [0, 2], "\(kept)")
        var noSize = keyframeRecord(index: 5, x: 0)
        noSize.intrinsics.width = 0
        r.check("loader.noSizeUnusable", !KeyframeLoader.isUsable(noSize))
        let full = SIMD2<Float>(1920, 1440)
        r.check("loader.aspectSame", KeyframeLoader.aspectMatches(imageWidth: 1920, imageHeight: 1440, resolution: full))
        r.check("loader.aspectScaled", KeyframeLoader.aspectMatches(imageWidth: 960, imageHeight: 720, resolution: full))
        r.check("loader.aspectRotated", !KeyframeLoader.aspectMatches(imageWidth: 1440, imageHeight: 1920, resolution: full))
        r.check("loader.aspectEmpty", !KeyframeLoader.aspectMatches(imageWidth: 0, imageHeight: 1440, resolution: full))
    }

    /// Reads real folders: records with normal tracking and an existing image load lazily,
    /// `maxCount` subsamples, several folders combine, and wrong-aspect images are skipped.
    static func loaderFileCases(_ r: Recorder) {
        do {
            let base = try makeTemporaryFolder("loader")
            defer { try? FileManager.default.removeItem(at: base) }
            let first = RawScanFolder(url: base.appendingPathComponent("first", isDirectory: true))
            var limited = keyframeRecord(index: 1, x: 0.1)
            limited.trackingNormal = false
            let firstRecords = [keyframeRecord(index: 0, x: 0), limited, keyframeRecord(index: 2, x: 0.2),
                                keyframeRecord(index: 3, x: 0.3)]
            try writeKeyframes(firstRecords, images: [0, 1, 2], into: first, width: 160, height: 120)
            let loaded = try KeyframeLoader.keyframes(in: first, maxCount: 10)
            r.check("loader.fileCount", loaded.count == 2, "\(loaded.count) keyframes")
            if loaded.count == 2 {
                r.check("loader.fileImage", loaded[0].image.width == 160 && loaded[0].image.height == 120)
                r.check("loader.fileResolution", loaded[0].imageResolution == SIMD2<Float>(160, 120))
                r.near("loader.filePose", loaded[1].cameraToWorld.columns.3.x, 0.2, 1e-6)
                r.check("loader.fileTimes", loaded[0].timestamp == 0 && loaded[1].timestamp == 2)
                r.check("loader.fileExposure", loaded[0].exposureOffset == 0.5)
                r.near("loader.fileIntrinsics", loaded[0].intrinsics.columns.2.x, 80, 1e-6)
            }
            let one = try KeyframeLoader.keyframes(in: first, maxCount: 1)
            r.check("loader.fileMaxCount", one.count == 1)

            let second = RawScanFolder(url: base.appendingPathComponent("second", isDirectory: true))
            try writeKeyframes([keyframeRecord(index: 0, x: 1)], images: [0], into: second, width: 160, height: 120)
            let report = KeyframeLoader.load(inFolders: [first, second], maxCount: 10)
            r.check("loader.foldersCombined", report.keyframes.count == 3 && report.candidates == 3
                    && report.unreadable == 0, "\(report.keyframes.count) of \(report.candidates)")

            let rotated = RawScanFolder(url: base.appendingPathComponent("rotated", isDirectory: true))
            try writeKeyframes([keyframeRecord(index: 0, x: 0)], images: [0], into: rotated, width: 120, height: 160)
            let wrong = KeyframeLoader.load(inFolders: [rotated], maxCount: 10)
            r.check("loader.wrongAspectSkipped", wrong.keyframes.isEmpty && wrong.unreadable == 1)

            let missing = RawScanFolder(url: base.appendingPathComponent("missing", isDirectory: true))
            let none = try KeyframeLoader.keyframes(in: missing, maxCount: 10)
            r.check("loader.missingFolderEmpty", none.isEmpty)
            let text = base.appendingPathComponent("note.jpg", isDirectory: false)
            try Data("not an image".utf8).write(to: text)
            r.check("loader.notAnImage", KeyframeLoader.lazyImage(at: text) == nil)
        } catch {
            r.fail("loader.files", error)
        }
    }

    // MARK: - TextureLowStep rules

    /// Budgets, variant rule, options, retry, targets, percent and the input hash.
    static func stepRuleCases(_ r: Recorder) {
        let session = fixedID(30)
        let step = TextureLowStep(room: roomRecord(fixedID(31), session: session), folders: [])
        r.check("step.id", step.id == .textureLow)
        r.check("step.budgets", step.memoryBudgetBytes == 600_000_000 && step.reducedMemoryBudgetBytes == 350_000_000)
        r.check("step.reducedBelowBudget", TextureLowStep.usesReducedVariant(availableMemory: 599_999_999))
        r.check("step.fullAtBudget", !TextureLowStep.usesReducedVariant(availableMemory: 600_000_000)
                && !TextureLowStep.usesReducedVariant(availableMemory: UInt64.max))
        r.check("step.options", TextureLowStep.options(reduced: false).atlasSize == 2048
                && TextureLowStep.options(reduced: true).atlasSize == 1024)
        r.near("step.retryHalves", TextureLowStep.retryOptions(TextureDensity.textured.options).texelsPerMeter, 50, 0)
        var dense = TXOptions()
        dense.texelsPerMeter = 12
        r.near("step.retryFloor", TextureLowStep.retryOptions(dense).texelsPerMeter, 10, 0)
        r.check("step.viewTarget", TextureLowStep.viewTriangleTarget(reduced: true) == 150_000
                && TextureLowStep.viewTriangleTarget(reduced: false) == nil)
        r.check("step.percent", TextureLowStep.percent(0.874) == 87 && TextureLowStep.percent(Float.nan) == 0
                && TextureLowStep.percent(2) == 100)
        if let result = storeResult(pageCount: 2) {
            r.check("step.texturedFaces", TextureLowStep.texturedFaceCount(result) == 2)
        }
        do {
            let base = try makeTemporaryFolder("hash")
            defer { try? FileManager.default.removeItem(at: base) }
            let package = try makePackage(in: base, id: 32)
            let room = fixedID(31)
            let ctx = context(package, available: 2_000_000_000, isCancelled: { false }, progress: { _ in })
            r.check("step.upstreamNone", TextureLowStep.upstreamHash(package, room: room) == "-")
            let before = try step.inputHash(ctx)
            let again = try step.inputHash(ctx)
            r.check("step.hashStable", again == before)
            try writeStamp(package, room: fixedID(99), hash: "aaaa")
            let otherRoom = try step.inputHash(ctx)
            r.check("step.hashOtherRoom", otherRoom == before)
            try writeStamp(package, room: room, hash: "bbbb")
            r.check("step.upstreamRead", TextureLowStep.upstreamHash(package, room: room) == "bbbb")
            let after = try step.inputHash(ctx)
            r.check("step.hashFollowsMesh", after != before)
            let folder = RawScanFolder(url: base.appendingPathComponent("raw", isDirectory: true))
            try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.url.appendingPathComponent("poses.ptrk", isDirectory: false))
            let withFolder = TextureLowStep(room: roomRecord(room, session: session), folders: [folder])
            let rawHash = try withFolder.inputHash(ctx)
            r.check("step.hashFollowsRaw", rawHash != after)
        } catch {
            r.fail("step.hash", error)
        }
    }

    // MARK: - TextureLowStep runs

    /// Whole runs on a synthetic room: full and reduced variants write one page of the right
    /// width that loads with 2 faces; cancellation before and during the bake, low memory,
    /// no mesh, no keyframes (which also removes an older texture) and a keyframe that sees
    /// nothing.
    static func stepRunCases(_ r: Recorder) {
        do {
            let base = try makeTemporaryFolder("run")
            defer { try? FileManager.default.removeItem(at: base) }
            let package = try makePackage(in: base, id: 40)
            let session = fixedID(41)
            let roomA = fixedID(42)
            let folderA = try syntheticRoom(package, session: session, room: roomA, facing: true)
            let stepA = TextureLowStep(room: roomRecord(roomA, session: session), folders: [folderA])
            var values: [Double] = []
            let ctx = context(package, available: 2_000_000_000, isCancelled: { false }, progress: { values.append($0) })
            let outcome = try stepA.execute(ctx)
            if case let .textured(pages, faces, coverage) = outcome {
                r.check("run.pages", pages == 1 && faces == 2, "\(pages) pages, \(faces) faces")
                r.near("run.coverage", coverage, 1, 0.01)
            } else {
                r.check("run.textured", false, "\(outcome)")
            }
            var monotonic = true
            for i in 1..<Swift.max(1, values.count) where values[i] < values[i - 1] { monotonic = false }
            r.check("run.progress", values.last == 1 && monotonic && values.count >= 4, "\(values.count) updates")
            let loaded = try TextureStore.load(package, room: roomA)
            r.check("run.loads", loaded?.faceCount == 2 && loaded?.pageParts().first?.positions.count == 6)
            r.check("run.fullWidth", imageSize(at: TextureStore.pageURL(package, room: roomA, page: 0))?.width == 2048)

            let reducedCtx = context(package, available: 599_999_999, isCancelled: { false }, progress: { _ in })
            let reduced = try stepA.execute(reducedCtx)
            r.check("run.reduced", reduced == .textured(pages: 1, faces: 2, coverage: reducedCoverage(reduced)))
            r.check("run.reducedWidth", imageSize(at: TextureStore.pageURL(package, room: roomA, page: 0))?.width == 1024)

            let lowCtx = context(package, available: 100_000_000, isCancelled: { false }, progress: { _ in })
            let lowError = thrownError { _ = try stepA.execute(lowCtx) }
            r.check("run.outOfMemory", lowError == MapperError.outOfMemory(step: .textureLow), "\(String(describing: lowError))")
            let stopCtx = context(package, available: 2_000_000_000, isCancelled: { true }, progress: { _ in })
            let stopError = thrownError { _ = try stepA.execute(stopCtx) }
            r.check("run.cancelledBefore", stopError == MapperError.cancelled, "\(String(describing: stopError))")

            let roomB = fixedID(43)
            let folderB = try syntheticRoom(package, session: session, room: roomB, facing: true)
            let stepB = TextureLowStep(room: roomRecord(roomB, session: session), folders: [folderB])
            let counter = TextureSelfTestCounter(allowed: 3)
            let midCtx = context(package, available: 2_000_000_000, isCancelled: { counter.next() }, progress: { _ in })
            let midError = thrownError { _ = try stepB.execute(midCtx) }
            r.check("run.cancelledDuringBake", midError == MapperError.cancelled, "\(String(describing: midError))")
            r.check("run.cancelledWritesNothing", !TextureStore.exists(package, room: roomB))

            let emptyStep = TextureLowStep(room: roomRecord(roomA, session: session), folders: [])
            let noKeyframes = try emptyStep.execute(ctx)
            r.check("run.noKeyframes", noKeyframes == .noKeyframes, "\(noKeyframes)")
            r.check("run.noKeyframesRemovesOld", !TextureStore.exists(package, room: roomA))

            let roomC = fixedID(44)
            let folderC = try syntheticRoom(package, session: session, room: roomC, facing: false)
            let stepC = TextureLowStep(room: roomRecord(roomC, session: session), folders: [folderC])
            let nothing = try stepC.execute(ctx)
            r.check("run.nothingTextured", nothing == .nothingTextured, "\(nothing)")
            r.check("run.nothingWritesNothing", !TextureStore.exists(package, room: roomC))

            let stepD = TextureLowStep(room: roomRecord(fixedID(45), session: session), folders: [folderA])
            let noMesh = try stepD.execute(ctx)
            r.check("run.noMesh", noMesh == .noMesh, "\(noMesh)")
        } catch {
            r.fail("run", error)
        }
    }

    // MARK: - Fixtures

    /// A room record in `session`.
    static func roomRecord(_ id: UUID, session: UUID) -> RoomRecord {
        RoomRecord(id: id, name: "", sessionID: session, floorIndex: 0, status: .captured, capturedRoomID: nil,
                   quality: nil, hasMeshPass: false, keyframeCount: 1, capturedAt: fixedDate(10),
                   frameLink: .projectFrame(sessionID: session))
    }

    /// A step context for `package` with a fixed manifest.
    static func context(_ package: ProjectPackage, available: UInt64, isCancelled: @escaping () -> Bool,
                        progress: @escaping (Double) -> Void) -> StepContext {
        var manifest = ProjectManifest.new(kind: .room, name: "", now: fixedDate(0))
        manifest.id = fixedID(39)
        return StepContext(package: package, manifest: manifest, availableMemory: available,
                           isCancelled: isCancelled, progress: progress)
    }

    /// A keyframe record for a 160 x 120 image (focal 100) at x = `x` looking down -z, one
    /// second per index, normal tracking.
    static func keyframeRecord(index: Int, x: Float) -> KeyframeRecord {
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4<Float>(x, 0, 0, 1)
        return KeyframeRecord(index: index, timestamp: Double(index), transform: Transform4(pose),
                              intrinsics: Intrinsics(fx: 100, fy: 100, cx: 80, cy: 60, width: 160, height: 120),
                              imageFile: RawScanFolder.keyframeImagePath(index), depthFile: nil,
                              exposureDuration: 0.01, exposureOffset: 0.5, ambientIntensity: 1000,
                              angularSpeed: 0.1, trackingNormal: true)
    }

    /// Writes `records` as keyframes.jsonl into `folder` (created) plus a checkerboard JPEG of
    /// `width` x `height` for each record index listed in `images`.
    static func writeKeyframes(_ records: [KeyframeRecord], images: [Int], into folder: RawScanFolder,
                               width: Int, height: Int) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder.url.appendingPathComponent("keyframes", isDirectory: true),
                               withIntermediateDirectories: true)
        guard let image = checkerImage(width: width, height: height),
              let jpeg = TextureStore.jpegData(image, quality: 0.9) else {
            throw TextureJobError.encodingFailed("self-test keyframe")
        }
        for index in images {
            try jpeg.write(to: folder.url.appendingPathComponent(RawScanFolder.keyframeImagePath(index), isDirectory: false))
        }
        var lines = Data()
        for record in records {
            lines.append(try ProjectStore.encoder.encode(record))
            lines.append(UInt8(ascii: "\n"))
        }
        try lines.write(to: folder.keyframesLogURL)
    }

    /// A room with a 0.8 x 0.6 m quad at z = -1.5 facing +z as its view mesh, and one keyframe
    /// at the origin looking down -z (`facing`) or turned around to +z. Returns the raw folder.
    static func syntheticRoom(_ package: ProjectPackage, session: UUID, room: UUID, facing: Bool) throws -> RawScanFolder {
        let folder = RawScanFolder(url: package.rawRoomURL(session: session, room: room))
        var record = keyframeRecord(index: 0, x: 0)
        if !facing {
            let turned = simd_float4x4(columns: (SIMD4<Float>(-1, 0, 0, 0), SIMD4<Float>(0, 1, 0, 0),
                                                 SIMD4<Float>(0, 0, -1, 0), SIMD4<Float>(0, 0, 0, 1)))
            record.transform = Transform4(turned)
        }
        try writeKeyframes([record], images: [0], into: folder, width: 160, height: 120)
        let positions: [SIMD3<Float>] = [SIMD3<Float>(-0.4, -0.3, -1.5), SIMD3<Float>(0.4, -0.3, -1.5),
                                         SIMD3<Float>(0.4, 0.3, -1.5), SIMD3<Float>(-0.4, 0.3, -1.5)]
        let quad = MeshWithAttributes(mesh: TriangleMesh(positions: positions, indices: [0, 1, 2, 0, 2, 3]))
        try FileManager.default.createDirectory(at: package.derivedRoomURL(room), withIntermediateDirectories: true)
        let data = MeshChunkFile.encode(MeshModelStore.chunk(from: quad, id: room))
        try data.write(to: MeshModelStore.viewURL(package, room: room))
        return folder
    }

    /// An opaque checkerboard (10 pixel cells, two tones) so the keyframe has texture.
    static func checkerImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(red: 0.9, green: 0.8, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.2, green: 0.3, blue: 0.5, alpha: 1)
        let cell = 10
        for row in 0..<((height + cell - 1) / cell) {
            for column in 0..<((width + cell - 1) / cell) where (row + column) % 2 == 0 {
                context.fill(CGRect(x: column * cell, y: row * cell, width: cell, height: cell))
            }
        }
        return context.makeImage()
    }

    /// Writes `derived/index.json` with one `consolidateMesh` stamp for `room`.
    static func writeStamp(_ package: ProjectPackage, room: UUID, hash: String) throws {
        let stamp = DerivedStamp(step: .consolidateMesh, subject: room, pipelineVersion: ProjectManifest.currentPipelineVersion,
                                 inputHash: hash, createdAt: fixedDate(5))
        try ProjectStore.writeJSON(DerivedIndex(stamps: [stamp]), to: package.derivedIndexURL)
    }

    /// The `MapperError` `body` throws, or nil when it returns or throws something else.
    static func thrownError(_ body: () throws -> Void) -> MapperError? {
        do {
            try body()
            return nil
        } catch let error as MapperError {
            return error
        } catch {
            return nil
        }
    }

    /// The coverage of a `.textured` outcome (so an equality check ignores the exact value).
    static func reducedCoverage(_ outcome: TextureLowStep.Outcome) -> Float {
        if case let .textured(_, _, coverage) = outcome { return coverage }
        return -1
    }
}

/// A thread-safe cancel check for the self-test: false for the first `allowed` calls, then
/// true (the step's own checks come first, so the cancel lands inside the bake).
final class TextureSelfTestCounter: @unchecked Sendable {
    /// Guards `calls`.
    private let lock = NSLock()
    /// Calls so far.
    private var calls = 0
    /// Calls answered with false.
    private let allowed: Int

    /// A counter that allows `allowed` calls.
    init(allowed: Int) {
        self.allowed = allowed
    }

    /// Counts a call; true once more than `allowed` calls were made.
    func next() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return calls > allowed
    }
}
