import Foundation

/// Build 5 checks of HomeUI (MODULES.md 3.43c): House, Object and Quick Measure follow the set
/// AppShell passes; a disabled mode shows its reason, else "Coming in a later version"; an
/// enabled mode has no note; House and advanced space subtitles count only active rooms (CR-7
/// `supersededBy == nil`); a superseded room never raises the needs-work badge. Pure and
/// deterministic, like the build 4 checks; uses the fixtures of `HomeUISelfTest.swift`.
extension HomeUISelfTest {
    /// Runs every build 5 check, appending "name: detail" for each failure.
    static func build5Checks(_ failures: inout [String]) {
        modeEnableChecks(&failures)
        modeNoteChecks(&failures)
        activeRoomChecks(&failures)
    }

    // MARK: Fixtures

    /// A copy of `manifest` whose rooms at `indices` (zero based) were replaced by a Rescan.
    private static func superseding(_ manifest: ProjectManifest, rooms indices: [Int]) -> ProjectManifest {
        var copy = manifest
        for index in indices where index >= 0 && index < copy.rooms.count {
            copy.rooms[index].supersededBy = uuid(UInt8(index + 1), high: 9)
        }
        return copy
    }

    /// The picker entry of `mode`, nil when it is missing.
    private static func entry(_ mode: ScanMode, in entries: [HomeModeEntry]) -> HomeModeEntry? {
        entries.first { $0.mode == mode }
    }

    // MARK: Mode availability

    /// The build 5 set enables House, Object and Quick Measure; each follows the set; Advanced
    /// stays off; the one-argument form equals the form with no reasons.
    private static func modeEnableChecks(_ failures: inout [String]) {
        let build5: Set<ScanMode> = [.room, .house, .object, .quickMeasure]
        let entries = HomePresentation.modeEntries(availableModes: build5, unavailableReasons: [:])
        let order: [ScanMode] = [.room, .house, .object, .quickMeasure, .advancedSpace]
        check(&failures, "b5.modes.order", entries.map { $0.mode } == order, "got \(entries.map { $0.mode.rawValue })")

        let enabled = entries.filter { $0.isEnabled }.map { $0.mode }
        let expected: [ScanMode] = [.room, .house, .object, .quickMeasure]
        check(&failures, "b5.modes.houseObjectMeasureEnabled", enabled == expected,
              "enabled \(enabled.map { $0.rawValue })")

        let advancedOff: Bool = entry(.advancedSpace, in: entries)?.isEnabled == false
        check(&failures, "b5.modes.advancedOff", advancedOff, "advanced enabled or missing")

        let withoutObject = HomePresentation.modeEntries(availableModes: [.room, .house, .quickMeasure], unavailableReasons: [:])
        let objectOff: Bool = entry(.object, in: withoutObject)?.isEnabled == false
        let houseOn: Bool = entry(.house, in: withoutObject)?.isEnabled == true
        check(&failures, "b5.modes.followSet", objectOff && houseOn, "object or house does not follow the set")

        let oneArgument = HomePresentation.modeEntries(availableModes: build5)
        check(&failures, "b5.modes.build4Form", oneArgument == entries, "the one-argument form differs")
    }

    // MARK: Mode notes

