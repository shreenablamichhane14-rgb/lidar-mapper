import Foundation

// Pure rules of the House / Building flow (docs/MODULES.md 3.41): room list rows and statuses,
// progress text, the low memory suggestion (D17), the Show Missing Areas rule (D19), preflight
// errors, room name suggestions, the alerts of the flow and every manifest change the flow makes
// (HouseManifestRules). Nonisolated, deterministic, safe on any queue; the self-test calls them.

/// Status of one room in the room list.
enum HouseRoomStatus: Equatable, Sendable { case done, needsScan, needsLineUp, notProcessed }

/// One room list row (pure presentation, `HousePresentation.rows`).
struct HouseRoomRow: Identifiable, Equatable, Sendable {
    /// `RoomRecord.id`.
    var id: UUID
    /// User name, else "Room n" (`Copy.FloorPlan.defaultRoomTitle`).
    var title: String
    /// `Copy.House.roomDone` / `roomNeedsScan` / `roomNotScanned`, `Copy.HouseUI.roomNeedsLineUp`.
    var statusText: String
    /// The status the text describes.
    var status: HouseRoomStatus
    /// Index into `ProjectManifest.floors`.
    var floorIndex: Int
    /// `FloorRecord.name`, else `Copy.House.floorLabel(index + 1)`.
    var floorTitle: String
    /// VoiceOver text: `Copy.A11y.roomDone` / `roomNeedsScan`, else the status text.
    var accessibility: String
}

/// One floor of the room list: its title and rows.
struct HouseFloorSection: Identifiable, Equatable, Sendable {
    /// Floor index.
    var id: Int
    /// Floor title (`HouseRoomRow.floorTitle`).
    var title: String
    /// Rows of the floor, in list order.
    var rows: [HouseRoomRow]
}

/// Buttons of the house flow's alerts (ScanUI's `ScanAlertAction` has no house actions).
enum HouseAlertAction: Equatable, Hashable, Sendable {
    case ok, openSettings, resume, finishNow, startFresh, keepLooking, lineUp(UUID), rescan(UUID), joinAgain, cancel
}

/// One alert of the house flow: text from Copy plus its buttons.
struct HouseAlert: Identifiable, Equatable {
    /// Stable identifier (the error or alert key), also used in logs.
    var id: String
    /// Alert title.
    var title: String
    /// Alert message.
    var body: String
    /// Buttons, in display order.
    var actions: [HouseAlertAction]

    /// ScanUI's `ScanErrorCopy.alert(for:)` text with its actions mapped one to one.
    static func from(_ alert: ScanAlert) -> HouseAlert {
        let mapped = alert.actions.map { action -> HouseAlertAction in
            switch action {
            case .ok: return .ok
            case .openSettings: return .openSettings
            case .finishNow: return .finishNow
            case .resume: return .resume
            }
        }
        return HouseAlert(id: alert.id, title: alert.title, body: alert.body, actions: mapped)
    }

    /// "Mapper lost its place" after `sceneTooLarge` right after relocalizing: Start Fresh Here or OK.
    static func relocalizationLost() -> HouseAlert {
        HouseAlert(id: "house.relocalizeLost", title: Copy.HouseUI.relocalizeLost.title,
                   body: Copy.HouseUI.relocalizeLost.body, actions: [.startFresh, .ok])
    }

    /// "These rooms didn't line up" for one room: Line Up by Hand, Scan Doorway Again, Cancel.
    static func alignFailed(room: UUID) -> HouseAlert {
        HouseAlert(id: "house.alignFailed." + room.uuidString, title: Copy.House.alignFailedTitle,
                   body: Copy.House.alignFailedBody, actions: [.lineUp(room), .rescan(room), .cancel])
    }

    /// "Rooms weren't joined automatically" after a crashed merge: Join Rooms Again or Cancel.
    static func mergeFailed() -> HouseAlert {
        HouseAlert(id: "house.mergeFailed", title: Copy.HouseUI.mergeFailedTitle, body: Copy.HouseUI.mergeFailedBody,
                   actions: [.joinAgain, .cancel])
    }

