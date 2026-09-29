import Foundation
import simd

// MissingAreasSelfTest checks that touch files (checks 16 to 18): a temporary package with a
// sealed room (pose track at 10 Hz, keyframe log, one mesh chunk, capture log, no RoomPlan
// file) and later a sealed mesh pass of that room (scan.json with the room id). The seed inputs
// and `MissingAreasReevaluation.run` are checked before and after the pass exists. Everything
// lives under FileManager.default.temporaryDirectory and is removed afterwards.

extension MissingAreasSelfTest {
    /// Folder of the temporary package, removed before and after the checks.
    static let fileTestFolderName = "MapperMissingAreasSelfTest"
    /// Fixed evaluation time.
    static let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)
    /// Pose samples of the room fixture: 0.0 to 5.0 s every 0.1 s.
    static let roomPoseCount = 51
    /// Pose samples of the pass fixture: 100.0 to 102.0 s every 0.1 s.
    static let passPoseCount = 21

    /// A fixed identifier built from `n` (no randomness).
    static func fixedID(_ n: Int) -> UUID {
        let low = UInt8(truncatingIfNeeded: n)
        let high = UInt8(truncatingIfNeeded: n >> 8)
        return UUID(uuid: (0x4D, 0x49, 0x53, 0x53, 0x49, 0x4E, 0x47, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, high, low))
    }

    /// Runs the file checks in a fresh temporary folder.
    static func checkFiles(_ c: inout Checker) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(fileTestFolderName, isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            try fileChecks(&c, base: base)
        } catch {
            c.check("files.run", false, "\(error)")
        }
    }

    /// The checks proper; an unexpected throw fails `files.run`.
    private static func fileChecks(_ c: inout Checker, base: URL) throws {
        let projectID = fixedID(900)
        let sessionID = fixedID(800)
        let roomID = fixedID(1)
        let name = projectID.uuidString + "." + ProjectPackage.fileExtension
        let package = ProjectPackage(root: base.appendingPathComponent(name, isDirectory: true))
        for folder in [package.rawURL, package.derivedURL] {
            try ProjectStore.ensureDirectory(folder)
        }
        let record = RoomRecord(id: roomID, name: "", sessionID: sessionID, floorIndex: 0, status: .captured,
                                capturedRoomID: nil, quality: nil, hasMeshPass: false, keyframeCount: 6,
                                capturedAt: fixedDate, frameLink: .projectFrame(sessionID: sessionID))
        var manifest = ProjectManifest.new(kind: .room, name: "Missing Areas Self Test", now: fixedDate)
        manifest.id = projectID
        manifest.rooms = [record]
        try ProjectStore.writeManifest(manifest, to: package)
        let roomFolder = RawScanFolder(url: package.rawRoomURL(session: sessionID, room: roomID))
        let roomSeal = try writeFolder(roomFolder, timeOffset: 0, poseCount: roomPoseCount, withMesh: true, info: nil)

        let seed = MissingAreasReevaluation.seedInputs(package: package, record: record)
        let times = seed.observations.map { $0.timestamp }
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        let oneHertz: Bool = times.count == 6 && gaps.allSatisfy { abs($0 - 1) < 0.05 }
        c.check("seed.observationsAt1Hz", oneHertz, "\(times)")
        let triangles = fixtureMesh().indices.count / 3
        let facesOK: Bool = seed.faces.count == triangles && seed.faces.count <= MissingAreasReevaluation.seedFaceLimit
        c.check("seed.facesUpToLimit", facesOK && MissingAreasReevaluation.seedFaceLimit == 100_000,
                "\(seed.faces.count) of \(triangles)")
        var stranger = record
        stranger.id = fixedID(55)
        let none = MissingAreasReevaluation.seedInputs(package: package, record: stranger)
        c.check("seed.missingRoomIsEmpty", none.observations.isEmpty && none.faces.isEmpty)

        let roomOnly = try MissingAreasReevaluation.run(package: package, record: record, now: fixedDate)
        let roomHash = QualityEvaluator.doneInputHash(seal: roomSeal)
        let storedRoomOnly = QualityStore.load(package, room: roomID)
        c.check("run.roomOnlyHash", roomOnly.inputHash == roomHash && storedRoomOnly?.inputHash == roomHash)
        c.check("run.updatesRoomRecord", (try? ManifestWriter.read(package))?.rooms.first?.quality == roomOnly.summary)

        let passID = fixedID(810)
        let passFolder = RawScanFolder(url: package.rawMeshPassURL(session: sessionID, pass: passID))
        let info = InProgressScanInfo(scanID: passID, projectID: projectID, sessionID: sessionID, roomID: roomID,
                                      kind: .meshPass, mode: .room, startedAt: fixedDate)
        let passSeal = try writeFolder(passFolder, timeOffset: 100, poseCount: passPoseCount, withMesh: false, info: info)
        let found = MeshPassFolders.forRoom(roomID, in: package)
        c.check("run.passFound", found.map { $0.url.lastPathComponent } == [passID.uuidString], "\(found.count)")

        let withPass = try MissingAreasReevaluation.run(package: package, record: record, now: fixedDate)
        let sealsWithPass: [SealFile?] = [roomSeal, passSeal]
        let passHash = QualityEvaluator.doneInputHash(seals: sealsWithPass)
        let stored = QualityStore.load(package, room: roomID)
        let hashOK: Bool = withPass.inputHash == passHash && withPass.inputHash != roomHash
        c.check("run.passChangesHash", hashOK && stored?.inputHash == passHash, "\(withPass.inputHash)")
        let seedWithPass = MissingAreasReevaluation.seedInputs(package: package, record: record)
        c.check("seed.includesEarlierPasses", seedWithPass.observations.count == 6 + 3, "\(seedWithPass.observations.count)")
        let roomFiles = (try? FileManager.default.contentsOfDirectory(atPath: roomFolder.url.path)) ?? []
        c.check("run.roomFolderUntouched", ProjectStore.verifyRawFolder(roomFolder.url).isEmpty
                && !roomFiles.contains(QualityStore.fileName))
    }

    // MARK: - Fixture writers

    /// Writes a raw folder: a pose track at 10 Hz from `timeOffset`, one keyframe per second,
    /// the fixture mesh as one chunk and a capture log when `withMesh`, and `scan.json` when
    /// `info` is set; then seals it.
    private static func writeFolder(_ folder: RawScanFolder, timeOffset: Double, poseCount: Int, withMesh: Bool,
                                    info: InProgressScanInfo?) throws -> SealFile {
        try ProjectStore.ensureDirectory(folder.url)
        var writer = ByteWriter()
        PoseTrackFile.appendHeader(to: &writer)
        var frames = Data()
        for k in 0..<poseCount {
            let t = timeOffset + Double(k) / 10
            let transform = walkPose(k)
            PoseTrackFile.append(PoseSample(timestamp: t, transform: transform, tracking: 2, thermal: 0,
                                            exposureDuration: 1.0 / 60), to: &writer)
            guard k % 10 == 0 else { continue }
            let frame = KeyframeRecord(index: k / 10, timestamp: t, transform: Transform4(transform),
                                       intrinsics: Intrinsics(fx: 1440, fy: 1440, cx: 960, cy: 720, width: 1920, height: 1440),
                                       imageFile: RawScanFolder.keyframeImagePath(k / 10), depthFile: nil,
                                       exposureDuration: 1.0 / 60, exposureOffset: 0, ambientIntensity: 1000,
                                       angularSpeed: 0, trackingNormal: true)
            frames.append(try ProjectStore.encoder.encode(frame))
            frames.append(0x0A)
        }
        try writer.data.write(to: folder.poseTrackURL)
        try frames.write(to: folder.keyframesLogURL)
        if withMesh {
            try ProjectStore.ensureDirectory(folder.meshURL)
            let mesh = fixtureMesh()
            let anchor = fixedID(700)
            let chunk = MeshChunk(anchorID: anchor, transform: matrix_identity_float4x4, updateCount: 1,
                                  positions: mesh.positions, indices: mesh.indices, classes: mesh.classes)
            try MeshChunkFile.encode(chunk).write(to: folder.meshChunkURL(anchor: anchor))
            let log = RoomCaptureLog(seconds: 5, instructionSeconds: [:], error: nil, relocalizations: 0,
                                     limitedTrackingFraction: 0, degraded: .allGood)
            try ProjectStore.writeJSON(log, to: folder.roomLogURL)
        }
        if let info {
            try ProjectStore.writeJSON(info, to: folder.url.appendingPathComponent(InProgressScanInfo.fileName, isDirectory: false))
        }
        return try ProjectStore.sealRawFolder(folder.url, now: fixedDate)
    }

    /// Camera `k` of the fixture walk: at eye height in the middle of a 4 x 4 m floor, turning
    /// 9 degrees per sample and looking 20 degrees down.
    private static func walkPose(_ k: Int) -> simd_float4x4 {
        let heading = Double(k) * 9 * Double.pi / 180
        let pitch = -20 * Double.pi / 180
        let forward = SIMD3<Float>(Float(cos(heading) * cos(pitch)), Float(sin(pitch)), Float(sin(heading) * cos(pitch)))
        let up = SIMD3<Float>(0, 1, 0)
        let upInView = simd_normalize(up - forward * simd_dot(up, forward))
        let x = -upInView
        let z = -forward
        let y = simd_cross(z, x)
        let position = SIMD4<Float>(2, eye, 2, 1)
        return simd_float4x4(columns: (SIMD4<Float>(x, 0), SIMD4<Float>(y, 0), SIMD4<Float>(z, 0), position))
    }

    /// A 4 x 4 m floor at y = 0 and a 4 x 2.5 m wall at z = 0, in 0.5 m cells, two triangles per
    /// cell, with face classes (floor 2, wall 1).
    private static func fixtureMesh() -> (positions: [SIMD3<Float>], indices: [UInt32], classes: [UInt8]) {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var classes: [UInt8] = []
        /// One grid of `nu` x `nv` cells spanned by `u` and `v` from `origin`.
        func grid(origin: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>, nu: Int, nv: Int, surface: UInt8) {
            let base = UInt32(positions.count)
            for j in 0...nv {
                for i in 0...nu {
                    let a: SIMD3<Float> = u * (Float(i) / Float(nu))
                    let b: SIMD3<Float> = v * (Float(j) / Float(nv))
                    positions.append(origin + a + b)
                }
            }
            let row = UInt32(nu + 1)
            for j in 0..<nv {
                for i in 0..<nu {
                    let p00 = base + UInt32(j) * row + UInt32(i)
                    let p10 = p00 + 1
                    let p01 = p00 + row
                    let p11 = p01 + 1
                    indices.append(contentsOf: [p00, p10, p11, p00, p11, p01])
                    classes.append(surface)
                    classes.append(surface)
                }
            }
        }
        grid(origin: SIMD3<Float>(0, 0, 0), u: SIMD3<Float>(4, 0, 0), v: SIMD3<Float>(0, 0, 4), nu: 8, nv: 8, surface: 2)
        grid(origin: SIMD3<Float>(0, 0, 0), u: SIMD3<Float>(4, 0, 0), v: SIMD3<Float>(0, 2.5, 0), nu: 8, nv: 5, surface: 1)
        return (positions: positions, indices: indices, classes: classes)
    }
}
