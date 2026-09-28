import Foundation

/// Store notifications.
extension Notification.Name {
    /// Posted on the main queue after a manifest was written; `object` is the project UUID.
    /// Also posted after a project was deleted (the manifest is then gone).
    static let mapperManifestDidChange = Notification.Name("mapper.manifestDidChange")
    /// Posted on the main queue after edits/editlog.json or edits/measurements.json changed; `object` is the project UUID.
    static let mapperEditsDidChange = Notification.Name("mapper.editsDidChange")
}

/// Serialized read-modify-write of project.json from any thread (one process-wide lock).
///
/// The lock is an `NSRecursiveLock` plus a depth counter: a nested call from inside a
/// `mutate` closure or a `withLock` body throws `MapperError.ioFailed` instead of
/// deadlocking or silently losing the outer change. Writes pass `createParents: false`, so an
/// update that races a project delete fails instead of recreating the package folder.
enum ManifestWriter {
    /// The lock and the nesting depth (the depth is only touched while the lock is held).
    private final class LockState {
        /// The process-wide manifest lock.
        let lock = NSRecursiveLock()
        /// Number of `withLock` bodies running on the thread that holds the lock.
        var depth = 0
    }

    /// The one lock for every manifest in the process.
    private static let state = LockState()

    /// Reads the manifest (Core `ProjectStore.readManifest`). No lock is needed: writes are
    /// atomic renames, so a reader always sees a whole file.
    static func read(_ package: ProjectPackage) throws -> ProjectManifest {
        try ProjectStore.readManifest(package)
    }

    /// Applies `mutate` under the lock, sets `modifiedAt = now`, writes atomically, posts
    /// `.mapperManifestDidChange` on main, returns the written manifest. The project id cannot
    /// change (a changed id is restored and logged). `mutate` must not call `ManifestWriter`.
    @discardableResult
    static func update(_ package: ProjectPackage, now: Date = Date(),
                       _ mutate: (inout ProjectManifest) throws -> Void) throws -> ProjectManifest {
        let written = try withLock { () throws -> ProjectManifest in
            var manifest = try ProjectStore.readManifest(package)
            let originalID = manifest.id
            try mutate(&manifest)
            if manifest.id != originalID {
                LogStore.shared.write("manifest update tried to change id \(originalID); kept", category: "store")
                manifest.id = originalID
            }
            manifest.modifiedAt = now
            try ProjectStore.writeJSON(manifest, to: package.manifestURL, createParents: false)
            return manifest
        }
        postChange(written.id)
        return written
    }

    /// Runs `body` while holding the manifest lock (used for project deletion, so no update
    /// interleaves with it). Throws `MapperError.ioFailed` when called from inside another
    /// `withLock` body or `update` closure on the same thread.
    static func withLock<T>(_ body: () throws -> T) throws -> T {
        let shared = state
        shared.lock.lock()
        defer { shared.lock.unlock() }
        guard shared.depth == 0 else {
            LogStore.shared.write("nested manifest write refused", category: "store")
            throw MapperError.ioFailed("nested manifest write")
        }
        shared.depth += 1
        defer { shared.depth -= 1 }
        return try body()
    }

    /// Posts `.mapperManifestDidChange` for `id` on the main queue (always asynchronously, so
    /// observers never run inside a caller's write).
    static func postChange(_ id: UUID) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .mapperManifestDidChange, object: id)
        }
    }
}
