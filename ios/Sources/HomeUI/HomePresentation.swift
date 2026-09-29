import Foundation

/// Badge on a Home project row (UX_COPY section 1).
enum HomeBadge: Equatable, Sendable {
    /// A processing job runs or waits, or the project still has to be processed
    /// (`Copy.Home.processingBadge`, "Building model...").
    case processing
    /// A room or object needs another scan (`Copy.Home.needsWorkBadge`, "Needs another scan").
    case needsWork
}

/// Sort orders of the Home list, offered in the More menu (`Copy.Home.sortRecent`, `sortName`).
enum HomeSortOrder: String, CaseIterable, Sendable {
    /// Newest change first (the order `ProjectLibrary.projects` already has).
    case recent
    /// By name, A to Z, numbers in numeric order ("Room 2" before "Room 10").
    case name

    /// The menu title of this order.
    var title: String {
        switch self {
        case .recent: return Copy.Home.sortRecent
        case .name: return Copy.Home.sortName
        }
    }
}

/// One row of the mode picker (UX_COPY section 2).
struct HomeModeEntry: Equatable, Identifiable, Sendable {
    /// The mode passed to `onPick` when the row is tapped.
    let mode: ScanMode
    /// Row title, for example `Copy.Modes.room`.
    let title: String
    /// One-line description, for example `Copy.Modes.roomDetail`.
    let detail: String
    /// SF Symbol name of the row icon.
    let symbol: String
    /// False when this device or version cannot start the mode (AppShell decides; the row then
    /// shows `note`).
    let isEnabled: Bool
    /// Shown under a disabled mode: its reason, else `Copy.HomeUI.comingLater`; nil when enabled.
    let note: String?

    /// Creates an entry. `note` defaults to nil, so the build 4 form without a note still works.
    init(mode: ScanMode, title: String, detail: String, symbol: String, isEnabled: Bool, note: String? = nil) {
        self.mode = mode
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.isEnabled = isEnabled
        self.note = note
    }

    /// Stable identity for `ForEach`.
    var id: String { mode.rawValue }
}

/// Pure presentation rules of the Home screen: subtitles, badges, search, sorting, names, the
/// mode picker entries and VoiceOver text. Nonisolated and free of disk access, so
/// `HomeUISelfTest` checks it off the main actor.
enum HomePresentation {
    // MARK: - Contract (MODULES.md 3.28)

    /// Row subtitle by mode: "Room, Sep 28", "3 rooms, Sep 28" (House, with the count of
    /// `activeRooms`, so a room replaced by a Rescan is not counted twice), "Object, Sep 28",
    /// "Quick Measure, Sep 28". Advanced space scans read like a room (or a house when they hold
    /// several active rooms); advanced object scans read like an object.
    static func subtitle(for manifest: ProjectManifest, dateText: String) -> String {
        let roomCount = activeRooms(manifest).count
        switch manifest.kind {
        case .room:
            return Copy.Home.roomSubtitle(dateText)
        case .house:
            return houseSubtitle(rooms: roomCount, dateText: dateText)
        case .object, .advancedObject:
            return Copy.Home.objectSubtitle(dateText)
        case .quickMeasure:
            return Copy.Home.measureSubtitle(dateText)
        case .advancedSpace:
            return roomCount > 1 ? houseSubtitle(rooms: roomCount, dateText: dateText) : Copy.Home.roomSubtitle(dateText)
        }
    }

    /// `.processing` while the runner holds a running or waiting job for the project, or while
    /// the manifest says it still needs processing (resumed after launch); otherwise
    /// `.needsWork` when an active room (`activeRooms`, CR-7) or an object is `.needsRescan`;
    /// otherwise nil. A superseded room never raises the badge: its Rescan replaced it.
    /// Processing wins because the quality of a room is only final once its job ends.
    static func badge(for manifest: ProjectManifest, processing: ProjectProcessingState?) -> HomeBadge? {
        if let state = processing, state.isRunning || state.isQueued {
            return .processing
        }
        if manifest.status == .processing || manifest.status == .needsProcessing {
            return .processing
        }
        let roomNeedsScan = activeRooms(manifest).contains { $0.status == .needsRescan }
        let objectNeedsScan = manifest.objects.contains { $0.status == .needsRescan }
        if roomNeedsScan || objectNeedsScan {
            return .needsWork
        }
        return nil
    }

