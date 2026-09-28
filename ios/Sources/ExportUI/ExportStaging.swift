import Foundation

/// Staging folders under a package's `exports/` (docs/ARCHITECTURE.md 9, "Cleanup"): one
/// `exports/<yyyyMMdd-HHmmss>/` per export, deleted when its share finishes and, at launch,
/// when older than 24 hours. Only folders whose name is a staging stamp are ever removed, so
/// Results' `exports/simple/` and anything else in `exports/` are left alone. Any thread.
extension ExportRunner {
    /// Queue for removals requested from the main thread.
    private static let cleanupQueue = DispatchQueue(label: "mapper.export.cleanup", qos: .utility)

    /// Staging folder name of an export started at `date` (local time, POSIX locale).
    static func stagingName(for date: Date) -> String {
        ExportCatalog.posixFormatter(stampFormat).string(from: date)
    }

    /// The start time encoded in a staging folder name ("yyyyMMdd-HHmmss", optionally followed
    /// by "-n" for a second export in the same second); nil for any other name.
    static func stagingDate(folderName: String) -> Date? {
        let parts = folderName.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard parts[0].count == 8, parts[1].count == 6, isDigits(parts[0]), isDigits(parts[1]) else { return nil }
        if parts.count == 3 {
            guard !parts[2].isEmpty, parts[2].count <= 4, isDigits(parts[2]) else { return nil }
        }
        return ExportCatalog.posixFormatter(stampFormat).date(from: "\(parts[0])-\(parts[1])")
    }

    /// True when every character is an ASCII digit (and there is at least one).
    private static func isDigits(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }

    /// True when `folderName` is a staging stamp more than `seconds` away from `now` (in the past,
    /// or in the future after a clock change, so no folder stays forever).
    static func isStale(folderName: String, olderThan seconds: TimeInterval, now: Date) -> Bool {
        guard let date = stagingDate(folderName: folderName) else { return false }
        let age = now.timeIntervalSince(date)
        return age > seconds || -age > seconds
    }

    /// Creates a new, empty staging folder `exports/<stamp>[-n]/`. `exports/` is created only
    /// while the package exists (a late export after a delete fails instead of recreating it).
    static func makeStagingFolder(_ package: ProjectPackage, now: Date) throws -> URL {
        let exports = try ProjectStore.ensureDirectory(package.exportsURL, inside: package.root)
        let base = stagingName(for: now)
        let fm = FileManager.default
        for attempt in 1...100 {
            let name = attempt == 1 ? base : "\(base)-\(attempt)"
            let url = exports.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: url.path) { continue }
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: false)
                return url
            } catch {
                if fm.fileExists(atPath: url.path) { continue }
                throw error
            }
        }
        throw ExportError.writeFailed(path: "exports", reason: "no free staging folder name")
    }

    /// True when `folder` is a staging folder: a stamp-named folder directly inside `exports/`.
    static func isStagingFolder(_ folder: URL) -> Bool {
        let parent = folder.deletingLastPathComponent().lastPathComponent
        return parent == "exports" && stagingDate(folderName: folder.lastPathComponent) != nil
    }

    /// Deletes a staging folder now (off main). Anything that is not a staging folder is left
    /// alone; failures are logged.
    static func removeStagingFolder(_ folder: URL) {
        guard isStagingFolder(folder) else {
            LogStore.shared.write("export: refused to remove a folder that is not a staging folder", category: logCategory)
            return
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return }
        do {
            try fm.removeItem(at: folder)
        } catch {
            LogStore.shared.write("export: staging folder not removed (\(logDescription(error)))", category: logCategory)
        }
    }

    /// `removeStagingFolder` on a utility queue, for callers on the main thread (the share sheet).
    static func removeStagingFolderLater(_ folder: URL) {
        cleanupQueue.async { ExportRunner.removeStagingFolder(folder) }
    }

    /// At launch (AppShell): deletes `exports/<stamp>/` staging folders older than 24 hours in
    /// every package. Any thread.
    static func removeStaleStaging(olderThan seconds: TimeInterval = 86_400, now: Date = Date()) {
        let fm = FileManager.default
        guard let root = try? ProjectStore.projectsRoot(),
              let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        var removed = 0
        for child in children where ProjectStore.projectID(fromPackageName: child.lastPathComponent) != nil {
            removed += removeStaleStaging(inExports: ProjectPackage(root: child).exportsURL, olderThan: seconds, now: now)
        }
        if removed > 0 {
            LogStore.shared.write("export: removed \(removed) stale staging folder(s)", category: logCategory)
        }
    }

    /// Deletes the stale staging folders of one `exports/` folder; returns how many were removed.
    @discardableResult
    static func removeStaleStaging(inExports folder: URL, olderThan seconds: TimeInterval, now: Date) -> Int {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return 0
        }
        var removed = 0
        for child in children where isStale(folderName: child.lastPathComponent, olderThan: seconds, now: now) {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            do {
                try fm.removeItem(at: child)
                removed += 1
            } catch {
                LogStore.shared.write("export: stale staging folder not removed (\(logDescription(error)))", category: logCategory)
            }
        }
        return removed
    }
}