    /// Button title of an action (Copy).
    static func title(for action: HouseAlertAction) -> String {
        switch action {
        case .ok: return Copy.Errors.ok
        case .openSettings: return Copy.Permissions.openSettings
        case .resume: return Copy.Scanning.resume
        case .finishNow: return Copy.ScanUI.finishNow
        case .startFresh: return Copy.HouseUI.startFresh
        case .keepLooking: return Copy.HouseUI.keepLooking
        case .lineUp: return Copy.House.alignManual
        case .rescan: return Copy.House.alignRescanDoorway
        case .joinAgain: return Copy.HouseUI.joinRoomsAgain
        case .cancel: return Copy.Project.cancel
        }
    }

    /// True for the button that only closes the alert (drawn with the cancel role).
    static func isDismissal(_ action: HouseAlertAction) -> Bool {
        action == .ok || action == .cancel
    }
}

/// Naming prompt after a room is kept.
struct HouseNamingRequest: Identifiable, Equatable {
    /// The room being named.
    var id: UUID
    /// Suggested names, the detected section name first.
    var suggestions: [String]
    /// The current name (empty for a new room; a rescan keeps the old room's name).
    var current: String
}

/// Pure presentation rules of the house flow.
enum HousePresentation {
    /// D17: suggest finishing the floor below this much available memory after a room.
    static let lowMemoryBytes: UInt64 = 800_000_000
    /// Longest room name kept, in characters (the project name limit of Store).
    static let maxRoomNameLength = 120

    /// Active rooms only (Structure `activeRooms`), floor then capture order.
    static func rows(manifest: ProjectManifest, report: StructureReport, userAligned: Set<UUID>) -> [HouseRoomRow] {
        let active = StructureEligibility.activeRooms(manifest)
        var numbered: [(order: Int, row: HouseRoomRow)] = []
        for (index, record) in active.enumerated() {
            let title = roomTitle(record, index: index)
            let aligned = userAligned.contains(record.id)
            let status = status(for: record, placement: report.placement(for: record.id), userAligned: aligned)
            let text = statusText(status, title: title)
            let row = HouseRoomRow(id: record.id, title: title, statusText: text, status: status,
                                   floorIndex: record.floorIndex,
                                   floorTitle: floorTitle(record.floorIndex, floors: manifest.floors),
                                   accessibility: accessibilityText(status, title: title, statusText: text))
            numbered.append((order: index, row: row))
        }
        numbered.sort { lhs, rhs in
            lhs.row.floorIndex != rhs.row.floorIndex ? lhs.row.floorIndex < rhs.row.floorIndex : lhs.order < rhs.order
        }
        return numbered.map { $0.row }
    }

    /// `.needsScan` for `.needsRescan` or `.failed`; `.needsLineUp` when the placement report
    /// asks for manual alignment and the room has no user alignment; `.notProcessed` while the
    /// room is `.capturing`; else `.done`.
    static func status(for record: RoomRecord, placement: RoomPlacementReport?, userAligned: Bool) -> HouseRoomStatus {
        switch record.status {
        case .needsRescan, .failed:
            return .needsScan
        case .capturing, .captured, .processed:
            break
        }
        if let placement, placement.needsManualAlignment, !userAligned { return .needsLineUp }
        if record.status == .capturing { return .notProcessed }
        return .done
    }

    /// "3 of 4 rooms done" (`Copy.House.progressSummary`), counting `.done` rows.
    static func progressText(_ rows: [HouseRoomRow]) -> String {
        let done = rows.filter { $0.status == .done }.count
        return Copy.House.progressSummary(done: done, total: rows.count)
    }

    /// True under `lowMemoryBytes` (D17 "finish this floor").
    static func suggestsFinishFloor(availableMemory: UInt64) -> Bool {
        availableMemory < lowMemoryBytes
    }

