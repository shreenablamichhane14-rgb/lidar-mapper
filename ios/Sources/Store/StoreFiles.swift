import Foundation

/// File helpers shared by the Store module: existence tests, lexical containment, capped
/// reads, folder size walks, log-safe error text and the removal path (a rename into a
/// trash folder, then a background delete). Any thread.
enum StoreFiles {
    /// Name of the trash folder inside the app's temporary directory.
    static let trashFolderName = "MapperTrash"

    /// Serial queue that deletes trashed folders in the background.
    private static let cleanupQueue = DispatchQueue(label: "mapper.store.cleanup", qos: .utility)

    /// True when something exists at `url` (file or folder).
    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// True when `url` is an existing folder.
    static func isDirectory(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// True when `url` lies strictly inside `root`, comparing path components lexically, so
    /// it never depends on whether the files exist. `standardizedFileURL` is not used because
    /// it drops a leading "/private" only for paths that exist; instead "." components are
    /// ignored and a leading "/private" is dropped on both sides. A ".." below `root` fails.
    static func isInside(_ url: URL, root: URL) -> Bool {
        let base = lexicalComponents(root)
        let parts = lexicalComponents(url)
        guard parts.count > base.count else { return false }
        guard Array(parts.prefix(base.count)) == base else { return false }
        return !parts.dropFirst(base.count).contains("..")
    }

    /// Path components without "." entries and without a leading "/private" (so
    /// "/private/var/x" and "/var/x" compare equal).
    private static func lexicalComponents(_ url: URL) -> [String] {
        var parts = url.pathComponents.filter { $0 != "." }
        if parts.count > 2, parts[0] == "/", parts[1] == "private" {
            parts.remove(at: 1)
        }
        return parts
    }

    /// The project id of a package whose folder is named `<UUID>.mapperproj`, else nil.
    static func projectID(of package: ProjectPackage) -> UUID? {
        ProjectStore.projectID(fromPackageName: package.root.lastPathComponent)
    }

    /// Reads a whole file of at most `maxBytes`. Throws `CoreError.fileTooLarge` before
    /// reading anything when the file is larger (untrusted input, CR-4).
    static func readCapped(_ url: URL, maxBytes: Int64) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= maxBytes else {
            throw CoreError.fileTooLarge(name: url.lastPathComponent, bytes: size)
        }
        return try Data(contentsOf: url)
    }

    /// Size in bytes of the regular files under `url` (recursively), or of the file itself.
    /// Missing items count as 0 and unreadable entries are skipped; symbolic links are not
    /// followed. Walks the disk: call off the main thread for large folders.
    static func directorySize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard isDirectory(url) else {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return 0 }
            return Int64(values.fileSize ?? 0)
        }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                          options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        while let next = walker.nextObject() {
            guard let item = next as? URL,
                  let values = try? item.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Error text that is safe for the log: Core and Mapper errors verbatim (their payloads
    /// hold file names and diagnostics, never full paths), anything else as domain and code,
    /// because Foundation errors carry full file paths (ARCHITECTURE 11.4).
    static func describe(_ error: Error) -> String {
        if let core = error as? CoreError { return "\(core)" }
        if let mapper = error as? MapperError { return "\(mapper)" }
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }

    /// `tmp/MapperTrash/`, on the same volume as Documents and Application Support.
    static func trashRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(trashFolderName, isDirectory: true)
    }

    /// Removes a file or folder. Nothing to do when it is absent. A folder is renamed into
    /// the trash first (one fast metadata operation, so the caller never waits for a large
    /// delete) and deleted on a background queue; when the rename fails it is deleted in place.
    static func remove(_ url: URL) throws {
        guard exists(url) else { return }
        let fm = FileManager.default
        let target = trashRoot().appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: trashRoot(), withIntermediateDirectories: true)
            try fm.moveItem(at: url, to: target)
        } catch {
            LogStore.shared.write("trash rename failed (\(describe(error))), deleting in place", category: "store")
            try fm.removeItem(at: url)
            return
        }
        cleanupQueue.async {
            do {
                try FileManager.default.removeItem(at: target)
            } catch {
                LogStore.shared.write("trash delete failed: \(StoreFiles.describe(error))", category: "store")
            }
        }
    }

    /// Deletes whatever an earlier run left in the trash (a kill during a background
    /// delete), on the background queue.
    static func emptyTrash() {
        cleanupQueue.async {
            let root = StoreFiles.trashRoot()
            guard let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            else { return }
            for child in children {
                try? FileManager.default.removeItem(at: child)
            }
            if !children.isEmpty {
                LogStore.shared.write("emptied trash: \(children.count) items", category: "store")
            }
        }
    }
}
