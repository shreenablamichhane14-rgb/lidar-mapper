import Foundation
import simd

/// What the inspector shows for the selection.
enum PlanEditorItem: Equatable {
    case wall(PlanWall)
    case opening(PlanOpening, wall: PlanWall)
    case room(PlanRoom)
    case fixture(PlanFixture)
    case annotation(PlanAnnotation)
    case dimension(PlanDimension)
}

/// Buttons of the inspector (for the selection) and of the add bar (nothing selected).
enum PlanEditorCommand: String, CaseIterable, Identifiable, Sendable {
    case wallLength, wallThickness, deleteWall, addDoor, addWindow, addOpening
    case resizeOpening, flipDoorSwing, deleteOpening
    case renameRoom, mergeRooms, splitRoom
    case turnFixture, changeCategory, deleteFixture
    case editAnnotation, deleteAnnotation, deleteMeasurement
    case addWall, addMeasurement, addText, addSymbol, addNote
    /// Identity for `ForEach`.
    var id: String { rawValue }
}

/// A sheet or alert the model asks the screen to show.
enum PlanEditorPrompt: Identifiable, Equatable {
    case wallLength(ElementID, current: Float)
    case wallThickness(ElementID, current: Float)
    case openingSize(ElementID, width: Float, height: Float?)
    case renameRoom(ElementID, current: String)
    /// Text, note or symbol at `at`; `editing` is the annotation being changed.
    case annotation(kind: AnnotationKind, at: Vec2, editing: ElementID?, current: String)
    case category(ElementID, current: ObjectCategory)
    case resetConfirmation

    /// Identity for `.sheet(item:)`: the prompt kind and its element (or point).
    var id: String {
        switch self {
        case .wallLength(let element, _): return "wallLength-" + element.uuid.uuidString
        case .wallThickness(let element, _): return "wallThickness-" + element.uuid.uuidString
        case .openingSize(let element, _, _): return "openingSize-" + element.uuid.uuidString
        case .renameRoom(let element, _): return "renameRoom-" + element.uuid.uuidString
        case .annotation(let kind, let at, let editing, _):
            let target = editing?.uuid.uuidString ?? "\(at.x),\(at.y)"
            return "annotation-" + kind.rawValue + "-" + target
        case .category(let element, _): return "category-" + element.uuid.uuidString
        case .resetConfirmation: return "resetConfirmation"
        }
    }
}

/// Texts of the plan editor (docs/MODULES.md 3.37): command titles, tool hints, refusals,
/// operation descriptions, item and level titles, symbols and typed lengths. Pure; every string
/// comes from `Copy`, every length through Units.
enum PlanEditorPresentation {
    /// Titles: Copy.FloorPlan (wallLength, wallThickness, addWall, deleteWall, addDoor, addWindow,
    /// addOpening, flipDoorSwing, renameRoom, mergeRooms, splitRoom, addMeasurement, deleteMeasurement,
    /// addText, addSymbol, addNote); resizeOpening reads Copy.FloorPlan.resizeDoor, resizeWindow or
    /// Copy.PlanEditor.resizeOpening by the selected opening's kind; Copy.PlanEditor.turn,
    /// Copy.ObjectMenu.changeCategory, Copy.PlanEditor.editText; Copy.Project.delete for deleteOpening,
    /// deleteFixture and deleteAnnotation.
    static func title(_ command: PlanEditorCommand, item: PlanEditorItem?) -> String {
        switch command {
        case .wallLength: return Copy.FloorPlan.wallLength
        case .wallThickness: return Copy.FloorPlan.wallThickness
        case .deleteWall: return Copy.FloorPlan.deleteWall
        case .addDoor: return Copy.FloorPlan.addDoor
        case .addWindow: return Copy.FloorPlan.addWindow
        case .addOpening: return Copy.FloorPlan.addOpening
        case .resizeOpening:
            guard case .opening(let opening, _)? = item else { return Copy.PlanEditor.resizeOpening }
            switch opening.kind {
            case .door, .openDoor: return Copy.FloorPlan.resizeDoor
            case .window: return Copy.FloorPlan.resizeWindow
            case .opening: return Copy.PlanEditor.resizeOpening
            }
        case .flipDoorSwing: return Copy.FloorPlan.flipDoorSwing
        case .deleteOpening, .deleteFixture, .deleteAnnotation: return Copy.Project.delete
        case .renameRoom: return Copy.FloorPlan.renameRoom
        case .mergeRooms: return Copy.FloorPlan.mergeRooms
        case .splitRoom: return Copy.FloorPlan.splitRoom
        case .turnFixture: return Copy.PlanEditor.turn
        case .changeCategory: return Copy.ObjectMenu.changeCategory
        case .editAnnotation: return Copy.PlanEditor.editText
        case .deleteMeasurement: return Copy.FloorPlan.deleteMeasurement
        case .addWall: return Copy.FloorPlan.addWall
        case .addMeasurement: return Copy.FloorPlan.addMeasurement
        case .addText: return Copy.FloorPlan.addText
        case .addSymbol: return Copy.FloorPlan.addSymbol
        case .addNote: return Copy.FloorPlan.addNote
        }
    }