    /// The Show Missing Areas rule (D19), the same as ScanUI's `ScanCoverageRules.canOfferMissingAreas`
    /// (3.43a, wave 5c, which HouseUI cannot import): false in Demo Mode, when `engineState` is not
    /// `.finished`, after a system stop, or with no missing area.
    static func canOfferMissingAreas(isDemo: Bool, engineState: ScanEngineState?, stoppedBySystem: Bool,
                                     missingAreas: Int) -> Bool {
        guard !isDemo, !stoppedBySystem, missingAreas > 0 else { return false }
        return engineState == .finished
    }

    /// The error a blocking ScanUI preflight issue shows through `ScanErrorCopy.alert(for:)`:
    /// cameraDenied -> `.cameraDenied`, noLidar -> `.unsupportedDevice`, lowStorage(free) ->
    /// `.lowStorage(freeBytes: free)`; nil for cameraUndetermined (the permission phase answers
    /// it) and for warnings.
    static func preflightError(_ issue: PreflightIssue) -> MapperError? {
        switch issue {
        case .cameraDenied: return .cameraDenied
        case .noLidar: return .unsupportedDevice
        case .lowStorage(let free): return .lowStorage(freeBytes: free)
        case .cameraUndetermined, .storageWarning, .lowBattery, .deviceHot: return nil
        }
    }

    /// The detected section name first (FloorPlan `RoomTitles.sectionName`), then
    /// `Copy.House.roomSuggestions` without duplicates (case-insensitive).
    static func suggestedNames(sectionLabel: String?) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        var candidates: [String] = []
        if let label = sectionLabel, let name = RoomTitles.sectionName(label) { candidates.append(name) }
        candidates.append(contentsOf: Copy.House.roomSuggestions)
        for name in candidates {
            let key = name.lowercased()
            guard !name.isEmpty, seen.insert(key).inserted else { continue }
            result.append(name)
        }
        return result
    }

    /// User name, else "Room n" where n counts active rooms in capture order from 1.
    static func roomTitle(_ record: RoomRecord, index: Int) -> String {
        let trimmed = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Copy.FloorPlan.defaultRoomTitle(Swift.max(0, index) + 1) : trimmed
    }

    /// `FloorRecord.name` of the floor with id `index`, else "Floor n" (`index + 1`).
    static func floorTitle(_ index: Int, floors: [FloorRecord]) -> String {
        if let floor = floors.first(where: { $0.id == index }) {
            let trimmed = floor.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return Copy.House.floorLabel(Swift.max(0, index) + 1)
    }

    /// The visible status line of a row.
    static func statusText(_ status: HouseRoomStatus, title: String) -> String {
        switch status {
        case .done: return Copy.House.roomDone(title)
        case .needsScan: return Copy.House.roomNeedsScan(title)
        case .needsLineUp: return Copy.HouseUI.roomNeedsLineUp(title)
        case .notProcessed: return Copy.House.roomNotScanned(title)
        }
    }

    /// VoiceOver text of a row.
    static func accessibilityText(_ status: HouseRoomStatus, title: String, statusText: String) -> String {
        switch status {
        case .done: return Copy.A11y.roomDone(title)
        case .needsScan: return Copy.A11y.roomNeedsScan(title)
        case .needsLineUp, .notProcessed: return statusText
        }
    }

    /// Rows grouped by floor, in row order (the room list sections).
    static func floorSections(_ rows: [HouseRoomRow]) -> [HouseFloorSection] {
        var result: [HouseFloorSection] = []
        for row in rows {
            if let last = result.indices.last, result[last].id == row.floorIndex {
                result[last].rows.append(row)
            } else {
                result.append(HouseFloorSection(id: row.floorIndex, title: row.floorTitle, rows: [row]))
            }
        }
        return result
    }
}

/// Every manifest change of the house flow, as pure functions on values.
enum HouseManifestRules {
    /// A capture session reference (no world map file yet).
    static func session(id: UUID, startedAt: Date, link: FrameLink) -> CaptureSessionRef {
        CaptureSessionRef(id: id, startedAt: startedAt, frameLink: link, worldMapFile: nil)
    }

