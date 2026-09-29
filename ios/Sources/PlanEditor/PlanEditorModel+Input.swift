import Foundation
import simd

/// One entry of the Plan Items menu (VoiceOver selection of any plan element).
struct PlanEditorListItem: Identifiable, Equatable {
    /// The element.
    let id: ElementID
    /// Its title (`PlanEditorPresentation.itemTitle`).
    let title: String
}

/// Tools, taps, commands, the inspector and prompts of the plan editor (docs/MODULES.md 3.37,
/// rules "Taps" and "Prompts"). Drags are in `PlanEditorModel+Drag.swift`.
extension PlanEditorModel {
    // MARK: - Tools

    /// Makes `tool` the active tool; pending points and the merge selection start over. Merge
    /// Rooms selects the room the others join into.
    func setTool(_ tool: PlanEditTool) {
        setToolState(tool)
        notice = nil
        clearSnap()
        if case .mergeRooms(let into) = tool { selection = into }
        if case .splitRoom(let room) = tool { selection = room }
    }

    /// Back to the select tool without doing anything.
    func cancelTool() {
        setToolState(.select)
        notice = nil
        clearSnap()
    }

    /// Clears the snap marker and line.
    func clearSnap() {
        setSnap(nil, at: nil)
    }

    // MARK: - Taps

    /// Plan meters; `tolerance` is 12 points converted with the canvas viewport.
    func tap(at point: SIMD2<Float>, tolerance: Float) {
        guard isLoaded, activeDrag == nil, let level = committedLevel, PlanEditorOps.isFinite(point) else { return }
        notice = nil
        switch tool {
        case .select:
            selectHit(at: point, tolerance: tolerance, level: level)
        case .addWall:
            let snapped = snapPoint(point, anchor: pendingPoints.last?.simd, tolerance: tolerance, level: level)
            guard let first = pendingPoints.first else {
                setPending([Vec2(snapped)])
                return
            }
            let id = ElementID()
            finishAdd(.addWall(id, a: first, b: Vec2(snapped)), select: id)
        case .addDimension:
            let snapped = snapPoint(point, anchor: pendingPoints.last?.simd, tolerance: tolerance, level: level)
            guard let first = pendingPoints.first else {
                setPending([Vec2(snapped)])
                return
            }
            let id = ElementID()
            finishAdd(.addDimension(id, a: first, b: Vec2(snapped)), select: id)
        case .addOpening(let kind):
            placeOpening(kind, at: point, tolerance: tolerance, level: level)
        case .addAnnotation(let kind):
            let snapped = snapPoint(point, anchor: nil, tolerance: 0, level: level)
            promptError = nil
            prompt = .annotation(kind: kind, at: Vec2(snapped), editing: nil, current: "")
        case .splitRoom(let room):
            let snapped = snapPoint(point, anchor: pendingPoints.last?.simd, tolerance: tolerance, level: level)
            guard let first = pendingPoints.first else {
                setPending([Vec2(snapped)])
                return
            }
            finishAdd(.splitRoom(room, a: first, b: Vec2(snapped), newRoom: ElementID()), select: room)
        case .mergeRooms(let into):
            let roomHits = (drawing?.hits ?? []).filter { $0.kind == .room }
            guard let hit = PlanDrawing.hitTest(roomHits, at: point, tolerance: tolerance), hit.element != into else { return }
            var rooms = mergeSelection
            if let index = rooms.firstIndex(of: hit.element) {
                rooms.remove(at: index)
            } else {
                rooms.append(hit.element)
            }
            setMergeSelection(rooms)
            Haptics.selection()
        }
    }

    /// Select tool: a generated wall dimension selects its wall and opens Wall Length (PEDIT-02);
    /// any other hit selects its element; empty space clears the selection.
    private func selectHit(at point: SIMD2<Float>, tolerance: Float, level: PlanLevel) {
        guard let hit = PlanDrawing.hitTest(drawing?.hits ?? [], at: point, tolerance: tolerance) else {
            selection = nil
            return
        }
        if hit.kind == .dimension,
           let wall = level.walls.first(where: { PlanBuilder.wallDimensionID($0.id) == hit.element }) {
            selection = wall.id
            if wall.arc == nil {
                promptError = nil
                prompt = .wallLength(wall.id, current: simd_distance(wall.a.simd, wall.b.simd))
            }
            return
        }
        selection = hit.element
    }