    /// Drops `.capturing` projects (a scan in progress or awaiting launch recovery; they never open
    /// Results) and archived ones unless `showArchived`; case-insensitive name search.
    /// The query is trimmed; an empty query keeps every remaining project. The input order is
    /// kept.
    static func filtered(_ projects: [ProjectManifest], query: String, showArchived: Bool) -> [ProjectManifest] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return projects.filter { manifest in
            guard manifest.status != .capturing else { return false }
            guard showArchived || !manifest.isArchived else { return false }
            return needle.isEmpty || nameMatches(manifest.name, needle: needle)
        }
    }

    // MARK: - Search and sort

    /// True when `name` contains `needle`, ignoring case and accents. Locale independent.
    static func nameMatches(_ name: String, needle: String) -> Bool {
        name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// The projects in `order`. Ties are broken by newest change, then by id, so the order is
    /// stable across reloads.
    static func sorted(_ projects: [ProjectManifest], by order: HomeSortOrder) -> [ProjectManifest] {
        switch order {
        case .recent:
            return projects.sorted { newerFirst($0, $1) }
        case .name:
            return projects.sorted { lhs, rhs in
                let result = compareNames(lhs.name, rhs.name)
                if result != .orderedSame { return result == .orderedAscending }
                return newerFirst(lhs, rhs)
            }
        }
    }

    /// Name order used by `sorted(_:by: .name)`: case and accent insensitive, numbers compared
    /// by value, locale independent.
    static func compareNames(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive, .numeric], range: nil, locale: nil)
    }

    /// Newest `modifiedAt` first, then by id text.
    private static func newerFirst(_ lhs: ProjectManifest, _ rhs: ProjectManifest) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    // MARK: - Rows

    /// Only projects past capture open Results (never a `.capturing` one).
    static func canOpen(_ manifest: ProjectManifest) -> Bool {
        manifest.status != .capturing
    }

    /// The name shown on the row. An empty or blank stored name falls back to the default name
    /// of its mode ("Room Sep 28").
    static func displayName(for manifest: ProjectManifest, dateText: String) -> String {
        let trimmed = manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return manifest.name }
        switch manifest.kind {
        case .room, .advancedSpace:
            return Copy.Home.defaultRoomName(dateText)
        case .house:
            return Copy.Home.defaultHouseName(dateText)
        case .object, .advancedObject:
            return Copy.Home.defaultObjectName(dateText)
        case .quickMeasure:
            return Copy.Home.defaultMeasureName(dateText)
        }
    }

    /// The spoken type of a project for `Copy.A11y.projectRow`: the mode picker's label.
    static func typeText(for mode: ScanMode) -> String {
        switch mode {
        case .room: return Copy.Modes.room
        case .house: return Copy.Modes.house
        case .object: return Copy.Modes.object
        case .quickMeasure: return Copy.Modes.quickMeasure
        case .advancedSpace, .advancedObject: return Copy.Modes.advanced
        }
    }

    /// SF Symbol shown for a mode (thumbnail placeholder and mode picker icon).
    static func symbol(for mode: ScanMode) -> String {
        switch mode {
        case .room: return "square.split.bottomrightquarter"
        case .house: return "house"
        case .object: return "cube"
        case .quickMeasure: return "ruler"
        case .advancedSpace, .advancedObject: return "slider.horizontal.3"
        }
    }

    /// The badge text shown on the row.
    static func badgeText(_ badge: HomeBadge) -> String {
        switch badge {
        case .processing: return Copy.Home.processingBadge
        case .needsWork: return Copy.Home.needsWorkBadge
        }
    }

    /// VoiceOver label of a row: "{name}, needs another scan" when the badge is `.needsWork`,
    /// else "{name}, {type}, {date}" (UX_COPY section 19).
    static func accessibilityLabel(for manifest: ProjectManifest, dateText: String, badge: HomeBadge?) -> String {
        let name = displayName(for: manifest, dateText: dateText)
        if badge == .needsWork {
            return Copy.A11y.projectNeedsWork(name)
        }
        return Copy.A11y.projectRow(name: name, type: typeText(for: manifest.kind), date: dateText)
    }

    /// VoiceOver value read after the label: the subtitle for a needs-work row (its label has no
    /// type or date), the badge text while processing, else empty.
    static func accessibilityValue(for manifest: ProjectManifest, dateText: String, badge: HomeBadge?) -> String {
        switch badge {
        case .needsWork?: return subtitle(for: manifest, dateText: dateText)
        case .processing?: return Copy.Home.processingBadge
        case nil: return ""
        }
    }

    /// The House subtitle with a singular form for one room.
    private static func houseSubtitle(rooms: Int, dateText: String) -> String {
        rooms == 1 ? Copy.HomeUI.houseOneRoomSubtitle(dateText) : Copy.Home.houseSubtitle(rooms: rooms, date: dateText)
    }

    // MARK: - Rename and delete

    /// The name a rename will store: `text` without surrounding spaces, or nil when nothing is
    /// left (`ProjectLibrary.rename` then leaves the project unchanged; it also caps the length).
    static func proposedName(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// True while the project's job is still running after `ProcessingRunner.cancel(projectID:)`:
    /// Home keeps the row disabled and deletes only once the job has ended, so no step writes
    /// into a deleted package. A waiting job is removed by `cancel` at once.
    static func mustWaitBeforeDelete(_ state: ProjectProcessingState?) -> Bool {
        state?.isRunning ?? false
    }

    // MARK: - Dates

    /// "Sep 28" for a date in the year of `now`, "Sep 28, 2025" otherwise, in the order and
    /// month names of `locale`. The formatters are cached per locale, time zone and pattern.
    static func dateText(_ date: Date, now: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let template = sameYear ? "MMMd" : "yMMMd"
        let formatter = HomeDateFormatCache.shared.formatter(template: template, locale: locale, timeZone: timeZone)
        return formatter.string(from: date)
    }

    // MARK: - Rooms

    /// Rooms that count for a project: CR-7 `supersededBy == nil` (a room replaced by a Rescan
    /// keeps its record but no longer counts). Manifest order. Status is not filtered, so the
    /// count matches what the build 4 subtitle showed for projects without a Rescan.
    static func activeRooms(_ manifest: ProjectManifest) -> [RoomRecord] {
        manifest.rooms.filter { $0.supersededBy == nil }
    }
}

