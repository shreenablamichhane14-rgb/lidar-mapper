import Foundation
import CoreGraphics

/// Plain-Swift checks for HomeUI (no XCTest), run from the Diagnostics suite list off the main
/// actor. Pure and deterministic: fixed ids, dates, locale and time zone; no files, no clock,
/// no ARKit, camera or network. Covers `HomePresentation` (subtitles, badges, search, archive
/// and `.capturing` filtering, rename effects, sorting, names, VoiceOver text, dates, mode
/// picker entries, the delete wait rule) and the thumbnail size rule.
enum HomeUISelfTest {
    /// Failing checks as "name: detail"; empty when all pass.
    static func run() -> [String] {
        var failures: [String] = []
        subtitleChecks(&failures)
        badgeChecks(&failures)
        filterChecks(&failures)
        renameAndSortChecks(&failures)
        rowChecks(&failures)
        dateChecks(&failures)
        modePickerChecks(&failures)
        miscChecks(&failures)
        return failures
    }

    // MARK: Fixtures

    /// 2026-09-28 12:00 UTC.
    private static let sep28 = Date(timeIntervalSince1970: 1_790_596_800)
    /// 2025-09-28 12:00 UTC.
    private static let sep28LastYear = Date(timeIntervalSince1970: 1_759_060_800)
    /// Date text used by the row checks.
    private static let day = "Sep 28"
    /// Fixed locale for date checks.
    private static let english = Locale(identifier: "en_US")

    /// Records a failure when `ok` is false.
    private static func check(_ failures: inout [String], _ name: String, _ ok: Bool, _ detail: @autoclosure () -> String) {
        if !ok { failures.append("\(name): \(detail())") }
    }

