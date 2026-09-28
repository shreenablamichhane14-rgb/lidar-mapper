import Foundation

/// Package-level removals behind `ProjectLibrary.delete` and `discardRoom`, written against
/// a `ProjectPackage` so the self-test can run them in a temporary folder. Any thread. These
/// are the only raw removals besides `InProgressScans.discard` (and build 6 Free up space).
enum StorePackageOps {
    /// Removes the whole package folder (raw included) while holding the manifest lock, so
    /// no manifest update interleaves; a later update fails because the folder is gone.
    static func deletePackage(_ package: ProjectPackage) throws {
        try ManifestWriter.withLock {
            try StoreFiles.remove(package.root)
        }
        LogStore.shared.write("deleted project \(projectLabel(package))", category: "store")
    }

    /// The user discarded the scan just captured: removes that `RoomRecord`, its sealed raw
    /// room folder and `derived/rooms/<room>/`. When nothing is left (no other room and no
    /// object) the whole package is deleted instead. Returns the written manifest, or nil when
    /// the project was deleted. The manifest is written before the folders are removed, so a
    /// crash in between leaves an unreferenced folder, never a record without its data.
    static func discardRoom(_ roomID: UUID, in package: ProjectPackage) throws -> ProjectManifest? {
        var sessionHint: UUID?
        let deletedProject = try ManifestWriter.withLock { () throws -> Bool in
            let manifest = try ManifestWriter.read(package)
            sessionHint = manifest.rooms.first(where: { $0.id == roomID })?.sessionID
            let otherRooms = manifest.rooms.contains { $0.id != roomID }
            guard !otherRooms, manifest.objects.isEmpty else { return false }
            try StoreFiles.remove(package.root)
            return true
        }
        if deletedProject {
            LogStore.shared.write("discarded room \(roomID); project \(projectLabel(package)) had nothing left and was deleted",
                                  category: "store")
            return nil
        }
        let written = try ManifestWriter.update(package) { manifest in
            manifest.rooms.removeAll { $0.id == roomID }
        }
        let rawFolders = rawRoomFolders(roomID, sessionHint: sessionHint, in: package)
        for folder in rawFolders {
            try StoreFiles.remove(folder)
        }
        try StoreFiles.remove(package.derivedRoomURL(roomID))
        LogStore.shared.write("discarded room \(roomID) of project \(projectLabel(package)): \(rawFolders.count) raw folders",
                              category: "store")
        return written
    }

    /// Existing raw folders of `roomID`: the one under `sessionHint` when it exists, else
    /// every `raw/sessions/<s>/rooms/<roomID>/` found by listing the session folders.
    static func rawRoomFolders(_ roomID: UUID, sessionHint: UUID?, in package: ProjectPackage) -> [URL] {
        if let session = sessionHint {
            let hinted = package.rawRoomURL(session: session, room: roomID)
            if StoreFiles.isDirectory(hinted) { return [hinted] }
        }
        return sessionIDs(in: package)
            .map { package.rawRoomURL(session: $0, room: roomID) }
            .filter { StoreFiles.isDirectory($0) }
    }

    /// Session ids with a folder under `raw/sessions/` (canonical UUID names only), sorted.
    static func sessionIDs(in package: ProjectPackage) -> [UUID] {
        let sessionsRoot = package.rawURL.appendingPathComponent("sessions", isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: nil)
        else { return [] }
        return uuidFolders(children)
    }

    /// Mesh-pass folders under `raw/sessions/<s>/mesh-pass/` of every session (build 5), as
    /// (pass id, folder) pairs.
    static func meshPassFolders(in package: ProjectPackage) -> [(id: UUID, url: URL)] {
        var result: [(id: UUID, url: URL)] = []
        for session in sessionIDs(in: package) {
            let passesRoot = package.sessionURL(session).appendingPathComponent("mesh-pass", isDirectory: true)
            guard let children = try? FileManager.default.contentsOfDirectory(at: passesRoot, includingPropertiesForKeys: nil)
            else { continue }
            for pass in uuidFolders(children) {
                result.append((id: pass, url: package.rawMeshPassURL(session: session, pass: pass)))
            }
        }
        return result
    }

    /// The UUIDs of the folders among `children` whose name is a canonical uppercase UUID.
    private static func uuidFolders(_ children: [URL]) -> [UUID] {
        var ids: [UUID] = []
        for child in children where StoreFiles.isDirectory(child) {
            let name = child.lastPathComponent
            guard let id = UUID(uuidString: name), id.uuidString == name else { continue }
            ids.append(id)
        }
        return ids.sorted { $0.uuidString < $1.uuidString }
    }

    /// The project id for logs (never a path).
    private static func projectLabel(_ package: ProjectPackage) -> String {
        StoreFiles.projectID(of: package)?.uuidString ?? "?"
    }
}
