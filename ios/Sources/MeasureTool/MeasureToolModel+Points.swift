import Foundation
import CoreGraphics
import UIKit
import simd

/// Taps, drags, completion, undo and list edits of `MeasureToolModel` (docs/MODULES.md 3.35 Rules).
/// Main actor, like the model.
extension MeasureToolModel {
    // MARK: - Tap

    /// A tap routed by Results while measuring. A nil hit sets the hint `Copy.MeasureTool.noSurface`
    /// and places nothing. The Wall tool makes both wall records at once (or hints `noWall`); the
    /// other tools resolve the point (`MeasureToolSnaps.resolve`), fire a selection haptic and show
    /// the "Snapped to" tag for a feature, and complete at their point count. An area closes when a
    /// tap lands within `closeRadiusPoints` of the first point with 3 or more points placed.
    func tap(_ hit: ViewerHit?) {
        guard let hit else {
            hint = Copy.MeasureTool.noSurface
            return
        }
        if tool == .wall {
            tapWall(hit)
            return
        }
        if draft.kind != tool { draft = .empty(tool) }
        let point = MeasureToolSnaps.resolve(hit, parts: viewer.content.parts, context: context,
                                             snapping: snappingEnabled)
        if tool == .area, draft.points.count >= 3, closesArea(point) {
            finishArea()
            return
        }
        if tool == .area, draft.points.count >= MeasureToolSnaps.maximumAreaPoints {
            hint = Copy.MeasureTool.areaClose
            return
        }
        announceSnap(point)
        draft.points.append(point)
        updateDraftValue()
        if tool != .area, draft.points.count >= tool.minimumPoints {
            completeDraft()
        }
    }

    /// Wall tool tap: both wall records, or the `noWall` hint.
    private func tapWall(_ hit: ViewerHit) {
        guard let wall = MeasureToolSnaps.wall(for: hit, context: context) else {
            hint = Copy.MeasureTool.noWall
            return
        }
        let made = MeasureToolSnaps.wallRecords(wall, context: context, now: Date())
        commit(made, reopen: .empty(.wall))
    }

    /// True when `point` projects within `closeRadiusPoints` of the first draft point's projection.
    private func closesArea(_ point: MeasureToolPoint) -> Bool {
        guard let first = draft.points.first, let a = screenPoint(first.position),
              let b = screenPoint(point.position) else { return false }
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot() <= MeasureToolSnaps.closeRadiusPoints
    }

    /// Area tool: completes the draft when it has at least 3 points.
    func finishArea() {
        guard draft.kind == .area, draft.points.count >= 3 else { return }
        completeDraft()
    }

    /// Saves the complete draft as a record and starts a new draft of the same tool.
    private func completeDraft() {
        guard let record = MeasureToolSnaps.record(for: draft, context: context, id: UUID(), now: Date()) else {
            updateDraftValue()
            return
        }
        commit([record], reopen: draft)
    }

    /// Appends records, saves and logs them, and clears the draft (the tool stays).
    private func commit(_ made: [MeasurementRecord], reopen: MeasureToolDraft) {
        guard !made.isEmpty else { return }
        records.append(contentsOf: made)
        completed.append(MeasureToolCompletion(ids: made.map { $0.id }, draft: reopen))
        for record in made {
            LogStore.shared.write(MeasureToolPresentation.logLine(record, event: "created"),
                                  category: MeasureToolModel.logCategory)
        }
        recordsChanged()
        persist()
        Haptics.tap()
        draft = .empty(tool)
        updateDraftValue()
        announce(made)
    }