    /// The hint line of a tool; `pending` is the number of points already placed.
    static func hint(for tool: PlanEditTool, pending: Int) -> String? {
        switch tool {
        case .select: return Copy.PlanEditor.selectHint
        case .addWall: return pending == 0 ? Copy.PlanEditor.wallStartHint : Copy.PlanEditor.wallEndHint
        case .addOpening: return Copy.PlanEditor.openingHint
        case .addDimension: return pending == 0 ? Copy.PlanEditor.dimensionStartHint : Copy.PlanEditor.dimensionEndHint
        case .addAnnotation: return Copy.PlanEditor.annotationHint
        case .splitRoom: return pending == 0 ? Copy.FloorPlan.splitHint : Copy.PlanEditor.splitEndHint
        case .mergeRooms: return Copy.FloorPlan.mergeHint
        }
    }

    /// The snap line for a snapped point, nil when nothing snapped.
    static func snapText(_ kind: PlanSnapKind?) -> String? {
        switch kind {
        case .endpoint?: return Copy.PlanEditor.snappedEnd
        case .wall?: return Copy.PlanEditor.snappedWall
        case .angle?: return Copy.PlanEditor.snappedAngle
        case .grid?: return Copy.PlanEditor.snappedGrid
        case .none?, nil: return nil
        }
    }

    /// The alert text of a refused action. `.outOfRange` names the wall length range; typed
    /// values name their own range through `rangeMessage(_:prefs:)`.
    static func message(for error: PlanEditorError, prefs: UnitPreferences) -> String {
        switch error {
        case .notFound: return Copy.PlanEditor.notFound
        case .tooShort: return Copy.PlanEditor.tooShort(lengthText(PlanEditorOps.minimumWallLength, prefs: prefs))
        case .outOfRange: return rangeMessage(PlanEditorOps.wallLengthRange, prefs: prefs)
        case .curvedWall: return Copy.PlanEditor.curvedWall
        case .lockedWall: return Copy.PlanEditor.lockedWall
        case .splitMissesRoom: return Copy.PlanEditor.splitMisses
        case .nothingToMerge: return Copy.PlanEditor.nothingToMerge
        case .notOnLevel: return Copy.PlanEditor.notOnLevel
        }
    }

    /// "Use a value from low to high." with both ends formatted with Units.
    static func rangeMessage(_ range: ClosedRange<Float>, prefs: UnitPreferences) -> String {
        Copy.PlanEditor.outOfRange(lengthText(range.lowerBound, prefs: prefs), lengthText(range.upperBound, prefs: prefs))
    }

    /// One line per operation kind for Results' orphaned-edit list (3.43b), exhaustive switch; a
    /// batch reads as its first operation.
    static func describe(_ op: EditOperation) -> String {
        switch op {
        case .renameRoom: return Copy.PlanEditor.editRoomRenamed
        case .relabelObject: return Copy.PlanEditor.editObjectRenamed
        case .recategorizeObject: return Copy.PlanEditor.editCategoryChanged
        case .setHidden: return Copy.PlanEditor.editHidden
        case .deleteElement: return Copy.PlanEditor.editDeleted
        case .moveObject: return Copy.PlanEditor.editObjectMoved
        case .moveWallEndpoint: return Copy.PlanEditor.editWallMoved
        case .addWall: return Copy.PlanEditor.editWallAdded
        case .addOpening: return Copy.PlanEditor.editOpeningAdded
        case .setDoorSwing: return Copy.PlanEditor.editSwingChanged
        case .setWallThickness: return Copy.PlanEditor.editThicknessChanged
        case .addAnnotation: return Copy.PlanEditor.editLabelAdded
        case .addDimension: return Copy.PlanEditor.editMeasurementAdded
        case .setScaleCorrection: return Copy.PlanEditor.editScaleCorrected
        case .setRoomAlignment: return Copy.PlanEditor.editRoomLinedUp
        case .cropObject: return Copy.PlanEditor.editObjectCropped
        case .moveOpening: return Copy.PlanEditor.editOpeningMoved
        case .resizeOpening: return Copy.PlanEditor.editOpeningResized
        case .mergeRooms: return Copy.PlanEditor.editRoomsMerged
        case .splitRoom: return Copy.PlanEditor.editRoomSplit
        case .batch(let operations):
            guard let first = operations.first else { return Copy.PlanEditor.editEmpty }
            return describe(first)
        }
    }

