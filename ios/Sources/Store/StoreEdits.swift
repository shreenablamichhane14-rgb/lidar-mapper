import Foundation

/// edits/editlog.json and edits/measurements.json with a process-wide lock. Posts
/// `.mapperEditsDidChange` on main after every write.
///
/// Writes go through `ProjectStore.writeJSON` (atomic, `.completeFileProtectionUnlessOpen`
/// under edits/ by Core's default) with `createParents: false` after
/// `ensureDirectory(_:inside: package.root)`, so a deleted project is never recreated. A write
/// also bumps the manifest's `modifiedAt` (best effort), because the manifest documents it
/// as the time of the last change to the manifest, edits or derived products.
enum EditStore {
    /// Read cap of editlog.json, bytes (ARCHITECTURE 11.3: 16 MB).
    static let maxEditLogBytes: Int64 = 16 * 1024 * 1024
    /// Read cap of measurements.json, bytes.
    static let maxMeasurementsBytes: Int64 = 16 * 1024 * 1024

    /// The one lock for both edit files of every project.
    private static let lock = NSLock()

    /// The edit log; empty when absent or unreadable (logged).
    static func load(_ package: ProjectPackage) -> EditLog {
        locked {
            do {
                return try readLog(package)
            } catch {
                LogStore.shared.write("edit log of \(label(package)) unreadable: \(StoreFiles.describe(error))", category: "store")
                return EditLog()
            }
        }
    }

    /// Appends an operation (dropping the redo tail) and writes the log. Throws, without
    /// writing, when an existing log cannot be read, so a damaged file is never replaced.
    @discardableResult
    static func append(_ op: EditOperation, to package: ProjectPackage) throws -> EditLog {
        try change(package) { log in
            log.append(op)
            return true
        }
    }

    /// Undoes the last active operation; the log is unchanged (and not written) when there
    /// is nothing to undo.
    @discardableResult
    static func undo(_ package: ProjectPackage) throws -> EditLog {
        try change(package) { log in
            log.undo()
        }
    }

    /// Redoes the first undone operation; the log is unchanged (and not written) when there
    /// is nothing to redo.
    @discardableResult
    static func redo(_ package: ProjectPackage) throws -> EditLog {
        try change(package) { log in
            log.redo()
        }
    }

    /// Saved measurements; empty when absent or unreadable (logged).
    static func loadMeasurements(_ package: ProjectPackage) -> [MeasurementRecord] {
        locked { () -> [MeasurementRecord] in
            let url = package.measurementsURL
            guard StoreFiles.exists(url) else { return [] }
            do {
                return try ProjectStore.readJSON([MeasurementRecord].self, from: url, maxBytes: maxMeasurementsBytes)
            } catch {
                LogStore.shared.write("measurements of \(label(package)) unreadable: \(StoreFiles.describe(error))",
                                      category: "store")
                return []
            }
        }
    }

    /// Replaces the saved measurements.
    static func saveMeasurements(_ records: [MeasurementRecord], to package: ProjectPackage) throws {
        try locked {
            try write(records, to: package.measurementsURL, in: package)
        }
        didChange(package)
    }

    /// Reads, lets `body` change the log (true when it changed), writes it when changed and
    /// notifies after the lock is released.
    private static func change(_ package: ProjectPackage, _ body: (inout EditLog) -> Bool) throws -> EditLog {
        let outcome = try locked { () throws -> (log: EditLog, changed: Bool) in
            var log = try readLog(package)
            let changed = body(&log)
            if changed {
                try write(log, to: package.editLogURL, in: package)
            }
            return (log: log, changed: changed)
        }
        if outcome.changed {
            didChange(package)
        }
        return outcome.log
    }

    /// The log on disk: empty when the file is absent; throws when it is unreadable.
    private static func readLog(_ package: ProjectPackage) throws -> EditLog {
        let url = package.editLogURL
        guard StoreFiles.exists(url) else { return EditLog() }
        return try ProjectStore.readJSON(EditLog.self, from: url, maxBytes: maxEditLogBytes)
    }

    /// Writes one edits file (the edits folder is created only inside an existing package).
    private static func write<T: Encodable>(_ value: T, to url: URL, in package: ProjectPackage) throws {
        try ProjectStore.ensureDirectory(package.editsURL, inside: package.root)
        try ProjectStore.writeJSON(value, to: url, createParents: false)
    }

    /// Posts `.mapperEditsDidChange` on main and bumps the manifest's `modifiedAt`.
    private static func didChange(_ package: ProjectPackage) {
        let id = StoreFiles.projectID(of: package)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .mapperEditsDidChange, object: id)
        }
        do {
            try ManifestWriter.update(package) { _ in }
        } catch {
            LogStore.shared.write("edits of \(label(package)): manifest time not updated (\(StoreFiles.describe(error)))",
                                  category: "store")
        }
    }

    /// Runs `body` while holding the edits lock.
    private static func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// The project id for logs.
    private static func label(_ package: ProjectPackage) -> String {
        StoreFiles.projectID(of: package)?.uuidString ?? "?"
    }
}
