import Foundation
import simd

/// Plain-Swift checks for Core (no XCTest), run at launch in debug builds. `run()` returns
/// one line per failing check; empty means all passed.
enum CoreSelfTest {
    /// Failing checks as "name: detail".
    static func run() -> [String] {
        var failures: [String] = []

        /// Records a failure when `condition` is false.
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if !condition { failures.append(detail.isEmpty ? name : "\(name): \(detail)") }
        }

        /// Encodes and decodes with the store's coders and checks equality.
        func roundTrip<T: Codable & Equatable>(_ name: String, _ value: T) {
            do {
                let data = try ProjectStore.encoder.encode(value)
                check(name, try ProjectStore.decoder.decode(T.self, from: data) == value)
            } catch {
                check(name, false, "\(error)")
            }
        }

        /// Checks that `body` throws.
        func expectThrows(_ name: String, _ body: () throws -> Void) {
            do {
                try body()
                check(name, false, "did not throw")
            } catch {
                return
            }
        }

        // Transform4
        var pose = simd_float4x4(simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3<Float>(0.2, 1, 0.1))))
        pose.columns.3 = SIMD4<Float>(1.5, -0.25, 3, 1)
        check("transform.simdRoundTrip", Transform4(Transform4(pose).simd) == Transform4(pose))
        check("transform.translation", Transform4(pose).translation == SIMD3<Float>(1.5, -0.25, 3))
        roundTrip("transform.json", Transform4(pose))
        expectThrows("transform.rejects15") {
            let bad = Data("{\"m\":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0]}".utf8)
            _ = try ProjectStore.decoder.decode(Transform4.self, from: bad)
        }
        roundTrip("vec3.json", Vec3(x: 1, y: -2, z: 3.5))

        // Intrinsics (ARKit convention: -Z forward, v down)
        let k = Intrinsics(fx: 1450, fy: 1452, cx: 958, cy: 721, width: 1920, height: 1440)
        var worst: Float = 0
        for pixel in [SIMD2<Float>(0, 0), SIMD2<Float>(1919, 1439), SIMD2<Float>(958.5, 721.25), SIMD2<Float>(300, 1200)] {
            for depth: Float in [0.5, 3.7] {
                let p = k.unproject(pixel: pixel, depth: depth)
                if let q = k.project(cameraPoint: p) { worst = max(worst, simd_length(q - pixel)) } else { worst = .infinity }
            }
        }
        check("intrinsics.roundTrip", worst < 1e-3, "error \(worst) px")
        check("intrinsics.behindIsNil", k.project(cameraPoint: SIMD3<Float>(0, 0, 1)) == nil)
        check("intrinsics.center", k.project(cameraPoint: SIMD3<Float>(0, 0, -2)) == SIMD2<Float>(958, 721))
        check("intrinsics.upIsSmallerV", (k.project(cameraPoint: SIMD3<Float>(0, 0.5, -2))?.y ?? 1e9) < 721)
        let world = SIMD3<Float>(0.3, 1.1, 1.2)
        let camPoint = simd_mul(pose.inverse, SIMD4<Float>(world, 1))
        let viaWorld = k.project(worldPoint: world, cameraToWorld: pose)
        let viaCamera = k.project(cameraPoint: SIMD3<Float>(camPoint.x, camPoint.y, camPoint.z))
        check("intrinsics.worldMatchesCamera", viaWorld == viaCamera)
        let depthK = k.scaled(toWidth: 256, height: 192)
        let expectedFx: Float = 1450.0 * 256.0 / 1920.0
        let expectedCy: Float = 721.0 * 192.0 / 1440.0
        let fxError: Float = abs(depthK.fx - expectedFx)
        let cyError: Float = abs(depthK.cy - expectedCy)
        let scaledSizeOK = depthK.width == 256 && depthK.height == 192
        check("intrinsics.scaled", fxError < 1e-3 && cyError < 1e-3 && scaledSizeOK)
        let fromMatrix = Intrinsics(matrix: k.matrix, width: 1920, height: 1440)
        check("intrinsics.matrix", fromMatrix == k)

        // MeshChunkFile
        let chunk = MeshChunk(anchorID: UUID(), transform: pose, updateCount: 7,
                              positions: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)],
                              normals: [SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 0, 0)],
                              indices: [0, 1, 2, 0, 2, 3], classes: [1, 5])
        let encoded = MeshChunkFile.encode(chunk)
        check("mchk.size", encoded.count == MeshChunkFile.headerSize + 4 * 24 + 2 * 13, "\(encoded.count)")
        check("mchk.roundTrip", (try? MeshChunkFile.decode(encoded)) == chunk)
        let bare = MeshChunk(anchorID: UUID(), transform: matrix_identity_float4x4, updateCount: 0,
                             positions: chunk.positions, indices: chunk.indices)
        check("mchk.bareRoundTrip", (try? MeshChunkFile.decode(MeshChunkFile.encode(bare))) == bare)
        check("mchk.sliceRoundTrip", (try? MeshChunkFile.decode((Data([9, 9]) + encoded).dropFirst(2))) == chunk)
        expectThrows("mchk.truncated") { _ = try MeshChunkFile.decode(encoded.prefix(encoded.count - 1)) }
        expectThrows("mchk.headerOnly") { _ = try MeshChunkFile.decode(encoded.prefix(20)) }
        expectThrows("mchk.badMagic") { _ = try MeshChunkFile.decode(Data("XXXX".utf8) + encoded.dropFirst(4)) }
        var badIndex = chunk
        badIndex.indices[5] = 9
        expectThrows("mchk.indexRange") { _ = try MeshChunkFile.decode(MeshChunkFile.encode(badIndex)) }
        let worldFirst = chunk.worldPositions.first ?? .zero
        check("mchk.world", simd_distance(worldFirst, SIMD3<Float>(1.5, -0.25, 3)) < 1e-5)
        check("mchk.triangleMesh", chunk.toTriangleMesh(world: false).triangleCount == 2)

        // DepthFile
        let depthValues: [Float] = [0.31, 1.2345, 2.5, 4.99, 0, 3.3]
        let confidence: [UInt8] = [0, 1, 2, 2, 0, 1]
        let depthData = DepthFile.encode(width: 3, height: 2, depth: depthValues, confidence: confidence)
        if let map = try? DepthFile.decode(depthData) {
            let close = zip(map.depth, depthValues).allSatisfy { (pair: (Float, Float)) -> Bool in
                let tolerance: Float = pair.1 * 0.001 + 1e-4
                let error: Float = abs(pair.0 - pair.1)
                return error <= tolerance
            }
            check("dpth.roundTrip", close && map.confidence == confidence && map.width == 3 && map.height == 2)
            check("dpth.at", map.depthAt(x: 2, y: 1) != nil && map.depthAt(x: 3, y: 0) == nil)
        } else {
            check("dpth.decode", false)
        }
        expectThrows("dpth.truncated") { _ = try DepthFile.decode(depthData.prefix(depthData.count - 2)) }

        // PoseTrackFile
        let samples = [PoseSample(timestamp: 12.5, transform: pose, tracking: 2, thermal: 1, exposureDuration: 0.008),
                       PoseSample(timestamp: 12.6, transform: matrix_identity_float4x4, tracking: 1, thermal: 3, exposureDuration: 0.02)]
        var track = ByteWriter()
        PoseTrackFile.appendHeader(to: &track)
        for s in samples { PoseTrackFile.append(s, to: &track) }
        check("ptrk.size", track.count == PoseTrackFile.headerSize + 2 * PoseTrackFile.recordSize)
        check("ptrk.roundTrip", (try? PoseTrackFile.decode(track.data)) == samples)
        check("ptrk.partialIgnored", (try? PoseTrackFile.decode(track.data + Data([1, 2, 3])))?.count == 2)
        expectThrows("ptrk.badHeader") { _ = try PoseTrackFile.decode(Data("PTRX".utf8)) }

        // EditLog
        let roomA = ElementID(), roomB = ElementID()
        var log = EditLog()
        log.append(.renameRoom(room: roomA, name: "A1"))
        log.append(.renameRoom(room: roomA, name: "A2"))
        check("editlog.append", log.active.count == 2 && log.canUndo && !log.canRedo && log.revision == 2)
        check("editlog.undo", log.undo() && log.active.count == 1 && log.canRedo)
        check("editlog.redo", log.redo() && log.active.count == 2 && !log.redo())
        log.undo()
        log.append(.renameRoom(room: roomB, name: "B"))
        check("editlog.truncatesRedo", log.operations.count == 2 && !log.canRedo
              && log.operations.last == .renameRoom(room: roomB, name: "B"))
        roundTrip("editlog.json", log)
        var empty = EditLog()
        check("editlog.emptyUndo", !empty.undo() && !empty.redo())
        let model = SelfTestRoomNames(names: [roomA: "", ElementID(): ""])
        let (edited, orphaned) = log.applied(to: model)
        check("editlog.applied", edited.names[roomA] == "A1" && orphaned.count == 1)

        // EditOperation JSON
        let wall = PlanWall(id: ElementID(roomPlanID: UUID()), a: Vec2(x: 0, y: 0), b: Vec2(x: 3, y: 0), thickness: 0.12,
                            thicknessSource: .estimated, arc: nil, provenance: .user, occludedSpans: [0.5...1.25])
        let ops: [EditOperation] = [
            .recategorizeObject(object: roomA, category: .desk),
            .setHidden(element: roomB, hidden: true),
            .moveObject(object: roomA, transform: Transform4(pose)),
            .moveWallEndpoint(wall: wall.id, atStart: false, to: Vec2(x: 1, y: 2)),
            .addWall(wall: wall, level: 1),
            .setDoorSwing(door: roomB, swing: DoorSwing(hingeAtStart: true, opensToNormalSide: false, source: .user)),
            .setScaleCorrection(room: roomA, factor: 1.012),
            .setRoomAlignment(RoomAlignmentRecord(roomID: UUID(), yaw: 0.3, translation: Vec3(x: 1, y: 0, z: -2), source: .user)),
            .cropObject(object: roomB, box: OrientedBoxRecord(OrientedBox(center: .zero, axes: matrix_identity_float3x3,
                                                                          halfExtents: SIMD3<Float>(1, 2, 3)))),
        ]
        for (i, op) in ops.enumerated() { roundTrip("editop.json.\(i)", op) }
        check("editop.targets", ops[4].targets == [wall.id] && ops[0].targets == [roomA])

        // Identifiers
        let rp = UUID()
        let derivedA = ElementID.derived(fromRoomPlan: rp), derivedB = ElementID.derived(fromRoomPlan: rp)
        check("elementID.derived", derivedA == derivedB && derivedA.uuid != rp && derivedA.roomPlanID == rp)
        check("elementID.equalityIgnoresProvenance", ElementID(uuid: rp) == ElementID(uuid: rp, roomPlanID: UUID()))
        roundTrip("frameLink.json", FrameLink.relocalized(sessionID: UUID(), from: UUID()))

        // ProjectManifest
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var manifest = ProjectManifest.new(kind: .house, name: "Test", now: now)
        let session = UUID()
        manifest.sessions.append(CaptureSessionRef(id: session, startedAt: now, frameLink: .projectFrame(sessionID: session),
                                                   worldMapFile: nil))
        manifest.rooms.append(RoomRecord(id: UUID(), name: "", sessionID: session, floorIndex: 0, status: .captured,
                                         capturedRoomID: nil,
                                         quality: QualitySummary(shape: 0.95, walls: 0.9, floor: 1, ceiling: 0.8, texture: 0.9, missingAreas: 1),
                                         hasMeshPass: false, keyframeCount: 40, capturedAt: now, frameLink: .unaligned))
        roundTrip("manifest.json", manifest)
        check("manifest.schema", manifest.schemaVersion == ProjectManifest.currentSchema && manifest.floors.count == 1)

        // ScanSettings
        var settings = ScanSettings.room
        check("settings.standardGate", settings.keyframeGate.meters == 0.30 && settings.keyframeGate.degrees == 15)
        settings.detail = .maximum
        settings.keepAllPhotos = false
        let coarseGate = settings.keyframeGate
        let metersError: Float = abs(coarseGate.meters - 0.18)
        let degreesError: Float = abs(coarseGate.degrees - 10.5)
        check("settings.coarseGate", metersError < 1e-6 && degreesError < 1e-5)
        settings.distance = .closeUp
        let closeUpWindow: ClosedRange<Float> = 0.3...2
        let normalWindow: ClosedRange<Float> = 0.3...4
        check("settings.depthWindow", settings.depthWindow == closeUpWindow && ScanSettings.room.depthWindow == normalWindow)

        // QualityVerdict
        check("verdict.good", QualityVerdict.from(shape: 0.9, walls: 0.95, floor: 1, ceiling: 0.9, texture: 0.99) == .good)
        check("verdict.okay", QualityVerdict.from(shape: 0.9, walls: 0.7, floor: 1, ceiling: 0.9, texture: 0.99) == .okay)
        check("verdict.poor", QualityVerdict.from(shape: 0.9, walls: 0.69, floor: 1, ceiling: 0.9, texture: .nan) == .poor)

        // PlanAxes
        let p3 = SIMD3<Float>(1.5, 2, -4)
        check("planAxes.convention", PlanAxes.toPlan(p3) == SIMD2<Float>(1.5, 4))
        check("planAxes.roundTrip", PlanAxes.toWorld(PlanAxes.toPlan(p3), y: 2) == p3)

        // DerivedIndex and InputHasher
        var index = DerivedIndex()
        let room = UUID()
        index.record(DerivedStamp(step: .cleanModel, subject: room, pipelineVersion: 1, inputHash: "a", createdAt: now))
        check("index.fresh", index.isFresh(step: .cleanModel, subject: room, version: 1, inputHash: "a"))
        check("index.staleVersion", !index.isFresh(step: .cleanModel, subject: room, version: 2, inputHash: "a"))
        check("index.staleHash", !index.isFresh(step: .cleanModel, subject: room, version: 1, inputHash: "b"))
        index.record(DerivedStamp(step: .cleanModel, subject: room, pipelineVersion: 1, inputHash: "b", createdAt: now))
        check("index.replaces", index.stamps.count == 1 && index.isFresh(step: .cleanModel, subject: room, version: 1, inputHash: "b"))
        let seal = SealFile(sealedAt: now, files: [SealEntry(path: "a.jpg", size: 10)])
        let h1 = InputHasher.hash(seals: [seal], editRevision: 3)
        check("hash.stable", h1 == InputHasher.hash(seals: [seal], editRevision: 3) && h1.count == 16)
        check("hash.sensitive", h1 != InputHasher.hash(seals: [seal], editRevision: 4))

        // SealFile on a temporary folder
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CoreSelfTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try ProjectStore.writeData(Data("abc".utf8), to: folder.appendingPathComponent("keyframes.jsonl"))
            try ProjectStore.writeData(encoded, to: folder.appendingPathComponent("mesh/x.mchk"))
            let made = try ProjectStore.sealRawFolder(folder, now: now)
            check("seal.make", made.files.map { $0.path } == ["keyframes.jsonl", "mesh/x.mchk"] && made.totalBytes == Int64(3 + encoded.count))
            check("seal.verifyClean", made.verify(folder: folder).isEmpty)
            try ProjectStore.writeData(Data("abcd".utf8), to: folder.appendingPathComponent("keyframes.jsonl"))
            try FileManager.default.removeItem(at: folder.appendingPathComponent("mesh/x.mchk"))
            check("seal.verifyDetects", made.verify(folder: folder).count == 2)
        } catch {
            check("seal.io", false, "\(error)")
        }

        // CR-4: JSON size cap; CR-6: no parent folder is recreated by a late write
        do {
            let small = folder.appendingPathComponent("small.json")
            try ProjectStore.writeJSON(seal, to: small)
            check("json.readsUnderCap", (try? ProjectStore.readJSON(SealFile.self, from: small)) == seal)
            do {
                _ = try ProjectStore.readJSON(SealFile.self, from: small, maxBytes: 8)
                check("json.sizeCap", false, "did not throw")
            } catch let error as CoreError {
                if case .fileTooLarge = error { } else { check("json.sizeCap", false, "\(error)") }
            }
            let gone = folder.appendingPathComponent("discarded", isDirectory: true)
            expectThrows("write.noParents") {
                try ProjectStore.writeData(Data("x".utf8), to: gone.appendingPathComponent("late.jpg"), createParents: false)
            }
            check("write.noParentsLeavesNoFolder", !FileManager.default.fileExists(atPath: gone.path))
            expectThrows("ensureInside.missingRoot") {
                _ = try ProjectStore.ensureDirectory(gone.appendingPathComponent("rooms"), inside: gone)
            }
            check("ensureInside.creates", (try? ProjectStore.ensureDirectory(folder.appendingPathComponent("rooms/r"), inside: folder)) != nil)
        } catch {
            check("json.io", false, "\(error)")
        }

        // Package layout
        let package = ProjectPackage(root: URL(fileURLWithPath: "/p/x.mapperproj", isDirectory: true))
        check("package.editLog", package.editLogURL.path.hasSuffix("/x.mapperproj/edits/editlog.json"))
        check("package.alignment", package.alignmentURL.path.hasSuffix("derived/structure/alignment.json"))
        check("package.rawRoom", package.rawRoomURL(session: session, room: room).path
              .hasSuffix("raw/sessions/\(session.uuidString)/rooms/\(room.uuidString)"))
        check("package.keyframePath", RawScanFolder.keyframeImagePath(12) == "keyframes/00012.jpg")
        check("package.attempt", package.pipelineAttemptURL.path.hasSuffix("/x.mapperproj/derived/pipeline_attempt.json"))
        let scanFolder = RawScanFolder(url: URL(fileURLWithPath: "/p/InProgress/scan", isDirectory: true))
        check("package.liveRoom", scanFolder.liveCapturedRoomURL.lastPathComponent == "capturedroom-live.json"
              && scanFolder.worldMapURL.lastPathComponent == "worldmap.arworldmap")

        // CR-4: record paths resolve only inside their folder
        for bad in ["", "/etc/x", "../x", "keyframes/../../x", "a//b", "./x", "a\\b", "x/.."] {
            check("path.rejects \(bad)", !RawScanFolder.isSafeRelativePath(bad) && scanFolder.resolve(bad) == nil)
        }
        check("path.accepts", RawScanFolder.isSafeRelativePath("keyframes/00001.jpg")
              && scanFolder.resolve("keyframes/00001.jpg")?.path == "/p/InProgress/scan/keyframes/00001.jpg")

        // CR-4: package names and file protection
        let canonical = UUID()
        check("packageName.canonical", ProjectStore.projectID(fromPackageName: canonical.uuidString + ".mapperproj") == canonical)
        check("packageName.rejects", ProjectStore.projectID(fromPackageName: canonical.uuidString.lowercased() + ".mapperproj") == nil
              && ProjectStore.projectID(fromPackageName: "x.mapperproj") == nil
              && ProjectStore.projectID(fromPackageName: canonical.uuidString) == nil)
        let unlessOpen = Data.WritingOptions.completeFileProtectionUnlessOpen
        check("protection.edits", ProjectStore.defaultProtection(for: package.editLogURL) == unlessOpen)
        check("protection.exports", ProjectStore.defaultProtection(for: package.exportsURL.appendingPathComponent("a/b.pdf")) == unlessOpen)
        check("protection.thumbnail", ProjectStore.defaultProtection(for: package.thumbnailURL) == unlessOpen)
        check("protection.rawAndDerived", ProjectStore.defaultProtection(for: package.rawRoomURL(session: session, room: room)
                                                                          .appendingPathComponent("poses.ptrk")) == []
              && ProjectStore.defaultProtection(for: package.cleanModelURL) == []
              && ProjectStore.defaultProtection(for: package.derivedURL.appendingPathComponent("thumbnail.jpg")) == [])

        // Measurements, categories, recordings
        // CR-2: 2 sigma above max(4 cm, 3 percent of the length); areas and volumes relative only
        check("measure.lowConfidence.short", MeasuredValue(value: 0.5, sigma: 0.021, provenance: .measured).isLowConfidence
              && !MeasuredValue(value: 0.5, sigma: 0.019, provenance: .measured).isLowConfidence)
        check("measure.lowConfidence.long", MeasuredValue(value: 3, sigma: 0.046, provenance: .measured).isLowConfidence
              && !MeasuredValue(value: 3, sigma: 0.044, provenance: .measured).isLowConfidence
              && !MeasuredValue(value: 10, sigma: 0.1, provenance: .measured).isLowConfidence(kind: .wallLength))
        check("measure.lowConfidence.area", MeasuredValue(value: 20, sigma: 0.31, provenance: .measured).isLowConfidence(kind: .area)
              && !MeasuredValue(value: 20, sigma: 0.29, provenance: .measured).isLowConfidence(kind: .area))
        check("measure.lowConfidence.noSigma", !MeasuredValue(value: 3, sigma: nil, provenance: .inferred).isLowConfidence
              && !MeasuredValue(value: 3, sigma: .nan, provenance: .measured).isLowConfidence(length: 3))
        check("category.count", ObjectCategory.allCases.count == 24 && !ObjectCategory.toilet.isMovable && ObjectCategory.sofa.isMovable)
        let recording = SnapshotRecording.synthetic(count: 5)
        check("recording.jsonl", (try? SnapshotRecording.decodeJSONLines(recording.encodeJSONLines())) == recording)
        check("error.copyKey", MapperError.outOfMemory(step: .textureHigh).copyKey == "error.outOfMemory"
              && MapperError.lowMemory.copyKey == "error.lowMemory")
        let fake = FakeScanEngine(recording: .synthetic(count: 3))
        _ = try? fake.start()
        fake.discard()
        check("fakeEngine.discard", fake.state == .idle)

        return failures
    }
}

/// Minimal `EditApplicable` model for the self-test: room names keyed by element.
private struct SelfTestRoomNames: EditApplicable {
    /// Names of the known rooms.
    var names: [ElementID: String]

    /// Applies renames; a rename of an unknown room is orphaned, other operations are ignored.
    mutating func apply(_ op: EditOperation) -> Bool {
        guard case .renameRoom(let room, let name) = op else { return true }
        guard names[room] != nil else { return false }
        names[room] = name
        return true
    }
}