    /// Add Door, Window or Opening: the tap must be within tolerance of a straight wall; the
    /// center is the tap projected on it.
    private func placeOpening(_ kind: OpeningKind, at point: SIMD2<Float>, tolerance: Float, level: PlanLevel) {
        let walls = (drawing?.hits ?? []).filter { $0.kind == .wall }
        guard let hit = PlanDrawing.hitTest(walls, at: point, tolerance: tolerance),
              let wall = level.walls.first(where: { $0.id == hit.element }), wall.arc == nil else {
            notice = Copy.PlanEditor.tapWall
            return
        }
        let a = wall.a.simd
        let d = wall.b.simd - a
        let length = simd_length(d)
        guard length > 1e-6 else { return }
        let center = min(max(simd_dot(point - a, d / length), 0), length)
        let id = ElementID()
        finishAdd(.addOpening(id, kind: kind, wall: wall.id, center: center, width: PlanEditorModel.defaultWidth(kind)),
                  select: id)
    }

    /// Performs an add; on success the tool returns to select with `select` selected. A refused
    /// add keeps the tool and starts its points over (the alert says why).
    func finishAdd(_ action: PlanEditAction, select id: ElementID) {
        setPending([])
        do {
            try perform(action)
            setToolState(.select)
            selection = id
        } catch {
            record("add not made: \(error)")
        }
        clearSnap()
    }

    /// Default width of a new door, window or opening.
    static func defaultWidth(_ kind: OpeningKind) -> Float {
        switch kind {
        case .door, .openDoor: return PlanEditorOps.defaultDoorWidth
        case .window: return PlanEditorOps.defaultWindowWidth
        case .opening: return PlanEditorOps.defaultOpeningWidth
        }
    }

    /// A tapped point snapped with the level's targets (radius the larger of 5 cm and the tap
    /// tolerance); publishes the snap kind and plays a selection haptic on a new snap.
    func snapPoint(_ point: SIMD2<Float>, anchor: SIMD2<Float>?, tolerance: Float, level: PlanLevel,
                   excluding: Set<ElementID> = []) -> SIMD2<Float> {
        let targets = PlanEditorSnapping.targets(level: level, excluding: excluding)
        let radius = max(PlanEditorSnapping.endpointRadius, tolerance.isFinite ? tolerance : 0)
        let result = PlanEditorSnapping.snap(point, anchor: anchor, targets: targets, radius: radius,
                                             grid: PlanEditorSnapping.gridStep(prefs), enabled: snappingEnabled)
        showSnap(result.kind, at: result.point)
        return result.point
    }

    /// Publishes a snap kind and its point; a new end, wall or angle snap plays the selection
    /// haptic.
    func showSnap(_ kind: PlanSnapKind, at point: SIMD2<Float>? = nil) {
        let shown: PlanSnapKind? = kind == PlanSnapKind.none ? nil : kind
        if let now = shown, now != snapKind, now != .grid { Haptics.selection() }
        setSnap(shown, at: point)
    }

    /// Merge Rooms: joins the tapped rooms into the tool's room.
    func commitMerge() {
        guard case .mergeRooms(let into) = tool else { return }
        finishAdd(.mergeRooms(mergeSelection, into: into), select: into)
    }

    // MARK: - Commands

    /// For the selection, or the add commands when nothing is selected.
    var commands: [PlanEditorCommand] {
        guard let item = selectedItem else {
            return [.addWall, .addDoor, .addWindow, .addOpening, .addMeasurement, .addText, .addSymbol, .addNote]
        }
        switch item {
        case .wall(let wall):
            if wall.arc != nil { return [.wallThickness, .deleteWall] }
            return [.wallLength, .wallThickness, .addDoor, .addWindow, .addOpening, .deleteWall]
        case .opening(let opening, _):
            let isDoor = opening.kind == .door || opening.kind == .openDoor
            return isDoor ? [.resizeOpening, .flipDoorSwing, .deleteOpening] : [.resizeOpening, .deleteOpening]
        case .room:
            return [.renameRoom, .mergeRooms, .splitRoom]
        case .fixture:
            return [.turnFixture, .changeCategory, .deleteFixture]
        case .annotation:
            return [.editAnnotation, .deleteAnnotation]
        case .dimension:
            return [.deleteMeasurement]
        }
    }

