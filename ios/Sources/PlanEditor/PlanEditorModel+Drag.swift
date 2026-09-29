import Foundation
import simd

/// What a canvas drag edits.
enum PlanEditorDragKind: Equatable {
    /// One end of a straight wall.
    case wallEnd(ElementID, atStart: Bool)
    /// The body of a wall, grabbed at `start` (plan meters).
    case wallBody(ElementID, start: SIMD2<Float>)
    /// A door, window or opening, grabbed `grab` meters past its near edge along the wall.
    case opening(ElementID, grab: Float)
    /// A fixture, grabbed `grab` from its center.
    case fixture(ElementID, grab: SIMD2<Float>)
    /// An annotation, grabbed `grab` from its anchor.
    case annotation(ElementID, grab: SIMD2<Float>)
}

/// A running canvas drag: what it edits and the last action whose preview was valid.
struct PlanEditorDrag {
    /// What is dragged.
    var kind: PlanEditorDragKind
    /// The action `endDrag` performs.
    var lastValid: PlanEditAction?
    /// Why the current point cannot be applied (shown when the drag ends without a valid action).
    var lastError: PlanEditorError?
}

/// Drags of the plan editor (docs/MODULES.md 3.37, rule "Drags"): a drag that starts on the
/// selection edits it with a live preview; `endDrag` performs the last valid action as one log
/// entry.
extension PlanEditorModel {
    /// Wall end handles grab within this multiple of the tap tolerance.
    static let handleGrabFactor: Float = 1.5

    /// True when the point grabs the selection (the canvas then edits instead of panning).
    func beginDrag(at point: SIMD2<Float>, tolerance: Float) -> Bool {
        guard isLoaded, activeDrag == nil, tool == .select, let id = selection, let level = committedLevel,
              PlanEditorOps.isFinite(point) else { return false }
        guard let kind = grab(id, at: point, tolerance: tolerance, level: level) else { return false }
        activeDrag = PlanEditorDrag(kind: kind, lastValid: nil, lastError: nil)
        notice = nil
        return true
    }

    /// Maps the action for the current point (snapped), applies it to a copy of the edited plan and
    /// shows it as the preview; an invalid state keeps the last valid preview.
    func drag(to point: SIMD2<Float>, tolerance: Float) {
        guard var current = activeDrag, let level = committedLevel, PlanEditorOps.isFinite(point) else { return }
        guard let action = dragAction(current.kind, at: point, tolerance: tolerance, level: level) else { return }
        do {
            let op = try PlanEditorOps.operation(for: action, context: context())
            var preview = editedPlan
            guard preview.apply(op) else { throw PlanEditorError.notFound }
            current.lastValid = action
            current.lastError = nil
            activeDrag = current
            showPreview(preview)
        } catch let error as PlanEditorError {
            current.lastError = error
            activeDrag = current
        } catch {
            current.lastError = .notFound
            activeDrag = current
        }
    }

    /// Performs the last valid action of the drag (nothing when the preview equals the edited
    /// plan); a drag that never had a valid state shows why in the hint line.
    func endDrag() {
        guard let finished = activeDrag else { return }
        activeDrag = nil
        clearSnap()
        let changed = plan != editedPlan
        guard let action = finished.lastValid, changed else {
            endPreview()
            if let error = finished.lastError {
                notice = PlanEditorPresentation.message(for: error, prefs: prefs)
            }
            return
        }
        do {
            try perform(action)
        } catch {
            endPreview()
        }
    }

    /// What a drag starting at `point` grabs of the selected element: a straight wall's end handle
    /// (within 1.5 x tolerance) or body, an opening's span, a fixture footprint
    /// (`PlanSymbols.footprint`), an annotation's hit box.
    private func grab(_ id: ElementID, at point: SIMD2<Float>, tolerance: Float, level: PlanLevel) -> PlanEditorDragKind? {
        let limit = tolerance.isFinite ? max(0, tolerance) : 0
        if let wall = level.walls.first(where: { $0.id == id }) {
            if wall.arc == nil {
                let handle = limit * PlanEditorModel.handleGrabFactor
                if simd_distance(point, wall.a.simd) <= handle { return .wallEnd(id, atStart: true) }
                if simd_distance(point, wall.b.simd) <= handle { return .wallEnd(id, atStart: false) }
            }
            return hitDistance(id, point) <= limit ? .wallBody(id, start: point) : nil
        }
        if let opening = level.openings.first(where: { $0.id == id }),
           let wall = level.walls.first(where: { $0.id == opening.wallID }) {
            guard hitDistance(id, point) <= limit, let frame = PlanEditorOps.unitFrame(wall) else { return nil }
            let along = simd_dot(point - wall.a.simd, frame.u)
            return .opening(id, grab: along - opening.offset)
        }
        if let fixture = level.fixtures.first(where: { $0.id == id }) {
            let footprint = PlanHit(element: id, kind: .fixture, segment: nil, polygon: PlanSymbols.footprint(fixture))
            guard footprint.distance(to: point) <= limit else { return nil }
            return .fixture(id, grab: point - fixture.center.simd)
        }
        if let annotation = level.annotations.first(where: { $0.id == id }) {
            guard hitDistance(id, point) <= limit else { return nil }
            return .annotation(id, grab: point - annotation.at.simd)
        }
        return nil
    }

