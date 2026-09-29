import Foundation

/// Folders of a small or medium object scan (docs/MODULES.md 3.33, 3.1; D5; CR-5). An object
/// scan lives in `InProgress/<objectID>/` (made by `InProgressScans.create`) with fresh, empty
/// `Images/` and `Checkpoint/` folders for `ObjectCaptureSession` (RESEARCH 3.3 gotcha 2). At
/// sealing the checkpoint moves to `derived/objects/<id>/checkpoint/` (a cache the reconstruction
/// keeps writing, so never raw), and `Images/`, `objectlog.json` and `scan.json` are sealed into
/// `raw/objects/<id>/`. Any thread.
enum ObjectScanFolders {
    /// Folder of the session's HEIC images.
    static let imagesFolderName = "Images"
    /// Folder of the capture session's checkpoint.
    static let checkpointFolderName = "Checkpoint"
    /// Apple's sample refuses fewer than 10 images (RESEARCH 3.3 recommended 4).
    static let minimumImages = 10
    /// Lowercased extensions counted as images.
    static let imageExtensions: Set<String> = ["heic", "jpg", "jpeg", "png"]

    /// `<folder>/Images/`.
    static func imagesURL(in folder: RawScanFolder) -> URL {
        folder.url.appendingPathComponent(imagesFolderName, isDirectory: true)
    }

    /// `<folder>/Checkpoint/`.
    static func checkpointURL(in folder: RawScanFolder) -> URL {
        folder.url.appendingPathComponent(checkpointFolderName, isDirectory: true)
    }

    /// Creates `Images/` and `Checkpoint/` in a new InProgress folder; throws
    /// `MapperError.ioFailed` when either exists and is not empty (the session would fail) or
    /// cannot be made. An existing empty folder is kept.
    static func prepare(_ folder: RawScanFolder) throws -> (images: URL, checkpoint: URL) {
        let images = imagesURL(in: folder)
        let checkpoint = checkpointURL(in: folder)
        for url in [images, checkpoint] {
            if StoreFiles.exists(url) {
                guard isEmptyDirectory(url) else {
                    throw MapperError.ioFailed("\(url.lastPathComponent) exists and is not an empty folder")
                }
                continue
            }
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } catch {
                throw MapperError.ioFailed("create \(url.lastPathComponent): \(StoreFiles.describe(error))")
            }
        }
        return (images: images, checkpoint: checkpoint)
    }

    /// True for an existing folder with no entries (hidden files count as entries).
    static func isEmptyDirectory(_ url: URL) -> Bool {
        guard StoreFiles.isDirectory(url),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
        return entries.isEmpty
    }

    /// Number of regular files directly in `images` whose extension is in `imageExtensions`
    /// (case-insensitive); 0 when the folder is missing.
    static func imageCount(in images: URL) -> Int {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: images, includingPropertiesForKeys: keys,
                                                                         options: [.skipsHiddenFiles]) else { return 0 }
        var count = 0
        for entry in entries where imageExtensions.contains(entry.pathExtension.lowercased()) {
            let values = try? entry.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true { count += 1 }
        }
        return count
    }

    /// After the session is released and the writer closed: moves `Checkpoint/` to
    /// `PhotogrammetryStore.checkpointURL` (replacing an older one; created with
    /// `ensureDirectory(_:inside: package.root)`), removes the four empty RawScanFolder
    /// subfolders InProgressScans made (mesh, keyframes, depth, photos; only when empty), then
    /// `InProgressScans.seal(_:into: package.rawObjectURL(objectID), package:root:)`.
    /// A retry after a crash between the move and the seal finds no `Checkpoint/` and seals.
    @discardableResult
    static func seal(_ folder: RawScanFolder, objectID: UUID, package: ProjectPackage, root: URL? = nil) throws -> SealFile {
        try moveCheckpoint(of: folder, objectID: objectID, package: package)
        removeEmptySubfolders(of: folder)
        let destination = package.rawObjectURL(objectID)
        let seal = try InProgressScans.seal(folder, into: destination, package: package, root: root)
        let images = seal.files.filter { $0.path.hasPrefix(imagesFolderName + "/") }.count
        ObjectCaptureSignals.log("object \(objectID) sealed: \(images) images, \(seal.files.count) files, \(seal.totalBytes) bytes")
        return seal
    }

    /// AppShell's RecoveryService (5d): an unsealed object scan can be built when it holds at
    /// least `minimumImages` images.
    static func canRecover(_ folder: RawScanFolder) -> Bool {
        imageCount(in: imagesURL(in: folder)) >= minimumImages
    }

    /// Removes everything inside `url` and keeps the (then empty) folder; creates it when missing.
    /// Used by PhotogrammetryStep's checkpoint retry.
    static func emptyDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if StoreFiles.isDirectory(url) {
            for name in try fm.contentsOfDirectory(atPath: url.path) {
                try fm.removeItem(at: url.appendingPathComponent(name))
            }
        } else {
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
        }
    }

    // MARK: Private

    /// Moves `<folder>/Checkpoint/` to the derived checkpoint, replacing an older one. Nothing to
    /// do when the scan has no checkpoint folder.
    private static func moveCheckpoint(of folder: RawScanFolder, objectID: UUID, package: ProjectPackage) throws {
        let source = checkpointURL(in: folder)
        guard StoreFiles.isDirectory(source) else { return }
        let target = PhotogrammetryStore.checkpointURL(package, object: objectID)
        try ProjectStore.ensureDirectory(PhotogrammetryStore.folder(package, object: objectID), inside: package.root)
        if StoreFiles.exists(target) {
            try StoreFiles.remove(target)
        }
        do {
            try FileManager.default.moveItem(at: source, to: target)
        } catch {
            throw MapperError.ioFailed("checkpoint move: \(StoreFiles.describe(error))")
        }
        ObjectCaptureSignals.log("object \(objectID): checkpoint moved to derived (\(StoreFiles.directorySize(target)) bytes)")
    }

    /// Removes the RawScanFolder subfolders an object scan never uses, only when empty.
    private static func removeEmptySubfolders(of folder: RawScanFolder) {
        for name in InProgressScans.subfolders {
            let url = folder.url.appendingPathComponent(name, isDirectory: true)
            guard isEmptyDirectory(url) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                ObjectCaptureSignals.log("remove empty \(name)/ failed: \(StoreFiles.describe(error))")
            }
        }
    }
}