    /// The record for a finished room (status `.captured`, the session's frame link, never the
    /// engine's; name empty until named). The session id is the engine's (the folder the room was
    /// sealed in).
    static func roomRecord(_ result: RoomScanResult, sessionLink: FrameLink, floorIndex: Int) -> RoomRecord {
        let session = result.frameLink.sessionID ?? sessionLink.sessionID
            ?? sessionID(fromRoomFolder: result.sealedFolder.url) ?? result.roomID
        return RoomRecord(id: result.roomID, name: "", sessionID: session, floorIndex: floorIndex, status: .captured,
                          capturedRoomID: result.capturedRoomID, quality: nil, hasMeshPass: false,
                          keyframeCount: result.keyframeCount, capturedAt: result.capturedAt, frameLink: sessionLink)
    }

    /// The session id in `raw/sessions/<session>/rooms/<room>/`, nil for any other shape.
    static func sessionID(fromRoomFolder url: URL) -> UUID? {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= 4, parts[parts.count - 2] == "rooms", parts[parts.count - 4] == "sessions" else { return nil }
        return UUID(uuidString: parts[parts.count - 3])
    }

    /// Appends the record (replacing one with the same id) and sets the project status
    /// `.needsProcessing` in the same update.
    static func append(_ record: RoomRecord, to manifest: inout ProjectManifest) {
        manifest.rooms.removeAll { $0.id == record.id }
        manifest.rooms.append(record)
        manifest.status = .needsProcessing
    }

    /// Poor verdict (QualityVerdict.poor) gives `.needsRescan`, else `.captured`.
    static func status(after evaluation: QualityEvaluation) -> RoomStatus {
        evaluation.summary.verdict == .poor ? .needsRescan : .captured
    }

    /// Sets `old.supersededBy = new` (CR-7) and copies the old name (when the new record has
    /// none) and the old floor to the new record. Nothing is deleted.
    static func supersede(_ old: UUID, by new: UUID, in manifest: inout ProjectManifest) {
        guard old != new, let oldIndex = manifest.rooms.firstIndex(where: { $0.id == old }) else { return }
        manifest.rooms[oldIndex].supersededBy = new
        guard let newIndex = manifest.rooms.firstIndex(where: { $0.id == new }) else { return }
        let oldRecord = manifest.rooms[oldIndex]
        if manifest.rooms[newIndex].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            manifest.rooms[newIndex].name = oldRecord.name
        }
        manifest.rooms[newIndex].floorIndex = oldRecord.floorIndex
    }

    /// `CaptureSessionRef.worldMapFile` of `session` becomes the room's own map path.
    static func setWorldMap(session: UUID, room: UUID, in manifest: inout ProjectManifest) {
        guard let index = manifest.sessions.firstIndex(where: { $0.id == session }) else { return }
        manifest.sessions[index].worldMapFile = HouseRelocalization.worldMapPath(room: room)
    }

    /// Appends `FloorRecord(id: max + 1, name: "", elevation: 0)` and returns its id.
    static func addFloor(to manifest: inout ProjectManifest) -> Int {
        let next = (manifest.floors.map { $0.id }.max() ?? -1) + 1
        manifest.floors.append(FloorRecord(id: next, name: "", elevation: 0))
        return next
    }

    /// Sets a room's status (no change when the room is missing).
    static func setStatus(_ status: RoomStatus, room: UUID, in manifest: inout ProjectManifest) {
        guard let index = manifest.rooms.firstIndex(where: { $0.id == room }) else { return }
        manifest.rooms[index].status = status
    }

    /// Sets a room's user name (trimmed; an empty text keeps the default title).
    static func setName(_ text: String, room: UUID, in manifest: inout ProjectManifest) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = manifest.rooms.firstIndex(where: { $0.id == room }) else { return }
        manifest.rooms[index].name = String(trimmed.prefix(HousePresentation.maxRoomNameLength))
    }
}
