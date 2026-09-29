import Foundation

/// What launch recovery does with a project left in `.capturing` (ARCHITECTURE 3.4 item 5).
enum CapturingFix: Equatable, Sendable {
    /// Sealed room folders are missing from the manifest: add them and process the project.
    case addRoomsAndProcess
    /// The rooms are listed already: process the project.
    case process
    /// No rooms yet, but an unfinished scan names the project: wait for the user's choice.
    case keepForRecovery
    /// Nothing to keep: delete the project.
    case delete
}

/// Unfinished scan recovery at launch (D5, ARCHITECTURE 3.4): finishes scans that were sealed
/// but not moved, offers unsealed ones to the user, and reconciles projects left in
/// `.capturing`. Everything here runs once at launch or from the recovery sheet.
enum RecoveryService {
    /// Log category.
    static let logCategory = "appshell"

    /// A sealed room folder of a package: its session, room and folder.
    struct SealedRoomFolder: Equatable, Sendable {
        /// The capture session (folder `raw/sessions/<session>`).
        var sessionID: UUID
        /// The room (folder `rooms/<room>`).
        var roomID: UUID
        /// The folder.
        var folder: RawScanFolder
    }

    // MARK: - Public API

    /// Unsealed InProgress folders to offer to the user. Before returning, sealed ones (a crash hit
    /// between seal and move) are finished silently: moved, RoomRecord added or updated, enqueued.
    /// It also reconciles every project still in `.capturing` (a kill during the quality sheet, an
    /// engine start that threw, a crash between the seal move and the manifest update): it adds a
    /// RoomRecord for each sealed `raw/sessions/*/rooms/*` folder missing from `manifest.rooms`
    /// (from scan.json and RawScanReader), sets `.needsProcessing` when the project has rooms, and
    /// deletes it when it has no rooms and no InProgress scan.json names its projectID.
    /// Main actor (called once at launch; the moves are renames on one volume).
    ///
    /// Only room scans are offered (build 4 makes no other kind); an unsealed scan that holds
    /// no scanned data at all (no mesh, no keyframes, no RoomPlan file) is discarded silently.
    @MainActor static func pending() -> [InProgressScanInfo] {
        var offered: [InProgressScanInfo] = []
        for info in InProgressScans.list() {
            if InProgressScans.isSealed(scanID: info.scanID) {
                finishSealed(info)
            } else if info.kind != .room || info.roomID == nil {
                log("unfinished \(info.kind.rawValue) scan \(short(info.scanID)) left for a later version")
            } else if let folder = try? InProgressScans.folder(for: info.scanID), !hasScannedData(folder) {
                log("unfinished scan \(short(info.scanID)) holds no scanned data; discarded")
                do {
                    try discard(info)
                } catch {
                    log("empty scan \(short(info.scanID)) could not be removed: \(StoreFiles.describe(error))")
                }
            } else {
                offered.append(info)
            }
        }
        reconcileCapturingProjects()
        if !offered.isEmpty { log("\(offered.count) unfinished scans to offer") }
        return offered
    }

    /// Seals into the project's room folder (JSON Lines tolerate a torn last line; no roomlog.json
    /// is written), adds the RoomRecord (.captured), enqueues processing. A missing project (it was
    /// deleted) makes recover create a new Room project for the scan.
    @MainActor static func recover(_ info: InProgressScanInfo) throws {
        let projectID = try moveIntoProject(info)
        log("recovered scan \(short(info.scanID)) into project \(short(projectID))")
        ProcessingPlans.enqueue(projectID: projectID, atFront: false)
    }

    /// Removes the InProgress folder, then deletes its project when that leaves it with no rooms.
    static func discard(_ info: InProgressScanInfo) throws {
        try InProgressScans.discard(scanID: info.scanID)
        let package = try ProjectStore.package(for: info.projectID)
        guard FileManager.default.fileExists(atPath: package.manifestURL.path) else { return }
        let manifest: ProjectManifest
        do {
            manifest = try ManifestWriter.read(package)
        } catch {
            log("discard: project \(short(info.projectID)) unreadable (\(StoreFiles.describe(error))); kept")
            return
        }
        let otherScans = InProgressScans.list().contains { $0.projectID == info.projectID }
        guard manifest.rooms.isEmpty, manifest.objects.isEmpty, !otherScans else { return }
        try StorePackageOps.deletePackage(package)
        ManifestWriter.postChange(info.projectID)
        log("discard: project \(short(info.projectID)) had no rooms left and was deleted")
    }