    /// Runs an inspector or add bar command.
    func run(_ command: PlanEditorCommand) {
        guard isLoaded else { return }
        notice = nil
        promptError = nil
        let item = selectedItem
        switch command {
        case .addWall: setTool(.addWall)
        case .addMeasurement: setTool(.addDimension)
        case .addText: setTool(.addAnnotation(.text))
        case .addSymbol: setTool(.addAnnotation(.symbol))
        case .addNote: setTool(.addAnnotation(.note))
        case .addDoor: addOpening(.door, on: item)
        case .addWindow: addOpening(.window, on: item)
        case .addOpening: addOpening(.opening, on: item)
        default:
            runForSelection(command, item: item)
        }
    }

    /// Commands that act on the selected item.
    private func runForSelection(_ command: PlanEditorCommand, item: PlanEditorItem?) {
        guard let item else { return }
        switch (command, item) {
        case (.wallLength, .wall(let wall)):
            prompt = .wallLength(wall.id, current: simd_distance(wall.a.simd, wall.b.simd))
        case (.wallThickness, .wall(let wall)):
            prompt = .wallThickness(wall.id, current: wall.thickness)
        case (.deleteWall, .wall(let wall)):
            attempt(.deleteWall(wall.id), thenSelect: nil)
        case (.resizeOpening, .opening(let opening, _)):
            prompt = .openingSize(opening.id, width: opening.width, height: openingHeight(opening.id))
        case (.flipDoorSwing, .opening(let opening, _)):
            attempt(.flipDoorSwing(opening.id), thenSelect: opening.id)
        case (.deleteOpening, .opening(let opening, _)):
            attempt(.deleteElement(opening.id), thenSelect: nil)
        case (.renameRoom, .room(let room)):
            prompt = .renameRoom(room.id, current: room.name)
        case (.mergeRooms, .room(let room)):
            setTool(.mergeRooms(into: room.id))
        case (.splitRoom, .room(let room)):
            setTool(.splitRoom(room.id))
        case (.turnFixture, .fixture(let fixture)):
            let turned = PlanEditorModel.normalizedAngle(fixture.yaw + Float.pi / 2)
            attempt(.moveFixture(fixture.id, center: fixture.center, yaw: turned), thenSelect: fixture.id)
        case (.changeCategory, .fixture(let fixture)):
            prompt = .category(fixture.id, current: fixture.category)
        case (.deleteFixture, .fixture(let fixture)):
            attempt(.deleteFixture(fixture.id), thenSelect: nil)
        case (.editAnnotation, .annotation(let annotation)):
            let current = annotation.kind == .symbol ? (annotation.symbol ?? "") : annotation.text
            prompt = .annotation(kind: annotation.kind, at: annotation.at, editing: annotation.id, current: current)
        case (.deleteAnnotation, .annotation(let annotation)):
            attempt(.deleteElement(annotation.id), thenSelect: nil)
        case (.deleteMeasurement, .dimension(let dimension)):
            attempt(.deleteElement(dimension.id), thenSelect: nil)
        default:
            record("command \(command.rawValue) does not apply to the selection")
        }
    }

    /// Add Door, Window or Opening from the inspector: centered on the selected straight wall
    /// (one step, VoiceOver friendly), else the tool that places it with a tap.
    private func addOpening(_ kind: OpeningKind, on item: PlanEditorItem?) {
        guard case .wall(let wall)? = item, wall.arc == nil else {
            setTool(.addOpening(kind))
            return
        }
        let length = simd_distance(wall.a.simd, wall.b.simd)
        let id = ElementID()
        finishAdd(.addOpening(id, kind: kind, wall: wall.id, center: length / 2, width: PlanEditorModel.defaultWidth(kind)),
                  select: id)
    }

    /// Performs an action and selects `id` afterwards (nil clears the selection). Refusals are
    /// already shown by `perform`.
    func attempt(_ action: PlanEditAction, thenSelect id: ElementID?) {
        do {
            try perform(action)
            selection = id
        } catch {
            record("action not made: \(error)")
        }
    }

    /// Head minus sill of a clean opening, nil without one.
    func openingHeight(_ id: ElementID) -> Float? {
        guard let clean, let found = PlanEditorOps.cleanOpening(id, in: clean) else { return nil }
        let height = found.opening.headHeight - found.opening.sillHeight
        return height.isFinite && height > 0 ? height : nil
    }