    /// Reasons become notes on disabled rows only; a missing or blank reason reads "Coming in a
    /// later version"; the Advanced row takes the reason of either advanced mode; VoiceOver
    /// reads the note.
    private static func modeNoteChecks(_ failures: inout [String]) {
        let objectReason = Copy.Errors.objectUnsupported.title
        let lidarReason = Copy.Errors.noLidar.title
        let available: Set<ScanMode> = [.room, .house, .quickMeasure]
        let reasons: [ScanMode: String] = [.object: objectReason, .quickMeasure: lidarReason]
        let entries = HomePresentation.modeEntries(availableModes: available, unavailableReasons: reasons)

        let object = entry(.object, in: entries)
        let objectNote: String? = object?.note
        let objectDisabled: Bool = object?.isEnabled == false
        check(&failures, "b5.note.objectReason", objectDisabled && objectNote == objectReason,
              "got \(String(describing: objectNote))")

        let advancedNote: String? = entry(.advancedSpace, in: entries)?.note
        check(&failures, "b5.note.advancedComingLater", advancedNote == Copy.HomeUI.comingLater,
              "got \(String(describing: advancedNote))")

        let enabledNotes = entries.filter { $0.isEnabled }.compactMap { $0.note }
        check(&failures, "b5.note.enabledHasNone", enabledNotes.isEmpty, "got \(enabledNotes)")

        let measure = entry(.quickMeasure, in: entries)
        let measureEnabled: Bool = measure?.isEnabled == true
        let measureNote: String? = measure?.note
        let measureOK: Bool = measureEnabled && measureNote == nil
        check(&failures, "b5.note.enabledIgnoresReason", measureOK, "got \(String(describing: measure))")

        let blank = HomePresentation.modeEntries(availableModes: [.room], unavailableReasons: [.house: "  \n"])
        let blankNote: String? = entry(.house, in: blank)?.note
        check(&failures, "b5.note.blankReason", blankNote == Copy.HomeUI.comingLater, "got \(String(describing: blankNote))")

        let advancedObject = HomePresentation.modeEntries(availableModes: [.room],
                                                          unavailableReasons: [.advancedObject: lidarReason])
        let eitherNote: String? = entry(.advancedSpace, in: advancedObject)?.note
        check(&failures, "b5.note.advancedEitherReason", eitherNote == lidarReason, "got \(String(describing: eitherNote))")

        let build4 = HomePresentation.modeEntries(availableModes: [.room])
        let build4Notes: [String?] = build4.filter { !$0.isEnabled }.map { $0.note }
        let comingLater: String = Copy.HomeUI.comingLater
        let build4AllLater: Bool = build4Notes.allSatisfy { (note: String?) -> Bool in note == comingLater }
        let build4OK: Bool = build4Notes.count == 4 && build4AllLater
        check(&failures, "b5.note.build4ComingLater", build4OK, "got \(build4Notes)")

        let mixed: [String?] = [nil, "  ", "Second"]
        let firstUsable = HomePresentation.modeNote(isEnabled: false, reasons: mixed)
        check(&failures, "b5.note.firstUsableReason", firstUsable == "Second", "got \(String(describing: firstUsable))")

        let spokenReason: String = object.map { HomePresentation.modeAccessibilityValue($0) } ?? ""
        check(&failures, "b5.a11y.modeReason", spokenReason == objectReason, "got \(spokenReason)")
        let spokenEnabled: String = entry(.room, in: entries).map { HomePresentation.modeAccessibilityValue($0) } ?? "missing"
        check(&failures, "b5.a11y.modeEnabledEmpty", spokenEnabled.isEmpty, "got \(spokenEnabled)")
    }

    // MARK: Active rooms (CR-7)

    /// Superseded rooms are left out of the House and advanced space counts and out of the
    /// needs-work badge; Quick Measure subtitles are unchanged.
    private static func activeRoomChecks(_ failures: inout [String]) {
        let house = superseding(project(60, "House", kind: .house, rooms: [.processed, .processed, .captured]), rooms: [1])
        let activeIDs = HomePresentation.activeRooms(house).map { $0.id }
        let expectedIDs: [UUID] = [house.rooms[0].id, house.rooms[2].id]
        check(&failures, "b5.activeRooms.dropsSuperseded", activeIDs == expectedIDs, "got \(activeIDs)")

        let houseText = HomePresentation.subtitle(for: house, dateText: day)
        check(&failures, "b5.subtitle.house.superseded", houseText == "2 rooms, Sep 28", "got \(houseText)")

        let oneLeft = superseding(project(61, "House", kind: .house, rooms: [.processed, .processed]), rooms: [0])
        let oneLeftText = HomePresentation.subtitle(for: oneLeft, dateText: day)
        check(&failures, "b5.subtitle.house.oneActive", oneLeftText == "1 room, Sep 28", "got \(oneLeftText)")

        let space = superseding(project(62, "Space", kind: .advancedSpace, rooms: [.processed, .processed]), rooms: [1])
        let spaceText = HomePresentation.subtitle(for: space, dateText: day)
        check(&failures, "b5.subtitle.advancedSpace.superseded", spaceText == Copy.Home.roomSubtitle(day), "got \(spaceText)")

        let measure = superseding(project(63, "Measure", kind: .quickMeasure, rooms: [.processed]), rooms: [0])
        let measureText = HomePresentation.subtitle(for: measure, dateText: day)
        check(&failures, "b5.subtitle.quickMeasure.unchanged", measureText == Copy.Home.measureSubtitle(day),
              "got \(measureText)")

        let idle = ProjectProcessingState()
        let replaced = superseding(project(64, "Replaced", kind: .house, rooms: [.processed, .needsRescan]), rooms: [1])
        let replacedBadge = HomePresentation.badge(for: replaced, processing: idle)
        check(&failures, "b5.badge.supersededNeedsRescan", replacedBadge == nil, "got \(String(describing: replacedBadge))")

        let stillPoor = superseding(project(65, "Poor", kind: .house, rooms: [.needsRescan, .processed]), rooms: [1])
        let poorBadge = HomePresentation.badge(for: stillPoor, processing: idle)
        check(&failures, "b5.badge.activeNeedsRescan", poorBadge == .needsWork, "got \(String(describing: poorBadge))")

        let spoken = HomePresentation.accessibilityValue(for: stillPoor, dateText: day, badge: .needsWork)
        check(&failures, "b5.a11y.value.activeCount", spoken == "1 room, Sep 28", "got \(spoken)")
    }
}