    /// Pure decision behind `pending()` for one `.capturing` project (tested).
    /// `sealedRoomFolders` counts the sealed room folders on disk that `manifest.rooms` does not
    /// list; `hasInProgressScan` is true when an unsealed InProgress scan.json names the project.
    static func reconcile(roomsInManifest: Int, sealedRoomFolders: Int, hasInProgressScan: Bool) -> CapturingFix {
        if sealedRoomFolders > 0 { return .addRoomsAndProcess }
        if roomsInManifest > 0 { return .process }
        if hasInProgressScan { return .keepForRecovery }
        return .delete
    }

    // MARK: - Files (any thread)

    /// Sealed room folders of a package (`raw/sessions/<s>/rooms/<r>/` with SEAL.json and a
    /// readable room scan.json), sorted by session and room. Folders whose names are not
    /// canonical UUIDs are ignored.
    static func sealedRoomFolders(in package: ProjectPackage) -> [SealedRoomFolder] {
        var result: [SealedRoomFolder] = []
        let fm = FileManager.default
        for session in StorePackageOps.sessionIDs(in: package) {
            let roomsRoot = package.sessionURL(session).appendingPathComponent("rooms", isDirectory: true)
            guard let children = try? fm.contentsOfDirectory(at: roomsRoot, includingPropertiesForKeys: nil) else { continue }
            let names = children.map { $0.lastPathComponent }.sorted()
            for name in names {
                guard let room = UUID(uuidString: name), room.uuidString == name else { continue }
                let folder = RawScanFolder(url: package.rawRoomURL(session: session, room: room))
                guard StoreFiles.isDirectory(folder.url), StoreFiles.exists(folder.sealURL) else { continue }
                guard let info = RawScanReader(folder: folder).info(), info.kind == .room else { continue }
                result.append(SealedRoomFolder(sessionID: session, roomID: room, folder: folder))
            }
        }
        return result
    }

    /// True when an unfinished scan holds anything worth keeping: a mesh chunk, keyframes or a
    /// RoomPlan file.
    static func hasScannedData(_ folder: RawScanFolder) -> Bool {
        let fm = FileManager.default
        let files = [folder.capturedRoomDataURL, folder.capturedRoomURL, folder.liveCapturedRoomURL, folder.keyframesLogURL]
        if files.contains(where: { fm.fileExists(atPath: $0.path) }) { return true }
        return !RawScanReader(folder: folder).meshChunkURLs().isEmpty
    }

    /// The RoomRecord of a sealed room folder: `.captured`, keyframes counted from
    /// keyframes.jsonl, captured at the seal time (or `fallbackDate`).
    static func roomRecord(roomID: UUID, sessionID: UUID, folder: RawScanFolder, fallbackDate: Date) -> RoomRecord {
        let reader = RawScanReader(folder: folder)
        let keyframes = (try? reader.keyframes().count) ?? 0
        let seal = try? ProjectStore.readJSON(SealFile.self, from: folder.sealURL)
        return RoomRecord(id: roomID, name: "", sessionID: sessionID, floorIndex: 0, status: .captured,
                          capturedRoomID: nil, quality: nil, hasMeshPass: false, keyframeCount: keyframes,
                          capturedAt: seal?.sealedAt ?? fallbackDate, frameLink: .projectFrame(sessionID: sessionID))
    }

    // MARK: - Launch steps (main actor)

    /// A scan sealed but not moved: move it, record the room, enqueue (logged on failure; the
    /// folder then stays for the next launch).
    @MainActor private static func finishSealed(_ info: InProgressScanInfo) {
        guard info.kind == .room, info.roomID != nil else {
            log("sealed \(info.kind.rawValue) scan \(short(info.scanID)) left for a later version")
            return
        }
        do {
            let projectID = try moveIntoProject(info)
            log("sealed scan \(short(info.scanID)) finished into project \(short(projectID))")
            ProcessingPlans.enqueue(projectID: projectID, atFront: false)
        } catch {
            log("sealed scan \(short(info.scanID)) could not be finished: \(StoreFiles.describe(error))")
        }
    }

