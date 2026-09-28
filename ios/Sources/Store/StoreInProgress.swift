import Foundation

/// Kind of a raw scan folder.
enum RawScanKind: String, Codable, CaseIterable, Sendable { case room, meshPass, object }

/// `scan.json` inside every raw scan folder, written at creation and sealed with the folder.
struct InProgressScanInfo: Codable, Equatable, Sendable {
    /// File name inside the scan folder.
    static let fileName = "scan.json"
    /// Read cap for `scan.json`, bytes (untrusted input, CR-4).
    static let maxBytes: Int64 = 64 * 1024

    /// Identifier of the scan (also the InProgress folder name).
    var scanID: UUID
    /// Project the scan belongs to.
    var projectID: UUID
    /// ARKit capture session, when the scan belongs to one.
    var sessionID: UUID?
    /// Room the scan becomes (Room and House modes).
    var roomID: UUID?
    /// Room, mesh pass or object folder.
    var kind: RawScanKind
    /// Scan mode of the project when the scan started.
    var mode: ScanMode
    /// When the scan started.
    var startedAt: Date

    /// Creates the record written as `scan.json`.
    init(scanID: UUID, projectID: UUID, sessionID: UUID?, roomID: UUID?, kind: RawScanKind, mode: ScanMode, startedAt: Date) {
        self.scanID = scanID
        self.projectID = projectID
        self.sessionID = sessionID
        self.roomID = roomID
        self.kind = kind
        self.mode = mode
        self.startedAt = startedAt
    }
}

/// In-progress scans under Library/Application Support/InProgress/<scanID>/ (D5). Thread-safe.
/// Every function below also takes a trailing `root: URL? = nil` (nil means
/// `ProjectStore.inProgressRoot()`), so the self-test works in a temporary folder.
enum InProgressScans {
    /// Subfolders made in every new scan folder (the `RawScanFolder` layout).
    static let subfolders = ["mesh", "keyframes", "depth", "photos"]

    /// Creates the folder with subfolders mesh/, keyframes/, depth/, photos/, writes scan.json
    /// and excludes the new folder from backup (the root is excluded by Core's inProgressRoot()).
    /// Throws when a folder for `info.scanID` exists already; a half-made folder is removed.
    static func create(_ info: InProgressScanInfo, root: URL? = nil) throws -> RawScanFolder {
        let base = try resolveRoot(root, create: true)
        let url = base.appendingPathComponent(info.scanID.uuidString, isDirectory: true)
        guard !StoreFiles.exists(url) else {
            throw MapperError.ioFailed("InProgress scan \(info.scanID) exists")
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            for name in subfolders {
                try fm.createDirectory(at: url.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: false)
            }
            let infoURL = url.appendingPathComponent(InProgressScanInfo.fileName, isDirectory: false)
            try ProjectStore.writeJSON(info, to: infoURL, createParents: false)
        } catch {
            try? fm.removeItem(at: url)
            LogStore.shared.write("InProgress create \(info.scanID) failed: \(StoreFiles.describe(error))", category: "store")
            throw error
        }
        do {
            try ProjectStore.excludeFromBackup(url)
        } catch {
            LogStore.shared.write("InProgress \(info.scanID) backup exclusion failed: \(StoreFiles.describe(error))", category: "store")
        }
        LogStore.shared.write("InProgress scan \(info.scanID) created, kind \(info.kind.rawValue), project \(info.projectID)",
                              category: "store")
        return RawScanFolder(url: url)
    }

    /// The InProgress folder of `scanID`; throws `CoreError.missingFile` when it does not exist.
    static func folder(for scanID: UUID, root: URL? = nil) throws -> RawScanFolder {
        let base = try resolveRoot(root, create: false)
        let url = base.appendingPathComponent(scanID.uuidString, isDirectory: true)
        guard StoreFiles.isDirectory(url) else { throw CoreError.missingFile(scanID.uuidString) }
        return RawScanFolder(url: url)
    }

