import Foundation

/// File checks of the ObjectCapture self-test: folder preparation, image counting, sealing into
/// a temporary package, the reconstruction store and the Codable round trips. Everything lives
/// under `FileManager.default.temporaryDirectory/ObjectCaptureSelfTest/` and is removed at the end.
extension ObjectCaptureSelfTest {
    /// Runs the file checks in a fresh temporary folder.
    static func fileChecks(_ failures: inout [String]) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ObjectCaptureSelfTest", isDirectory: true)
        try? fm.removeItem(at: base)
        defer { try? fm.removeItem(at: base) }
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            try prepareChecks(&failures, base: base)
            try sealChecks(&failures, base: base)
            try storeChecks(&failures, base: base)
        } catch {
            failures.append("files: \(StoreFiles.describe(error))")
        }
        codableChecks(&failures)
    }

    // MARK: Folders

    /// `prepare` makes two empty folders and refuses a non-empty `Images/`; `imageCount`,
    /// `canRecover`, `isEmptyDirectory` and `emptyDirectory`.
    private static func prepareChecks(_ failures: inout [String], base: URL) throws {
        let fm = FileManager.default
        let root = base.appendingPathComponent("InProgress-prepare", isDirectory: true)
        let folder = try InProgressScans.create(scanInfo(fixedID(10)), root: root)
        let paths = try ObjectScanFolders.prepare(folder)
        let imagesEmpty = ObjectScanFolders.isEmptyDirectory(paths.images)
        let checkpointEmpty = ObjectScanFolders.isEmptyDirectory(paths.checkpoint)
        check(&failures, "folders.prepare", imagesEmpty && checkpointEmpty, "images \(imagesEmpty), checkpoint \(checkpointEmpty)")

        let busy = try InProgressScans.create(scanInfo(fixedID(11)), root: root)
        let busyImages = ObjectScanFolders.imagesURL(in: busy)
        try fm.createDirectory(at: busyImages, withIntermediateDirectories: false)
        try Data([1]).write(to: busyImages.appendingPathComponent("IMG_0001.HEIC"))
        var threw = false
        do {
            _ = try ObjectScanFolders.prepare(busy)
        } catch {
            threw = true
        }
        check(&failures, "folders.prepareRefusesFiles", threw, "prepare accepted a non-empty Images folder")

        for name in ["a.heic", "b.HEIC", "c.jpg", "notes.txt", "d.JPG"] {
            try Data([2]).write(to: paths.images.appendingPathComponent(name))
        }
        let counted = ObjectScanFolders.imageCount(in: paths.images)
        check(&failures, "folders.imageCount", counted == 4, "got \(counted)")
        let missing = ObjectScanFolders.imageCount(in: base.appendingPathComponent("missing", isDirectory: true))
        check(&failures, "folders.imageCountMissing", missing == 0, "got \(missing)")

        let recover = try InProgressScans.create(scanInfo(fixedID(12)), root: root)
        let recoverPaths = try ObjectScanFolders.prepare(recover)
        for index in 1...9 {
            try Data([3]).write(to: recoverPaths.images.appendingPathComponent("IMG_\(index).HEIC"))
        }
        let nine = ObjectScanFolders.canRecover(recover)
        try Data([3]).write(to: recoverPaths.images.appendingPathComponent("IMG_10.HEIC"))
        let ten = ObjectScanFolders.canRecover(recover)
        check(&failures, "folders.canRecover", !nine && ten, "9 images \(nine), 10 images \(ten)")

        let missingEmpty = ObjectScanFolders.isEmptyDirectory(base.appendingPathComponent("missing", isDirectory: true))
        check(&failures, "folders.missingIsNotEmptyFolder", !missingEmpty, "a missing folder counted as empty")
        try ObjectScanFolders.emptyDirectory(recoverPaths.images)
        check(&failures, "folders.emptyDirectory", ObjectScanFolders.isEmptyDirectory(recoverPaths.images),
              "files left after emptyDirectory")
    }

    /// `seal` moves `Checkpoint/` to the derived checkpoint, removes the empty subfolders, seals
    /// `Images/` and `objectlog.json` and lists them in SEAL.json.
    private static func sealChecks(_ failures: inout [String], base: URL) throws {
        let fm = FileManager.default
        let root = base.appendingPathComponent("InProgress-seal", isDirectory: true)
        let objectID = fixedID(20)
        let package = try makePackage(base: base, id: fixedID(21))
        let folder = try InProgressScans.create(scanInfo(objectID), root: root)
        let paths = try ObjectScanFolders.prepare(folder)
        for index in 1...ObjectScanFolders.minimumImages {
            try Data(repeating: UInt8(index), count: 16).write(to: paths.images.appendingPathComponent("IMG_\(index).HEIC"))
        }
        try Data([7, 7, 7]).write(to: paths.checkpoint.appendingPathComponent("snapshot.bin"))
        let logURL = folder.url.appendingPathComponent(ObjectCaptureLog.fileName, isDirectory: false)
        try ProjectStore.writeJSON(sampleLog(objectID), to: logURL, createParents: false)

        let seal = try ObjectScanFolders.seal(folder, objectID: objectID, package: package, root: root)
        let sealed = package.rawObjectURL(objectID)
        check(&failures, "seal.moved", !StoreFiles.exists(folder.url) && StoreFiles.isDirectory(sealed),
              "InProgress folder still there or raw folder missing")
        let snapshot = PhotogrammetryStore.checkpointURL(package, object: objectID).appendingPathComponent("snapshot.bin")
        let checkpointMoved = fm.fileExists(atPath: snapshot.path)
        let checkpointLeft = StoreFiles.exists(sealed.appendingPathComponent(ObjectScanFolders.checkpointFolderName))
        check(&failures, "seal.checkpoint", checkpointMoved && !checkpointLeft,
              "moved \(checkpointMoved), left in raw \(checkpointLeft)")
        let leftovers = InProgressScans.subfolders.filter { StoreFiles.exists(sealed.appendingPathComponent($0)) }
        check(&failures, "seal.emptySubfoldersRemoved", leftovers.isEmpty, "left \(leftovers)")
        let listed = Set(seal.files.map(\.path))
        let images = seal.files.filter { $0.path.hasPrefix(ObjectScanFolders.imagesFolderName + "/") }.count
        let hasLog = listed.contains(ObjectCaptureLog.fileName)
        check(&failures, "seal.lists", images == ObjectScanFolders.minimumImages && hasLog,
              "images \(images), log \(hasLog)")
        let problems = ProjectStore.verifyRawFolder(sealed)
        check(&failures, "seal.verifies", problems.isEmpty, "\(problems)")
        let rawCount = ObjectScanFolders.imageCount(in: PhotogrammetryStore.imagesURL(package, object: objectID))
        check(&failures, "seal.imagesURL", rawCount == ObjectScanFolders.minimumImages, "got \(rawCount)")
    }

    // MARK: Store

    /// Paths, the loaders, the step's hash and budgets.
    private static func storeChecks(_ failures: inout [String], base: URL) throws {
        let package = try makePackage(base: base, id: fixedID(30))
        let id = fixedID(31)
        let model = PhotogrammetryStore.modelURL(package, object: id)
        let folderName = model.deletingLastPathComponent().lastPathComponent
        check(&failures, "store.paths", model.lastPathComponent == "model.usdz" && folderName == id.uuidString,
              "model \(model.lastPathComponent) in \(folderName)")
        let checkpointName = PhotogrammetryStore.checkpointURL(package, object: id).lastPathComponent
        let infoName = PhotogrammetryStore.infoURL(package, object: id).lastPathComponent
        check(&failures, "store.names", checkpointName == "checkpoint" && infoName == "reconstruction.json",
              "checkpoint \(checkpointName), info \(infoName)")
        let absentModel = PhotogrammetryStore.modelURLIfPresent(package, object: id)
        let absentInfo = PhotogrammetryStore.loadInfo(package, object: id)
        check(&failures, "store.absent", absentModel == nil && absentInfo == nil, "found files that do not exist")

        try ProjectStore.ensureDirectory(PhotogrammetryStore.folder(package, object: id), inside: package.root)
        try Data([0x50, 0x4B]).write(to: model)
        let info = sampleInfo(id)
        try ProjectStore.writeJSON(info, to: PhotogrammetryStore.infoURL(package, object: id), createParents: false)
        let presentModel = PhotogrammetryStore.modelURLIfPresent(package, object: id)
        let loaded = PhotogrammetryStore.loadInfo(package, object: id)
        check(&failures, "store.present", presentModel != nil && loaded == info, "model or info not read back")

        let step = PhotogrammetryStep(object: ObjectRecord(id: id, name: "", size: .smallMedium, status: .captured,
                                                           imageCount: 10, modelFile: nil))
        let fullBudget: UInt64 = 1024 * 1024 * 1024
        let reducedBudget: UInt64 = 500 * 1024 * 1024
        let budgetsOK = step.memoryBudgetBytes == fullBudget && step.reducedMemoryBudgetBytes == reducedBudget
        check(&failures, "step.identity", step.id == .reconstructObject && budgetsOK, "id \(step.id.rawValue)")
        let seal = SealFile(sealedAt: fixedDate, files: [SealEntry(path: "Images/IMG_1.HEIC", size: 2_000_000)])
        let empty = PhotogrammetryStep.inputHash(seal: nil)
        let sealed = PhotogrammetryStep.inputHash(seal: seal)
        let again = PhotogrammetryStep.inputHash(seal: seal)
        check(&failures, "step.inputHash", empty != sealed && sealed == again && sealed.count == 16,
              "empty \(empty), sealed \(sealed), again \(again)")
    }

    // MARK: Codable

    /// `PhotogrammetryInfo` and `ObjectCaptureLog` survive a JSON round trip with the package coders.
    private static func codableChecks(_ failures: inout [String]) {
        let info = sampleInfo(fixedID(40))
        let log = sampleLog(fixedID(41))
        do {
            let infoBack = try ProjectStore.decoder.decode(PhotogrammetryInfo.self, from: ProjectStore.encoder.encode(info))
            check(&failures, "codable.info", infoBack == info, "round trip differs")
            let logBack = try ProjectStore.decoder.decode(ObjectCaptureLog.self, from: ProjectStore.encoder.encode(log))
            check(&failures, "codable.log", logBack == log, "round trip differs")
        } catch {
            failures.append("codable: \(error)")
        }
    }

    // MARK: Fixtures

    /// `scan.json` of an object scan with a fixed start.
    private static func scanInfo(_ id: UUID) -> InProgressScanInfo {
        InProgressScanInfo(scanID: id, projectID: fixedID(99), sessionID: nil, roomID: id, kind: .object,
                           mode: .object, startedAt: fixedDate)
    }

    /// A temporary package with `raw/` and `derived/`.
    private static func makePackage(base: URL, id: UUID) throws -> ProjectPackage {
        let package = ProjectPackage(root: base.appendingPathComponent(id.uuidString + "." + ProjectPackage.fileExtension,
                                                                       isDirectory: true))
        try FileManager.default.createDirectory(at: package.rawURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package.derivedURL, withIntermediateDirectories: true)
        return package
    }

    /// A capture log with fixed values.
    static func sampleLog(_ id: UUID) -> ObjectCaptureLog {
        ObjectCaptureLog(objectID: id, startedAt: fixedDate, seconds: 95.5, shotCount: 120, maximumNumberOfInputImages: 300,
                         photogrammetryMaxImages: 300, photogrammetryMaxImageDimension: 4032, passes: 3, flips: 1,
                         feedbackSeconds: ["movingTooFast": 2.5], trackingLimitedSeconds: 1.25, detectionFailures: 1,
                         finalStage: "completed", failure: nil, thermalAtStart: "nominal", thermalAtEnd: "fair",
                         freeBytesAtStart: 9_000_000_000, availableMemoryAtStart: 2_500_000_000, osVersion: "selftest")
    }
}