    /// An angle wrapped to (-pi, pi].
    static func normalizedAngle(_ angle: Float) -> Float {
        guard angle.isFinite else { return 0 }
        var a = angle.truncatingRemainder(dividingBy: 2 * Float.pi)
        if a > Float.pi { a -= 2 * Float.pi }
        if a <= -Float.pi { a += 2 * Float.pi }
        return a
    }

    // MARK: - Inspector

    /// The selected element of the edited level, from the shown plan.
    var selectedItem: PlanEditorItem? {
        guard let id = selection, plan.levels.indices.contains(levelIndex) else { return nil }
        let level = plan.levels[levelIndex]
        if let wall = level.walls.first(where: { $0.id == id }) { return .wall(wall) }
        if let opening = level.openings.first(where: { $0.id == id }),
           let wall = level.walls.first(where: { $0.id == opening.wallID }) {
            return .opening(opening, wall: wall)
        }
        if let room = level.rooms.first(where: { $0.id == id }) { return .room(room) }
        if let fixture = level.fixtures.first(where: { $0.id == id }) { return .fixture(fixture) }
        if let annotation = level.annotations.first(where: { $0.id == id }) { return .annotation(annotation) }
        if let dimension = level.dimensions.first(where: { $0.id == id }) { return .dimension(dimension) }
        return nil
    }

    /// Title of the selection for the inspector, nil when nothing is selected.
    var selectedTitle: String? {
        guard let item = selectedItem, plan.levels.indices.contains(levelIndex) else { return nil }
        return PlanEditorPresentation.itemTitle(item, level: plan.levels[levelIndex], roomTitles: roomTitles)
    }

    /// Drag handles of the selection, plan meters (wall ends, opening ends, fixture center, annotation anchor).
    var handles: [SIMD2<Float>] {
        guard let item = selectedItem else { return [] }
        switch item {
        case .wall(let wall):
            return wall.arc == nil ? [wall.a.simd, wall.b.simd] : []
        case .opening(let opening, let wall):
            let a = wall.a.simd
            let d = wall.b.simd - a
            let length = simd_length(d)
            guard length > 1e-6 else { return [] }
            let u = d / length
            return [a + u * opening.offset, a + u * (opening.offset + opening.width)]
        case .fixture(let fixture):
            return [fixture.center.simd]
        case .annotation(let annotation):
            return [annotation.at.simd]
        case .room, .dimension:
            return []
        }
    }

    /// The hint or snap line: a notice first, then the snap, then the tool's hint.
    var statusLine: String? {
        if let notice { return notice }
        if let snap = PlanEditorPresentation.snapText(snapKind) { return snap }
        return PlanEditorPresentation.hint(for: tool, pending: pendingPoints.count)
    }

    /// Selectable items of the level with their titles, for the VoiceOver Plan Items menu.
    var itemList: [PlanEditorListItem] {
        guard plan.levels.indices.contains(levelIndex) else { return [] }
        let level = plan.levels[levelIndex]
        var items: [PlanEditorItem] = []
        items += level.rooms.map { PlanEditorItem.room($0) }
        items += level.walls.map { PlanEditorItem.wall($0) }
        for opening in level.openings {
            if let wall = level.walls.first(where: { $0.id == opening.wallID }) {
                items.append(PlanEditorItem.opening(opening, wall: wall))
            }
        }
        items += level.fixtures.filter { !$0.isHidden }.map { PlanEditorItem.fixture($0) }
        items += level.annotations.map { PlanEditorItem.annotation($0) }
        items += level.dimensions.filter { $0.isUser }.map { PlanEditorItem.dimension($0) }
        return items.map { item in
            PlanEditorListItem(id: PlanEditorModel.itemID(item),
                               title: PlanEditorPresentation.itemTitle(item, level: level, roomTitles: roomTitles))
        }
    }

    /// The element id of an inspector item.
    static func itemID(_ item: PlanEditorItem) -> ElementID {
        switch item {
        case .wall(let wall): return wall.id
        case .opening(let opening, _): return opening.id
        case .room(let room): return room.id
        case .fixture(let fixture): return fixture.id
        case .annotation(let annotation): return annotation.id
        case .dimension(let dimension): return dimension.id
        }
    }
}
