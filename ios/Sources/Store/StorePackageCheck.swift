import Foundation

/// Integrity check run when a project opens (Results) and after a restore (build 6). Any thread.
enum PackageCheck {
    /// `ProjectStore.verifyRawFolder` on every sealed room, mesh-pass and object folder of the
    /// manifest, plus the record path rule below; returns problem lines (also logged, category
    /// "store"). The caller marks the project `.needsAttention` through `ManifestWriter` when
    /// the list is not empty.
    ///
    /// Rooms: a room not in `.capturing` must have its sealed folder. Mesh passes (build 5)
    /// found under the manifest's sessions must be sealed. Objects are verified when their
    /// folder holds a SEAL.json (their capture layout is build 5's). Record paths in
    /// keyframes.jsonl and photos.jsonl must be safe and point at existing files.
    static func verify(_ package: ProjectPackage, manifest: ProjectManifest) -> [String] {
        var problems: [String] = []
        for room in manifest.rooms {
            let url = package.rawRoomURL(session: room.sessionID, room: room.id)
            problems += verifyFolder(url, label: "room \(room.id)", required: room.status != .capturing)
        }
        for pass in StorePackageOps.meshPassFolders(in: package) {
            problems += verifyFolder(pass.url, label: "mesh pass \(pass.id)", required: true)
        }
        for object in manifest.objects {
            let url = package.rawObjectURL(object.id)
            guard StoreFiles.exists(package.sealURL(in: url)) else { continue }
            problems += verifyFolder(url, label: "object \(object.id)", required: false)
        }
        if problems.isEmpty {
            LogStore.shared.write("package check \(manifest.id): ok", category: "store")
        } else {
            LogStore.shared.write("package check \(manifest.id): \(problems.count) problems", category: "store")
            for line in problems.prefix(50) {
                LogStore.shared.write("package check \(manifest.id): \(line)", category: "store")
            }
        }
        return problems
    }

    /// A path stored in a record (`KeyframeRecord.imageFile`, `depthFile`, `PhotoPin.imageFile`)
    /// is safe when Core's `RawScanFolder.isSafeRelativePath` accepts it (CR-4); readers then
    /// open files only through `RawScanFolder.resolve`, which returns nil for anything else.
    static func isSafeRecordPath(_ path: String) -> Bool {
        RawScanFolder.isSafeRelativePath(path)
    }

    /// Problems of one raw folder: missing (when `required`), unsealed (when `required`), seal
    /// mismatches, and record paths. Every line starts with `label`.
    static func verifyFolder(_ url: URL, label: String, required: Bool) -> [String] {
        guard StoreFiles.isDirectory(url) else {
            return required ? ["\(label): raw folder missing"] : []
        }
        let folder = RawScanFolder(url: url)
        guard StoreFiles.exists(folder.sealURL) else {
            return required ? ["\(label): not sealed"] : []
        }
        let sealProblems = ProjectStore.verifyRawFolder(url)
        var problems = sealProblems.map { "\(label): \($0)" }
        let known = Set(sealProblems)
        for line in recordProblems(folder) where !known.contains(line) {
            problems.append("\(label): \(line)")
        }
        return problems
    }

    /// Unsafe or dangling file paths in keyframes.jsonl and photos.jsonl. A dangling path is
    /// reported as "missing <path>", the same text as the seal check, so the caller can drop
    /// duplicates.
    static func recordProblems(_ folder: RawScanFolder) -> [String] {
        var problems: [String] = []
        do {
            let keyframes = try RawScanReader.jsonLines(KeyframeRecord.self, at: folder.keyframesLogURL).records
            for record in keyframes {
                problems += pathProblems(record.imageFile, in: folder, owner: "keyframe \(record.index)")
                if let depth = record.depthFile {
                    problems += pathProblems(depth, in: folder, owner: "keyframe \(record.index)")
                }
            }
        } catch {
            problems.append("keyframes.jsonl unreadable: \(StoreFiles.describe(error))")
        }
        do {
            let photos = try RawScanReader.jsonLines(PhotoPin.self, at: folder.photosLogURL).records
            for pin in photos {
                problems += pathProblems(pin.imageFile, in: folder, owner: "photo \(pin.id)")
            }
        } catch {
            problems.append("photos.jsonl unreadable: \(StoreFiles.describe(error))")
        }
        return problems
    }

    /// One record path: unsafe, or safe but not an existing file.
    private static func pathProblems(_ path: String, in folder: RawScanFolder, owner: String) -> [String] {
        guard isSafeRecordPath(path), let url = folder.resolve(path) else {
            return ["\(owner): unsafe path"]
        }
        guard StoreFiles.exists(url) else { return ["missing \(path)"] }
        return []
    }
}