    /// Distance from `point` to the drawn hits of an element (infinity when it is not drawn).
    private func hitDistance(_ id: ElementID, _ point: SIMD2<Float>) -> Float {
        var best = Float.infinity
        for hit in drawing?.hits ?? [] where hit.element == id {
            best = min(best, hit.distance(to: point))
        }
        return best
    }

    /// The action for a drag at `point`, snapped with `PlanEditorSnapping` (the moving wall and
    /// its joined walls left out of the targets; a body move snaps its distance).
    private func dragAction(_ kind: PlanEditorDragKind, at point: SIMD2<Float>, tolerance: Float,
                            level: PlanLevel) -> PlanEditAction? {
        let grid = PlanEditorSnapping.gridStep(prefs)
        switch kind {
        case .wallEnd(let id, let atStart):
            guard let wall = level.walls.first(where: { $0.id == id }) else { return nil }
            var excluded: Set<ElementID> = [id]
            for end in PlanEditorOps.joined(id, atStart: atStart, in: level) { excluded.insert(end.wall) }
            let anchor = atStart ? wall.b.simd : wall.a.simd
            let snapped = snapPoint(point, anchor: anchor, tolerance: tolerance, level: level, excluding: excluded)
            return .moveWallEnd(id, atStart: atStart, to: Vec2(snapped))
        case .wallBody(let id, let start):
            guard let wall = level.walls.first(where: { $0.id == id }),
                  let frame = PlanEditorOps.unitFrame(wall) else { return nil }
            let raw = simd_dot(point - start, frame.n)
            let distance = PlanEditorSnapping.snapDistance(raw, grid: grid, enabled: snappingEnabled)
            showSnap(snappingEnabled ? .grid : .none)
            return .moveWall(id, by: distance)
        case .opening(let id, let grabOffset):
            guard let opening = level.openings.first(where: { $0.id == id }),
                  let wall = level.walls.first(where: { $0.id == opening.wallID }),
                  let frame = PlanEditorOps.unitFrame(wall) else { return nil }
            let raw = simd_dot(point - wall.a.simd, frame.u) - grabOffset
            let offset = PlanEditorSnapping.snapDistance(raw, grid: grid, enabled: snappingEnabled)
            showSnap(snappingEnabled ? .grid : .none)
            return .moveOpening(id, offset: offset)
        case .fixture(let id, let grabOffset):
            guard let fixture = level.fixtures.first(where: { $0.id == id }) else { return nil }
            let center = gridPoint(point - grabOffset, level: level)
            return .moveFixture(id, center: Vec2(center), yaw: fixture.yaw)
        case .annotation(let id, let grabOffset):
            guard var annotation = level.annotations.first(where: { $0.id == id }) else { return nil }
            annotation.at = Vec2(gridPoint(point - grabOffset, level: level))
            return .setAnnotation(annotation)
        }
    }

    /// A dragged fixture center or annotation anchor rounded to the grid in the frame of the
    /// level's main wall direction (no end or wall snapping for these).
    private func gridPoint(_ p: SIMD2<Float>, level: PlanLevel) -> SIMD2<Float> {
        let targets = PlanSnapTargets(endpoints: [], segments: [], axis: PlanEditorSnapping.referenceAxis(level))
        let result = PlanEditorSnapping.snap(p, anchor: nil, targets: targets, radius: 0,
                                             grid: PlanEditorSnapping.gridStep(prefs), enabled: snappingEnabled)
        showSnap(result.kind, at: result.point)
        return result.point
    }
}
