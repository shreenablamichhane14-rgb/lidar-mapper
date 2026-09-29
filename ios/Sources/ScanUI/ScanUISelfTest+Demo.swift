import Foundation

// ScanUISelfTest checks that touch files or recorder objects: the Demo Mode room written by
// `DemoProjectFactory.makeDemoRoom` into a temporary package (clean.json and plan.json load
// with a 20 m^2 floor, the raw folder is sealed, the mesh files and quality.json load), the
// disabled snapshot recorder, the keyframe recorder's pause conformance and the fallback
// evaluation. Everything lives under FileManager.default.temporaryDirectory and is removed.
extension ScanUISelfTest {
    /// Folder of the temporary package, removed before and after the checks.
    static let demoTestFolderName = "MapperScanUISelfTest"

    /// Runs the demo room and recorder checks.
    static func checkDemoRoom(_ c: inout ScanUISelfTestChecker) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(demoTestFolderName, isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            try demoChecks(&c, base: base)
        } catch {
            c.check("demo.run", false, "\(error)")
        }

        c.check("recorder.disabledIsNil", SnapshotRecorder(enabled: false) == nil)
        let keyframes: ScanRecorder = KeyframeRecorder()
        if let pausable = keyframes as? PausableScanRecorder {
            pausable.isPaused = true
            c.check("recorder.keyframesPausable", pausable.isPaused)
            pausable.isPaused = false
        } else {
            c.check("recorder.keyframesPausable", false, "KeyframeRecorder is not PausableScanRecorder")
        }
        let fallback = ScanQualityCheck.fallback(roomID: fixedID(7), now: fixedDate)
        c.check("quality.fallbackIsHonest", fallback.summary.verdict == .poor && fallback.roomID == fixedID(7)
                && fallback.missingAreas.isEmpty, "\(fallback.summary)")
    }

    /// Writes the demo room into a fresh package and checks every file it promises.
    private static func demoChecks(_ c: inout ScanUISelfTestChecker, base: URL) throws {
        let projectID = fixedID(100)
        let sessionID = fixedID(101)
        let roomID = fixedID(102)
        let name = projectID.uuidString + "." + ProjectPackage.fileExtension
        let package = ProjectPackage(root: base.appendingPathComponent(name, isDirectory: true))
        for folder in [package.rawURL, package.derivedURL, package.editsURL, package.exportsURL] {
            try ProjectStore.ensureDirectory(folder)
        }
        var manifest = ProjectManifest.new(kind: .room, name: "Scan UI Self Test", now: fixedDate)
        manifest.id = projectID
        try ProjectStore.writeManifest(manifest, to: package)

        let made = try DemoProjectFactory.makeDemoRoom(package: package, sessionID: sessionID, roomID: roomID,
                                                       now: fixedDate)
        let record = made.0
        let evaluation = made.1
        c.check("demo.run", true)

        let clean = try CleanModelStore.loadBase(package)
        let room = clean.rooms.first
        c.near("demo.cleanFloorArea", room?.metrics.floorArea ?? 0, 20, tolerance: 1e-3)
        let walls = room?.walls.count ?? 0
        let openings = room?.openings.count ?? 0
        let objects = room?.objects.count ?? 0
        c.check("demo.cleanElements", walls == 4 && openings == 2 && objects == 2,
                "walls \(walls), openings \(openings), objects \(objects)")

        let plan = try PlanModelStore.loadBase(package)
        c.near("demo.planArea", plan.levels.first?.rooms.first?.area ?? 0, 20, tolerance: 1e-3)

        let rawFolder = package.rawRoomURL(session: sessionID, room: roomID)
        let sealExists = FileManager.default.fileExists(atPath: package.sealURL(in: rawFolder).path)
        let sealProblems = ProjectStore.verifyRawFolder(rawFolder)
        c.check("demo.rawSealed", sealExists && sealProblems.isEmpty, "\(sealProblems)")

        let measured = try MeshModelStore.loadMeasured(package, room: roomID)
        c.check("demo.meshFiles", (measured?.triangleCount ?? 0) > 0, "\(measured?.triangleCount ?? 0)")

        let stored = QualityStore.load(package, room: roomID)
        let summary = evaluation.summary
        let recordOK = record.id == roomID && record.status == .processed && record.quality == summary
        c.check("demo.qualityStored", stored?.roomID == roomID && recordOK, "\(record.status)")
        let scoresOK = summary.shape >= 0.8 && summary.shape <= 1 && summary.texture > 0.5 && summary.texture <= 1
        c.check("demo.qualityScores", scoresOK && evaluation.degraded == .allGood, "\(summary)")
    }
}