    /// Moves a room scan into its project (or a new Room project when that one is gone), adds
    /// the session and the RoomRecord and sets `.needsProcessing`. Returns the project id.
    @MainActor private static func moveIntoProject(_ info: InProgressScanInfo) throws -> UUID {
        guard info.kind == .room, let roomID = info.roomID else {
            throw MapperError.ioFailed("recover: not a room scan")
        }
        let sessionID = info.sessionID ?? info.scanID
        let folder = try InProgressScans.folder(for: info.scanID)
        let target = try targetProject(for: info)
        let destination = target.package.rawRoomURL(session: sessionID, room: roomID)
        let seal = try InProgressScans.seal(folder, into: destination, package: target.package)
        let record = roomRecord(roomID: roomID, sessionID: sessionID, folder: RawScanFolder(url: destination),
                                fallbackDate: seal.sealedAt)
        let session = CaptureSessionRef(id: sessionID, startedAt: info.startedAt,
                                        frameLink: .projectFrame(sessionID: sessionID), worldMapFile: nil)
        try ProjectLibrary.shared.update(target.id) { manifest in
            if !manifest.sessions.contains(where: { $0.id == sessionID }) {
                manifest.sessions.append(session)
            }
            manifest.rooms.removeAll { $0.id == roomID }
            manifest.rooms.append(record)
            manifest.status = .needsProcessing
        }
        return target.id
    }

    /// The scan's project when its manifest still exists, else a new Room project named like a
    /// new scan of that day.
    @MainActor private static func targetProject(for info: InProgressScanInfo) throws -> (id: UUID, package: ProjectPackage) {
        let package = try ProjectStore.package(for: info.projectID)
        if FileManager.default.fileExists(atPath: package.manifestURL.path) {
            return (info.projectID, package)
        }
        let name = ScanFlowModel.defaultProjectName(mode: .room, now: info.startedAt)
        let created = try ProjectLibrary.shared.create(kind: .room, name: name)
        log("project \(short(info.projectID)) is gone; scan \(short(info.scanID)) goes to new project \(short(created.1.id))")
        return (created.1.id, created.0)
    }

    /// Reconciles every project still in `.capturing` (see `pending()`). Every InProgress scan
    /// still on disk (offered, of another kind, or sealed but not movable) keeps its project.
    @MainActor private static func reconcileCapturingProjects() {
        let waiting = Set(InProgressScans.list().map { $0.projectID })
        for manifest in ProjectStore.listProjects() where manifest.status == .capturing {
            let id = manifest.id
            guard let package = try? ProjectStore.package(for: id) else { continue }
            let listed = Set(manifest.rooms.map { $0.id })
            let missing = sealedRoomFolders(in: package).filter { !listed.contains($0.roomID) }
            let fix = reconcile(roomsInManifest: manifest.rooms.count, sealedRoomFolders: missing.count,
                                hasInProgressScan: waiting.contains(id))
            log("capturing project \(short(id)): \(manifest.rooms.count) rooms, \(missing.count) unlisted sealed rooms -> \(fix)")
            apply(fix, projectID: id, missing: missing, now: Date())
        }
    }

    /// Carries out one reconcile decision (failures are logged).
    @MainActor private static func apply(_ fix: CapturingFix, projectID: UUID, missing: [SealedRoomFolder], now: Date) {
        do {
            switch fix {
            case .addRoomsAndProcess:
                let records = missing.map {
                    roomRecord(roomID: $0.roomID, sessionID: $0.sessionID, folder: $0.folder, fallbackDate: now)
                }
                try ProjectLibrary.shared.update(projectID) { manifest in
                    for record in records {
                        manifest.rooms.removeAll { $0.id == record.id }
                        manifest.rooms.append(record)
                        if !manifest.sessions.contains(where: { $0.id == record.sessionID }) {
                            manifest.sessions.append(CaptureSessionRef(id: record.sessionID, startedAt: record.capturedAt,
                                                                       frameLink: record.frameLink, worldMapFile: nil))
                        }
                    }
                    manifest.status = .needsProcessing
                }
            case .process:
                try ProjectLibrary.shared.update(projectID) { manifest in
                    manifest.status = .needsProcessing
                }
            case .keepForRecovery:
                break
            case .delete:
                try ProjectLibrary.shared.delete(projectID)
            }
        } catch {
            log("capturing project \(short(projectID)): \(fix) failed: \(StoreFiles.describe(error))")
        }
    }

    // MARK: - Log

    /// Writes one line to the app log (ids only).
    static func log(_ message: String) {
        LogStore.shared.write("recovery: " + message, category: logCategory)
    }

    /// First 8 characters of an id for the log.
    static func short(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }
}