    /// A fixed UUID ending in `low` (and `high` before it).
    private static func uuid(_ low: UInt8, high: UInt8 = 0) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, high, low))
    }

    /// A room record with a fixed id and the given status.
    private static func room(_ index: UInt8, _ status: RoomStatus) -> RoomRecord {
        RoomRecord(id: uuid(index, high: 1), name: "", sessionID: uuid(1, high: 2), floorIndex: 0, status: status,
                   capturedRoomID: nil, quality: nil, hasMeshPass: false, keyframeCount: 0, capturedAt: sep28,
                   frameLink: .unaligned)
    }

    /// A manifest with fixed id and dates; `modified` is seconds after `sep28`.
    private static func project(_ index: UInt8, _ name: String, kind: ScanMode = .room, status: ProjectStatus = .ready,
                                archived: Bool = false, modified: Double = 0, rooms: [RoomStatus] = []) -> ProjectManifest {
        var records: [RoomRecord] = []
        for (offset, roomStatus) in rooms.enumerated() {
            records.append(room(UInt8(offset + 1), roomStatus))
        }
        return ProjectManifest(schemaVersion: ProjectManifest.currentSchema, id: uuid(index), name: name, kind: kind,
                               createdAt: sep28, modifiedAt: sep28.addingTimeInterval(modified), isArchived: archived,
                               pipelineVersion: ProjectManifest.currentPipelineVersion, sessions: [], rooms: records,
                               objects: [], floors: [FloorRecord(id: 0, name: "", elevation: 0)], status: status,
                               reconstructionPending: false, settings: ScanSettings.defaults(for: kind))
    }

    /// Names of a list, for failure details.
    private static func names(_ list: [ProjectManifest]) -> [String] {
        list.map { $0.name }
    }

    // MARK: Subtitles

    /// One subtitle per mode, the House room count and its singular form.
    private static func subtitleChecks(_ failures: inout [String]) {
        let roomText = HomePresentation.subtitle(for: project(1, "A", kind: .room, rooms: [.processed]), dateText: day)
        check(&failures, "subtitle.room", roomText == "Room, Sep 28", "got \(roomText)")

        let house = project(2, "B", kind: .house, rooms: [.processed, .processed, .captured])
        let houseText = HomePresentation.subtitle(for: house, dateText: day)
        check(&failures, "subtitle.house.count", houseText == "3 rooms, Sep 28", "got \(houseText)")

        let oneRoom = HomePresentation.subtitle(for: project(3, "C", kind: .house, rooms: [.processed]), dateText: day)
        check(&failures, "subtitle.house.oneRoom", oneRoom == "1 room, Sep 28", "got \(oneRoom)")

        let objectText = HomePresentation.subtitle(for: project(4, "D", kind: .object), dateText: day)
        check(&failures, "subtitle.object", objectText == "Object, Sep 28", "got \(objectText)")

        let measureText = HomePresentation.subtitle(for: project(5, "E", kind: .quickMeasure), dateText: day)
        check(&failures, "subtitle.quickMeasure", measureText == "Quick Measure, Sep 28", "got \(measureText)")

        let advancedObject = HomePresentation.subtitle(for: project(6, "F", kind: .advancedObject), dateText: day)
        check(&failures, "subtitle.advancedObject", advancedObject == Copy.Home.objectSubtitle(day), "got \(advancedObject)")

        let spaceOne = HomePresentation.subtitle(for: project(7, "G", kind: .advancedSpace, rooms: [.processed]), dateText: day)
        check(&failures, "subtitle.advancedSpace.one", spaceOne == Copy.Home.roomSubtitle(day), "got \(spaceOne)")
        let spaceTwo = HomePresentation.subtitle(for: project(8, "H", kind: .advancedSpace, rooms: [.processed, .processed]),
                                                 dateText: day)
        check(&failures, "subtitle.advancedSpace.two", spaceTwo == Copy.Home.houseSubtitle(rooms: 2, date: day), "got \(spaceTwo)")
    }

    // MARK: Badges

    /// Processing from the runner or the status, needs-work from a room or object, nothing
    /// otherwise, processing first.
    private static func badgeChecks(_ failures: inout [String]) {
        var running = ProjectProcessingState()
        running.isRunning = true
        var queued = ProjectProcessingState()
        queued.isQueued = true
        let idle = ProjectProcessingState()
        let ready = project(10, "Ready", rooms: [.processed])

        let whileRunning = HomePresentation.badge(for: ready, processing: running)
        check(&failures, "badge.processing.running", whileRunning == .processing, "got \(String(describing: whileRunning))")
        let whileQueued = HomePresentation.badge(for: ready, processing: queued)
        check(&failures, "badge.processing.queued", whileQueued == .processing, "got \(String(describing: whileQueued))")

        let statusProcessing = HomePresentation.badge(for: project(11, "P", status: .processing, rooms: [.captured]), processing: nil)
        check(&failures, "badge.processing.status", statusProcessing == .processing, "got \(String(describing: statusProcessing))")
        let statusPending = HomePresentation.badge(for: project(12, "Q", status: .needsProcessing, rooms: [.captured]), processing: idle)
        check(&failures, "badge.processing.needsProcessing", statusPending == .processing, "got \(String(describing: statusPending))")

        let rescan = project(13, "R", rooms: [.processed, .needsRescan])
        let needsWork = HomePresentation.badge(for: rescan, processing: idle)
        check(&failures, "badge.needsWork.room", needsWork == .needsWork, "got \(String(describing: needsWork))")

        var objectProject = project(14, "S", kind: .object)
        objectProject.objects = [ObjectRecord(id: uuid(1, high: 3), name: "", size: .smallMedium, status: .needsRescan,
                                              imageCount: 0, modelFile: nil)]
        let objectWork = HomePresentation.badge(for: objectProject, processing: nil)
        check(&failures, "badge.needsWork.object", objectWork == .needsWork, "got \(String(describing: objectWork))")

        let none = HomePresentation.badge(for: ready, processing: idle)
        check(&failures, "badge.none.ready", none == nil, "got \(String(describing: none))")
        let attention = HomePresentation.badge(for: project(15, "T", status: .needsAttention, rooms: [.failed]), processing: nil)
        check(&failures, "badge.none.needsAttention", attention == nil, "got \(String(describing: attention))")

        let both = HomePresentation.badge(for: rescan, processing: running)
        check(&failures, "badge.processingWins", both == .processing, "got \(String(describing: both))")
    }

    // MARK: Search and filtering

    /// Case and accent insensitive search, trimmed query, archive toggle, `.capturing` hidden.
    private static func filterChecks(_ failures: inout [String]) {
        let kitchen = project(20, "Kitchen", modified: 30)
        let garage = project(21, "Garage", modified: 20)
        let cafe = project(22, "Caf\u{00E9} Corner", modified: 10)
        let archived = project(23, "Kitchen Archive", archived: true, modified: 5)
        let capturing = project(24, "Kitchen Live", status: .capturing, modified: 40)
        let all = [capturing, kitchen, garage, cafe, archived]

        let upper = HomePresentation.filtered(all, query: "kITCHen", showArchived: false)
        check(&failures, "filter.caseInsensitive", upper.map { $0.id } == [kitchen.id], "got \(names(upper))")

        let accent = HomePresentation.filtered(all, query: "cafe", showArchived: false)
        check(&failures, "filter.accentInsensitive", accent.map { $0.id } == [cafe.id], "got \(names(accent))")

        let trimmed = HomePresentation.filtered(all, query: "  garage \n", showArchived: false)
        check(&failures, "filter.trimmedQuery", trimmed.map { $0.id } == [garage.id], "got \(names(trimmed))")

        let everything = HomePresentation.filtered(all, query: "", showArchived: false)
        check(&failures, "filter.emptyQuery.keepsOrder", everything.map { $0.id } == [kitchen.id, garage.id, cafe.id],
              "got \(names(everything))")

        let hidden = HomePresentation.filtered(all, query: "kitchen", showArchived: false)
        check(&failures, "filter.hidesArchived", !hidden.contains { $0.id == archived.id }, "got \(names(hidden))")
        let shown = HomePresentation.filtered(all, query: "kitchen", showArchived: true)
        check(&failures, "filter.showsArchived", shown.map { $0.id } == [kitchen.id, archived.id], "got \(names(shown))")

        let withArchive = HomePresentation.filtered(all, query: "", showArchived: true)
        check(&failures, "filter.dropsCapturing", !withArchive.contains { $0.id == capturing.id }, "got \(names(withArchive))")
        let live = HomePresentation.filtered(all, query: "live", showArchived: true)
        check(&failures, "filter.dropsCapturing.search", live.isEmpty, "got \(names(live))")

        let noMatch = HomePresentation.filtered(all, query: "attic", showArchived: true)
        check(&failures, "filter.noMatch", noMatch.isEmpty, "got \(names(noMatch))")
    }

    // MARK: Rename and sort

    /// The rename text rule, then a renamed project sorts and searches by its new name; name
    /// order is numeric and case insensitive; recent order is newest first.
    private static func renameAndSortChecks(_ failures: inout [String]) {
        let proposed = HomePresentation.proposedName("  Bombay Bar & Grill \n")
        check(&failures, "rename.proposed.trims", proposed == "Bombay Bar & Grill", "got \(String(describing: proposed))")
        let blank = HomePresentation.proposedName("   \n ")
        check(&failures, "rename.proposed.blank", blank == nil, "got \(String(describing: blank))")

        let alpha = project(30, "Bravo", modified: 10)
        var charlie = project(31, "Charlie", modified: 20)
        let delta = project(32, "Delta", modified: 30)
        charlie.name = HomePresentation.proposedName(" Aardvark ") ?? charlie.name
        let list = [delta, charlie, alpha]

        let byName = HomePresentation.sorted(list, by: .name)
        check(&failures, "rename.sortsByNewName", byName.map { $0.id } == [charlie.id, alpha.id, delta.id], "got \(names(byName))")
        let newHits = HomePresentation.filtered(list, query: "AARD", showArchived: false)
        check(&failures, "rename.searchesNewName", newHits.map { $0.id } == [charlie.id], "got \(names(newHits))")
        let oldHits = HomePresentation.filtered(list, query: "charlie", showArchived: false)
        check(&failures, "rename.oldNameGone", oldHits.isEmpty, "got \(names(oldHits))")

        let recent = HomePresentation.sorted([alpha, delta, charlie], by: .recent)
        check(&failures, "sort.recent", recent.map { $0.id } == [delta.id, charlie.id, alpha.id], "got \(names(recent))")

        let room10 = project(33, "Room 10", modified: 1)
        let room2 = project(34, "Room 2", modified: 2)
        let numeric = HomePresentation.sorted([room10, room2], by: .name)
        check(&failures, "sort.name.numeric", numeric.map { $0.id } == [room2.id, room10.id], "got \(names(numeric))")

        let lower = project(35, "apple", modified: 1)
        let upper = project(36, "Banana", modified: 2)
        let cased = HomePresentation.sorted([upper, lower], by: .name)
        check(&failures, "sort.name.caseInsensitive", cased.map { $0.id } == [lower.id, upper.id], "got \(names(cased))")

        let older = project(37, "Room Sep 28", modified: 1)
        let newer = project(38, "Room Sep 28", modified: 2)
        let ties = HomePresentation.sorted([older, newer], by: .name)
        check(&failures, "sort.name.tieNewestFirst", ties.map { $0.id } == [newer.id, older.id], "got \(ties.map { $0.id })")
    }

    // MARK: Rows

    /// Opening, delete waiting, display names and VoiceOver text.
    private static func rowChecks(_ failures: inout [String]) {
        check(&failures, "open.capturing", !HomePresentation.canOpen(project(40, "X", status: .capturing)), "capturing opens")
        check(&failures, "open.ready", HomePresentation.canOpen(project(41, "Y")), "ready does not open")
        check(&failures, "open.needsProcessing", HomePresentation.canOpen(project(42, "Z", status: .needsProcessing)),
              "needsProcessing does not open")

        var running = ProjectProcessingState()
        running.isRunning = true
        var queued = ProjectProcessingState()
        queued.isQueued = true
        check(&failures, "delete.waitsWhileRunning", HomePresentation.mustWaitBeforeDelete(running), "does not wait")
        check(&failures, "delete.queuedDoesNotWait", !HomePresentation.mustWaitBeforeDelete(queued), "waits")
        check(&failures, "delete.idleDoesNotWait", !HomePresentation.mustWaitBeforeDelete(nil), "waits")

        let unnamed = HomePresentation.displayName(for: project(43, "  ", kind: .room), dateText: day)
        check(&failures, "name.defaultRoom", unnamed == Copy.Home.defaultRoomName(day), "got \(unnamed)")
        let unnamedHouse = HomePresentation.displayName(for: project(44, "", kind: .house), dateText: day)
        check(&failures, "name.defaultHouse", unnamedHouse == Copy.Home.defaultHouseName(day), "got \(unnamedHouse)")
        let named = HomePresentation.displayName(for: project(45, "Kitchen"), dateText: day)
        check(&failures, "name.kept", named == "Kitchen", "got \(named)")

        let kitchen = project(46, "Kitchen", rooms: [.processed])
        let label = HomePresentation.accessibilityLabel(for: kitchen, dateText: day, badge: nil)
        check(&failures, "a11y.row", label == "Kitchen, Room, Sep 28", "got \(label)")
        let workLabel = HomePresentation.accessibilityLabel(for: kitchen, dateText: day, badge: .needsWork)
        check(&failures, "a11y.needsWork", workLabel == "Kitchen, needs another scan", "got \(workLabel)")
        let workValue = HomePresentation.accessibilityValue(for: kitchen, dateText: day, badge: .needsWork)
        check(&failures, "a11y.value.needsWork", workValue == "Room, Sep 28", "got \(workValue)")
        let busyValue = HomePresentation.accessibilityValue(for: kitchen, dateText: day, badge: .processing)
        check(&failures, "a11y.value.processing", busyValue == Copy.Home.processingBadge, "got \(busyValue)")
        let plainValue = HomePresentation.accessibilityValue(for: kitchen, dateText: day, badge: nil)
        check(&failures, "a11y.value.none", plainValue.isEmpty, "got \(plainValue)")
        let houseType = HomePresentation.typeText(for: .house)
        check(&failures, "a11y.type.house", houseType == Copy.Modes.house, "got \(houseType)")
    }

    // MARK: Dates

    /// "Sep 28" within the year, the year added otherwise, the time zone respected, formatters
    /// cached.
    private static func dateChecks(_ failures: inout [String]) {
        let gmt = TimeZone.gmt
        let sameYear = HomePresentation.dateText(sep28, now: sep28.addingTimeInterval(86_400), locale: english, timeZone: gmt)
        let sameOK = sameYear.contains("Sep") && sameYear.contains("28") && !sameYear.contains("2026")
        check(&failures, "date.sameYear", sameOK, "got \(sameYear)")

        let lastYear = HomePresentation.dateText(sep28LastYear, now: sep28, locale: english, timeZone: gmt)
        let lastOK = lastYear.contains("Sep") && lastYear.contains("28") && lastYear.contains("2025")
        check(&failures, "date.otherYear", lastOK, "got \(lastYear)")

        let lateEvening = sep28.addingTimeInterval(11.5 * 3600)
        let inGMT = HomePresentation.dateText(lateEvening, now: sep28, locale: english, timeZone: gmt)
        check(&failures, "date.timeZone.gmt", inGMT.contains("28"), "got \(inGMT)")
        if let tokyo = TimeZone(identifier: "Asia/Tokyo") {
            let inTokyo = HomePresentation.dateText(lateEvening, now: sep28, locale: english, timeZone: tokyo)
            check(&failures, "date.timeZone.tokyo", inTokyo.contains("29"), "got \(inTokyo)")
        } else {
            check(&failures, "date.timeZone.tokyo", false, "Asia/Tokyo time zone missing")
        }

        let first = HomeDateFormatCache.shared.formatter(template: "MMMd", locale: english, timeZone: gmt)
        let second = HomeDateFormatCache.shared.formatter(template: "MMMd", locale: english, timeZone: gmt)
        check(&failures, "date.formatterCached", first === second, "a new formatter per call")
    }

    // MARK: Mode picker

    /// Five entries in UX_COPY order; build 4 enables Room only; Advanced follows its modes.
    private static func modePickerChecks(_ failures: inout [String]) {
        let build4 = HomePresentation.modeEntries(availableModes: [.room])
        let order: [ScanMode] = [.room, .house, .object, .quickMeasure, .advancedSpace]
        check(&failures, "modes.order", build4.map { $0.mode } == order, "got \(build4.map { $0.mode.rawValue })")
        let enabled = build4.filter { $0.isEnabled }.map { $0.mode }
        check(&failures, "modes.build4.roomOnly", enabled == [.room], "enabled \(enabled.map { $0.rawValue })")
        let titles: [String] = [Copy.Modes.room, Copy.Modes.house, Copy.Modes.object, Copy.Modes.quickMeasure, Copy.Modes.advanced]
        check(&failures, "modes.titles", build4.map { $0.title } == titles, "got \(build4.map { $0.title })")
        let details: [String] = [Copy.Modes.roomDetail, Copy.Modes.houseDetail, Copy.Modes.objectDetail,
                                 Copy.Modes.quickMeasureDetail, Copy.Modes.advancedDetail]
        check(&failures, "modes.details", build4.map { $0.detail } == details, "details differ")
        let ids = Set(build4.map { $0.id })
        check(&failures, "modes.uniqueIDs", ids.count == build4.count, "duplicate ids")

        let objectOnly = HomePresentation.modeEntries(availableModes: [.advancedObject])
        let advanced = objectOnly.last
        let advancedOK = advanced?.mode == .advancedObject && advanced?.isEnabled == true
        check(&failures, "modes.advancedObjectOnly", advancedOK, "got \(String(describing: advanced))")

        let none = HomePresentation.modeEntries(availableModes: [])
        check(&failures, "modes.noneAvailable", none.allSatisfy { !$0.isEnabled }, "some enabled")
    }

    // MARK: Misc

    /// Copy strings of this module, badge and sort texts, and the thumbnail size rule.
    private static func miscChecks(_ failures: inout [String]) {
        check(&failures, "copy.comingLater", Copy.HomeUI.comingLater == "Coming in a later version", "got \(Copy.HomeUI.comingLater)")
        check(&failures, "copy.badges", HomePresentation.badgeText(.processing) == Copy.Home.processingBadge
              && HomePresentation.badgeText(.needsWork) == Copy.Home.needsWorkBadge, "badge texts differ")
        check(&failures, "copy.sortTitles", HomeSortOrder.recent.title == Copy.Home.sortRecent
              && HomeSortOrder.name.title == Copy.Home.sortName, "sort titles differ")

        let fitted = HomeThumbnailCache.fittedSize(CGSize(width: 1200, height: 900), maxPixels: 300)
        check(&failures, "thumbnail.fitted", fitted == CGSize(width: 300, height: 225), "got \(fitted)")
        let small = HomeThumbnailCache.fittedSize(CGSize(width: 100, height: 80), maxPixels: 300)
        check(&failures, "thumbnail.smallKept", small == CGSize(width: 100, height: 80), "got \(small)")
        let empty = HomeThumbnailCache.fittedSize(.zero, maxPixels: 300)
        check(&failures, "thumbnail.degenerate", empty == .zero, "got \(empty)")
    }
}