    /// Reads the new value aloud for VoiceOver users (the row's text).
    private func announce(_ made: [MeasurementRecord]) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        let ids = Set(made.map { $0.id })
        let spoken = rows.filter { ids.contains($0.id) }.map { $0.accessibility }
        guard !spoken.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: spoken.joined(separator: ". "))
    }

    /// Selection haptic and "Snapped to" tag for a point with a feature (MEAS-08).
    func announceSnap(_ point: MeasureToolPoint) {
        guard let text = MeasureToolPresentation.snapText(point) else { return }
        Haptics.selection()
        snapText = text
        snapClearTask?.cancel()
        snapClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: MeasureToolModel.snapTextNanoseconds)
            guard !Task.isCancelled else { return }
            self?.snapText = nil
        }
    }

    // MARK: - Undo and clear

    /// Removes the last draft point; with an empty draft, reopens the measurement completed last in
    /// this session (removing its saved record; both records of a Wall tap). A reopened distance,
    /// height or angle loses its last point; a reopened area keeps its corners (Undo takes back the
    /// closing tap); a Wall tap leaves an empty Wall draft.
    func undoPoint() {
        if !draft.points.isEmpty {
            draft.points.removeLast()
            updateDraftValue()
            return
        }
        while let last = completed.popLast() {
            let ids = Set(last.ids)
            let removed = records.filter { ids.contains($0.id) }
            guard !removed.isEmpty else { continue }
            records.removeAll { ids.contains($0.id) }
            for record in removed {
                LogStore.shared.write(MeasureToolPresentation.logLine(record, event: "deleted"),
                                      category: MeasureToolModel.logCategory)
            }
            recordsChanged()
            persist()
            var reopened = last.draft
            if reopened.kind != .area, !reopened.points.isEmpty {
                reopened.points.removeLast()
            }
            if tool != reopened.kind { tool = reopened.kind }
            draft = reopened
            updateDraftValue()
            return
        }
    }

    /// Clears the draft (the tool stays).
    func clearDraft() {
        draft = .empty(tool)
        updateDraftValue()
    }

    /// True when Undo has something to take back.
    var canUndo: Bool {
        !draft.points.isEmpty || !completed.isEmpty
    }

    // MARK: - Drag

    /// Re-places a handle under `screenPoint` (`viewer.hitTest`, then `MeasureToolSnaps.resolve`);
    /// a miss keeps the point. The value updates live; a feature change fires the snap haptic.
    func drag(_ handle: MeasureToolHandle, to screenPoint: CGPoint) {
        guard let hit = viewer.hitTest(screenPoint) else { return }
        let point = MeasureToolSnaps.resolve(hit, parts: viewer.content.parts, context: context,
                                             snapping: snappingEnabled)
        if point.feature != dragFeature {
            dragFeature = point.feature
            announceSnap(point)
        }
        switch handle {
        case .draft(let index):
            guard index >= 0, index < draft.points.count else { return }
            draft.points[index] = point
            updateDraftValue()
        case .record(let id, let index):
            guard let i = records.firstIndex(where: { $0.id == id }),
                  !MeasureToolSnaps.isWallRecord(records[i], among: records),
                  index >= 0, index < records[i].points.count else { return }
            if dragOriginals[id] == nil { dragOriginals[id] = records[i] }
            records[i] = MeasureToolSnaps.moving(records[i], index: index, to: point, context: context)
            if let entry = completed.firstIndex(where: { $0.ids.contains(id) }),
               index < completed[entry].draft.points.count {
                completed[entry].draft.points[index] = point
            }
            recordsChanged()
        }
    }

    /// A moved record is saved and logged ("measurement edited").
    func endDrag(_ handle: MeasureToolHandle) {
        dragFeature = nil
        guard case .record(let id, _) = handle, let original = dragOriginals.removeValue(forKey: id) else { return }
        guard let record = records.first(where: { $0.id == id }), record != original else { return }
        LogStore.shared.write(MeasureToolPresentation.logLine(record, event: "edited"),
                              category: MeasureToolModel.logCategory)
        persist()
    }

    /// A tap on a handle (no drag): places a point there as a tap on the model would, so a new
    /// measurement can start at an existing point and an area closes on its first point.
    func tapHandle(_ handle: MeasureToolHandle) {
        dragFeature = nil
        guard let world = position(of: handle), let screen = screenPoint(world) else { return }
        tap(viewer.hitTest(screen))
    }

    /// World position of a handle, if it still exists.
    func position(of handle: MeasureToolHandle) -> SIMD3<Float>? {
        switch handle {
        case .draft(let index):
            guard index >= 0, index < draft.points.count else { return nil }
            return draft.points[index].position
        case .record(let id, let index):
            guard let record = records.first(where: { $0.id == id }), index >= 0,
                  index < record.points.count else { return nil }
            return record.points[index].simd
        }
    }

    // MARK: - List

    /// Renames a record (whitespace trimmed; empty restores the numbered title).
    func rename(_ id: UUID, to name: String) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard records[i].name != trimmed else { return }
        records[i].name = trimmed
        LogStore.shared.write(MeasureToolPresentation.logLine(records[i], event: "edited") + " renamed",
                              category: MeasureToolModel.logCategory)
        recordsChanged()
        persist()
    }

    /// Deletes one record.
    func delete(_ id: UUID) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        records.removeAll { $0.id == id }
        completed.removeAll { $0.ids.contains(id) }
        LogStore.shared.write(MeasureToolPresentation.logLine(record, event: "deleted"),
                              category: MeasureToolModel.logCategory)
        recordsChanged()
        persist()
    }

    /// After `Copy.MeasureTool.deleteAllTitle` was confirmed: removes every saved measurement.
    func deleteAll() {
        guard !records.isEmpty else { return }
        for record in records {
            LogStore.shared.write(MeasureToolPresentation.logLine(record, event: "deleted"),
                                  category: MeasureToolModel.logCategory)
        }
        records = []
        completed = []
        recordsChanged()
        persist()
    }
}