    /// Every InProgress folder with a readable scan.json, sealed or not. At launch AppShell's
    /// RecoveryService finishes sealed ones silently (a crash hit between seal and move) and
    /// offers "Recover unfinished scan" for unsealed ones (D5). Folders whose name is not a
    /// UUID, whose scan.json is unreadable or names another scan are skipped (logged).
    /// Oldest first.
    static func list(root: URL? = nil) -> [InProgressScanInfo] {
        let fm = FileManager.default
        guard let base = try? resolveRoot(root, create: false),
              let children = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return [] }
        var result: [InProgressScanInfo] = []
        for child in children where StoreFiles.isDirectory(child) {
            let name = child.lastPathComponent
            guard let id = UUID(uuidString: name), id.uuidString == name else { continue }
            let infoURL = child.appendingPathComponent(InProgressScanInfo.fileName, isDirectory: false)
            do {
                let info = try ProjectStore.readJSON(InProgressScanInfo.self, from: infoURL, maxBytes: InProgressScanInfo.maxBytes)
                guard info.scanID == id else {
                    LogStore.shared.write("InProgress \(id): scan.json names \(info.scanID); skipped", category: "store")
                    continue
                }
                result.append(info)
            } catch {
                LogStore.shared.write("InProgress \(id): unreadable scan.json (\(StoreFiles.describe(error))); skipped",
                                      category: "store")
            }
        }
        return result.sorted { $0.startedAt < $1.startedAt }
    }

    /// True when the folder already holds SEAL.json.
    static func isSealed(scanID: UUID, root: URL? = nil) -> Bool {
        guard let base = try? resolveRoot(root, create: false) else { return false }
        let folder = RawScanFolder(url: base.appendingPathComponent(scanID.uuidString, isDirectory: true))
        return StoreFiles.exists(folder.sealURL)
    }

    /// Writes SEAL.json (`ProjectStore.sealRawFolder`) unless one exists already (then only the
    /// move is repeated), moves the folder to `destination` (creating its parents with
    /// `ProjectStore.ensureDirectory(_:inside: package.root)`, so a deleted package is never
    /// recreated; fails if the destination exists), re-applies `excludeFromBackup` on the package raw/.
    ///
    /// Preconditions (checked, each failure throws before anything is written): `folder` is an
    /// existing folder inside the InProgress root, `destination` lies inside `package.root` and
    /// does not exist. The caller has closed its `RawScanWriter` (nothing may be written into
    /// the folder after SEAL.json).
    @discardableResult
    static func seal(_ folder: RawScanFolder, into destination: URL, package: ProjectPackage,
                     root: URL? = nil) throws -> SealFile {
        let base = try resolveRoot(root, create: false)
        let scanName = folder.url.lastPathComponent
        guard StoreFiles.isInside(folder.url, root: base) else {
            throw CoreError.corruptFile("seal \(scanName): folder is outside InProgress")
        }
        guard StoreFiles.isDirectory(folder.url) else { throw CoreError.missingFile(scanName) }
        guard StoreFiles.isInside(destination, root: package.root) else {
            throw CoreError.corruptFile("seal \(scanName): destination is outside the package")
        }
        guard !StoreFiles.exists(destination) else {
            throw MapperError.ioFailed("seal \(scanName): destination exists")
        }
        let seal: SealFile
        if let existing = existingSeal(folder) {
            seal = existing
        } else {
            seal = try ProjectStore.sealRawFolder(folder.url, now: Date())
        }
        try ProjectStore.ensureDirectory(destination.deletingLastPathComponent(), inside: package.root)
        try FileManager.default.moveItem(at: folder.url, to: destination)
        do {
            try ProjectStore.excludeFromBackup(package.rawURL)
        } catch {
            LogStore.shared.write("raw backup exclusion failed after seal: \(StoreFiles.describe(error))", category: "store")
        }
        LogStore.shared.write("sealed scan \(scanName): \(seal.files.count) files, \(seal.totalBytes) bytes", category: "store")
        return seal
    }

    /// Removes the InProgress folder of `scanID` (a cancelled scan or a declined recovery).
    /// Nothing to do when it is already gone. The caller has closed its writer first.
    static func discard(scanID: UUID, root: URL? = nil) throws {
        let base = try resolveRoot(root, create: false)
        let url = base.appendingPathComponent(scanID.uuidString, isDirectory: true)
        guard StoreFiles.exists(url) else { return }
        try StoreFiles.remove(url)
        LogStore.shared.write("InProgress scan \(scanID) discarded", category: "store")
    }

    /// The seal already in the folder (a crash hit between seal and move), or nil when there
    /// is none or it cannot be read (then the folder is sealed again; SEAL.json itself is
    /// never listed).
    private static func existingSeal(_ folder: RawScanFolder) -> SealFile? {
        guard StoreFiles.exists(folder.sealURL) else { return nil }
        do {
            return try ProjectStore.readJSON(SealFile.self, from: folder.sealURL)
        } catch {
            LogStore.shared.write("seal \(folder.url.lastPathComponent): unreadable SEAL.json, sealing again", category: "store")
            return nil
        }
    }

    /// The InProgress root: `root` when given (created only when `create`), else
    /// `ProjectStore.inProgressRoot()`.
    private static func resolveRoot(_ root: URL?, create: Bool) throws -> URL {
        guard let root = root else { return try ProjectStore.inProgressRoot() }
        if create { try ProjectStore.ensureDirectory(root) }
        return root
    }
}