// MARK: - Mode picker

extension HomePresentation {
    /// The five picker rows in UX_COPY order: Room, House / Building, Object, Quick Measure,
    /// Advanced Scan. A row is enabled when its mode is in `availableModes` (AppShell decides;
    /// build 5 enables House, Object and Quick Measure on capable devices). A disabled row's
    /// `note` is its reason from `unavailableReasons` (for example
    /// `Copy.Errors.objectUnsupported.title`), else `Copy.HomeUI.comingLater`; an enabled row
    /// has no note even when a reason is passed. The Advanced row picks `.advancedSpace`, or
    /// `.advancedObject` when only that one is available, and takes the reason of either.
    static func modeEntries(availableModes: Set<ScanMode>, unavailableReasons: [ScanMode: String]) -> [HomeModeEntry] {
        let onlyAdvancedObject = availableModes.contains(.advancedObject) && !availableModes.contains(.advancedSpace)
        let advancedMode: ScanMode = onlyAdvancedObject ? .advancedObject : .advancedSpace
        let otherAdvanced: ScanMode = onlyAdvancedObject ? .advancedSpace : .advancedObject
        let advancedEnabled = availableModes.contains(.advancedSpace) || availableModes.contains(.advancedObject)
        let plainModes: [ScanMode] = [.room, .house, .object, .quickMeasure]
        var entries: [HomeModeEntry] = plainModes.map { mode in
            let enabled = availableModes.contains(mode)
            let note = modeNote(isEnabled: enabled, reasons: [unavailableReasons[mode]])
            return HomeModeEntry(mode: mode, title: typeText(for: mode), detail: modeDetail(for: mode),
                                 symbol: symbol(for: mode), isEnabled: enabled, note: note)
        }
        let advancedReasons: [String?] = [unavailableReasons[advancedMode], unavailableReasons[otherAdvanced]]
        let advancedNote = modeNote(isEnabled: advancedEnabled, reasons: advancedReasons)
        entries.append(HomeModeEntry(mode: advancedMode, title: Copy.Modes.advanced, detail: Copy.Modes.advancedDetail,
                                     symbol: symbol(for: advancedMode), isEnabled: advancedEnabled, note: advancedNote))
        return entries
    }

    /// The build 4 form keeps working: `unavailableReasons` empty, so every disabled row reads
    /// `Copy.HomeUI.comingLater`.
    static func modeEntries(availableModes: Set<ScanMode>) -> [HomeModeEntry] {
        modeEntries(availableModes: availableModes, unavailableReasons: [:])
    }

    /// The note under a picker row: nil when enabled; else the first reason that is not blank
    /// (trimmed); else `Copy.HomeUI.comingLater`.
    static func modeNote(isEnabled: Bool, reasons: [String?]) -> String? {
        guard !isEnabled else { return nil }
        for case let reason? in reasons {
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return Copy.HomeUI.comingLater
    }

    /// VoiceOver value of a picker row: its `note` (the reason a disabled mode cannot start),
    /// empty for an enabled row.
    static func modeAccessibilityValue(_ entry: HomeModeEntry) -> String {
        entry.note ?? ""
    }

    /// One-line description of a mode in the picker (UX_COPY section 2).
    static func modeDetail(for mode: ScanMode) -> String {
        switch mode {
        case .room: return Copy.Modes.roomDetail
        case .house: return Copy.Modes.houseDetail
        case .object: return Copy.Modes.objectDetail
        case .quickMeasure: return Copy.Modes.quickMeasureDetail
        case .advancedSpace, .advancedObject: return Copy.Modes.advancedDetail
        }
    }
}

/// Thread-safe cache of the date formatters behind `HomePresentation.dateText`, keyed by
/// locale, time zone and template. Formatting with a shared `DateFormatter` is thread safe;
/// only creation is guarded by the lock.
final class HomeDateFormatCache: @unchecked Sendable {
    /// The app-wide cache.
    static let shared = HomeDateFormatCache()

    /// Guards `formatters`.
    private let lock = NSLock()
    /// Formatters by "locale|timeZone|template".
    private var formatters: [String: DateFormatter] = [:]

    /// A formatter for `template` localized to `locale`, in `timeZone`.
    func formatter(template: String, locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let key = locale.identifier + "|" + timeZone.identifier + "|" + template
        lock.lock()
        defer { lock.unlock() }
        if let cached = formatters[key] { return cached }
        let created = DateFormatter()
        created.locale = locale
        created.timeZone = timeZone
        created.setLocalizedDateFormatFromTemplate(template)
        formatters[key] = created
        return created
    }
}
