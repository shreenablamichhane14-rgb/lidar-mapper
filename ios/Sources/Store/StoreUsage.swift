import Foundation

/// Bytes used per package part.
struct PackageUsage: Equatable, Sendable {
    /// `raw/`.
    var raw: Int64
    /// `derived/`.
    var derived: Int64
    /// `edits/`.
    var edits: Int64
    /// `exports/`.
    var exports: Int64
    /// The whole package: the four parts plus the root files (project.json, thumbnail.jpg).
    var total: Int64

    /// No bytes.
    static let zero = PackageUsage(raw: 0, derived: 0, edits: 0, exports: 0, total: 0)
}

/// Storage accounting for Settings and the project rows (ARCHITECTURE 12.3). Sizes are the
/// logical sizes of regular files; missing folders count as 0. Every function walks the
/// disk, so call it off the main thread.
enum StorageUsage {
    /// Walks the folder, any thread.
    static func usage(of package: ProjectPackage) -> PackageUsage {
        let raw = StoreFiles.directorySize(package.rawURL)
        let derived = StoreFiles.directorySize(package.derivedURL)
        let edits = StoreFiles.directorySize(package.editsURL)
        let exports = StoreFiles.directorySize(package.exportsURL)
        let parts: Set<String> = [package.rawURL.lastPathComponent, package.derivedURL.lastPathComponent,
                                  package.editsURL.lastPathComponent, package.exportsURL.lastPathComponent]
        var rootFiles: Int64 = 0
        let children = (try? FileManager.default.contentsOfDirectory(at: package.root, includingPropertiesForKeys: nil)) ?? []
        for child in children where !parts.contains(child.lastPathComponent) {
            rootFiles += StoreFiles.directorySize(child)
        }
        let total = raw + derived + edits + exports + rootFiles
        return PackageUsage(raw: raw, derived: derived, edits: edits, exports: exports, total: total)
    }

    /// Bytes under `Documents/Projects` (0 when it cannot be opened).
    static func projectsTotal() -> Int64 {
        guard let root = try? ProjectStore.projectsRoot() else { return 0 }
        return StoreFiles.directorySize(root)
    }

    /// Bytes under `Library/Application Support/InProgress` (0 when it cannot be opened).
    static func inProgressTotal() -> Int64 {
        guard let root = try? ProjectStore.inProgressRoot() else { return 0 }
        return StoreFiles.directorySize(root)
    }
}