    /// Room title (`RoomTitles`), or "Wall 3", "Door 1", "Window 2", "Opening 1" numbered in level order
    /// (Copy.MeasureCore wallTitle, doorTitle, windowTitle, openingTitle), the category name of a
    /// fixture, the annotation text (its symbol for a symbol), or `Copy.PlanEditor.measurementItem`.
    static func itemTitle(_ item: PlanEditorItem, level: PlanLevel, roomTitles: [ElementID: String]) -> String {
        switch item {
        case .room(let room):
            if let title = roomTitles[room.id] { return title }
            let index = level.rooms.firstIndex { $0.id == room.id } ?? 0
            return RoomTitles.title(name: room.name, sectionLabel: nil, index: index)
        case .wall(let wall):
            let index = level.walls.firstIndex { $0.id == wall.id } ?? 0
            return Copy.MeasureCore.wallTitle(index + 1)
        case .opening(let opening, _):
            let sameKind = level.openings.filter { openingGroup($0.kind) == openingGroup(opening.kind) }
            let number = (sameKind.firstIndex { $0.id == opening.id } ?? 0) + 1
            switch opening.kind {
            case .door, .openDoor: return Copy.MeasureCore.doorTitle(number)
            case .window: return Copy.MeasureCore.windowTitle(number)
            case .opening: return Copy.MeasureCore.openingTitle(number)
            }
        case .fixture(let fixture):
            return Copy.FloorPlan.categoryName(fixture.category)
        case .annotation(let annotation):
            if annotation.kind == .symbol, let symbol = annotation.symbol, !symbol.isEmpty { return symbol }
            let firstLine = annotation.text.components(separatedBy: .newlines).first { !$0.isEmpty }
            return firstLine ?? Copy.FloorPlan.textPlaceholder
        case .dimension:
            return Copy.PlanEditor.measurementItem
        }
    }

    /// Numbering group of an opening kind: doors (open or not), windows, openings.
    private static func openingGroup(_ kind: OpeningKind) -> Int {
        switch kind {
        case .door, .openDoor: return 0
        case .window: return 1
        case .opening: return 2
        }
    }

    /// `PlanLevel.name`, else `Copy.House.floorLabel(id + 1)`.
    static func levelTitle(_ level: PlanLevel) -> String {
        let name = level.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? Copy.House.floorLabel(level.id + 1) : name
    }

    /// Add Symbol choices, stored in `PlanAnnotation.symbol` as shown (FloorPlan draws the text).
    static let symbols: [String] = [
        Copy.PlanEditor.symbolOutlet, Copy.PlanEditor.symbolSwitch, Copy.PlanEditor.symbolLight,
        Copy.PlanEditor.symbolSmokeAlarm, Copy.PlanEditor.symbolWater, Copy.PlanEditor.symbolGas,
        Copy.PlanEditor.symbolVent, Copy.PlanEditor.symbolThermostat
    ]

    /// `LengthParser.meters(from:prefs:)` accepted when finite and inside `range`; nil otherwise.
    static func parseLength(_ text: String, prefs: UnitPreferences, range: ClosedRange<Float>) -> Float? {
        guard let meters = LengthParser.meters(from: text, prefs: prefs), meters.isFinite else { return nil }
        let value = Float(meters)
        guard value.isFinite, range.contains(value) else { return nil }
        return value
    }

    /// Why a typed length was rejected: `Copy.PlanEditor.invalidLength` when it is not a length,
    /// else the range message.
    static func lengthProblem(_ text: String, prefs: UnitPreferences, range: ClosedRange<Float>) -> String {
        guard let meters = LengthParser.meters(from: text, prefs: prefs), meters.isFinite else {
            return Copy.PlanEditor.invalidLength
        }
        return rangeMessage(range, prefs: prefs)
    }

    /// The starting text of a length field: `LengthFormat.primary`.
    static func lengthText(_ meters: Float, prefs: UnitPreferences) -> String {
        LengthFormat.primary(Double(meters), prefs: prefs)
    }
}
