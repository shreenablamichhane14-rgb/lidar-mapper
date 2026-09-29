import Foundation
import simd

// The CR-1 edit operations on the clean model (build 5, docs/MODULES.md 3.37b): move and
// resize doors, windows and openings, merge and split rooms, and batches (one user action, one
// undo step). Each returns false only when a target is missing, and then changes nothing;
// geometry changes call `refresh(_:)` of the room (occlusion and unscaled metrics), and
// `applyingEdits(_:)` recomputes everything at the end. FloorPlan's `PlanModel.apply` (3.37c)
// follows the same rules with the same `Polygon2D.clipped(leftOf:_:)` arithmetic, so both
// models agree on every room's parts.

extension CleanModel {
    /// Limits of the CR-1 room and opening edits.
    enum RoomEditLimits {
        /// Smallest opening width after a resize, meters.
        static let minimumOpeningWidth: Float = 0.05
        /// A split whose smaller side holds less floor area than this leaves the room unchanged,
        /// square meters.
        static let minimumSplitArea: Float = 0.01
        /// Rooms merged with a ceiling height differing by more than this are logged, meters.
        static let ceilingDifferenceLog: Float = 0.05
        /// Merged-outline vertices within this distance of a moved wall end follow it, meters.
        static let outlineFollowDistance: Float = 0.001
        /// Split line points closer than this coincide, meters.
        static let coincidentPoints: Float = 1e-6
    }

    // MARK: - Openings

    /// `moveOpening`: the near edge goes `offset` meters from the wall start, clamped to
    /// [0, max(0, wall length - width)], provenance `.user`. A missing opening returns false; an
    /// opening without a wall, or a non-finite offset, returns true unchanged (logged).
    mutating func moveOpening(_ id: ElementID, offset: Float) -> Bool {
        guard let at = openingLocation(id) else { return false }
        var opening = rooms[at.room].openings[at.index]
        guard let wall = hostWall(of: opening) else {
            log("moveOpening \(id.uuid): opening has no wall; unchanged")
            return true
        }
        guard offset.isFinite else {
            log("moveOpening \(id.uuid): offset \(offset) ignored")
            return true
        }
        opening.offsetAlongWall = CleanModel.clampedOffset(offset, width: opening.width, wallLength: wall.length)
        opening.provenance = .user
        rooms[at.room].openings[at.index] = opening
        refresh(at.room)
        return true
    }

    /// `resizeOpening`: the width is clamped to [0.05, wall length] keeping the opening's
    /// center, then the offset is clamped as for `moveOpening`; heights apply when finite with
    /// 0 <= sill < head, the head capped by the wall height and the sill forced to 0 for doors
    /// (`door`, `openDoor`); invalid heights keep the old ones (logged). Provenance `.user`. A
    /// missing opening returns false. An opening without a wall keeps its center with no upper
    /// width limit and no head cap.
    mutating func resizeOpening(_ id: ElementID, width: Float, sillHeight: Float, headHeight: Float) -> Bool {
        guard let at = openingLocation(id) else { return false }
        var opening = rooms[at.room].openings[at.index]
        let wall = hostWall(of: opening)
        if width.isFinite {
            let upper = wall.map { Swift.max(0, $0.length) } ?? Float.greatestFiniteMagnitude
            let newWidth = Swift.min(Swift.max(width, RoomEditLimits.minimumOpeningWidth), upper)
            let center = opening.offsetAlongWall + opening.width * 0.5
            let centered = center - newWidth * 0.5
            if let wall {
                opening.offsetAlongWall = CleanModel.clampedOffset(centered, width: newWidth, wallLength: wall.length)
            } else {
                opening.offsetAlongWall = Swift.max(0, centered)
            }
            opening.width = newWidth
        } else {
            log("resizeOpening \(id.uuid): width \(width) ignored")
        }
        if let heights = CleanModel.resizedHeights(kind: opening.kind, sill: sillHeight, head: headHeight,
                                                   wallHeight: wall?.height) {
            opening.sillHeight = heights.sill
            opening.headHeight = heights.head
        } else {
            log("resizeOpening \(id.uuid): heights \(sillHeight) to \(headHeight) invalid; kept \(opening.sillHeight) to \(opening.headHeight)")
        }
        opening.provenance = .user
        rooms[at.room].openings[at.index] = opening
        refresh(at.room)
        return true
    }

    /// Near-edge offset clamped to [0, max(0, wallLength - width)].
    static func clampedOffset(_ offset: Float, width: Float, wallLength: Float) -> Float {
        let upper = Swift.max(0, wallLength - width)
        return Swift.min(Swift.max(offset, 0), upper)
    }

    /// Sill and head for a resize, or nil when they are invalid: both finite with
    /// 0 <= sill < head; the head is capped by a positive finite wall height; doors get sill 0;
    /// the result must still have sill < head.
    static func resizedHeights(kind: OpeningKind, sill: Float, head: Float, wallHeight: Float?) -> (sill: Float, head: Float)? {
        guard sill.isFinite, head.isFinite, sill >= 0, sill < head else { return nil }
        var cappedHead = head
        if let wallHeight, wallHeight.isFinite, wallHeight > 0 {
            cappedHead = Swift.min(head, wallHeight)
        }
        let isDoor = kind == .door || kind == .openDoor
        let newSill: Float = isDoor ? 0 : sill
        guard newSill < cappedHead else { return nil }
        return (newSill, cappedHead)
    }

    /// The wall hosting an opening, anywhere in the model; nil when it has none or the wall is
    /// gone.
    func hostWall(of opening: CleanOpening) -> CleanWall? {
        guard let wallID = opening.wallID, let at = wallLocation(wallID) else { return nil }
        return rooms[at.room].walls[at.index]
    }

    // MARK: - Merge

    /// `mergeRooms`: false when `into` or any listed room is missing (nothing changes). Each
    /// listed room on the same floor as `into` gives its walls, openings and objects to `into`,
    /// its outline and merged outlines to `into.floor.mergedOutlines`, and is removed; rooms on
    /// another floor, `into` itself and duplicates are skipped (logged). `into` keeps its name,
    /// section label, floor elevation and ceiling (a ceiling difference above 5 cm is logged).
    mutating func mergeRooms(_ merged: [ElementID], into: ElementID) -> Bool {
        guard roomIndex(into) != nil else { return false }
        for id in merged where roomIndex(id) == nil { return false }
        var model = self
        var seen: Set<ElementID> = [into]
        for id in merged {
            guard seen.insert(id).inserted else {
                log("mergeRooms: \(id.uuid) listed twice or equal to the target; skipped")
                continue
            }
            guard let target = model.roomIndex(into), let source = model.roomIndex(id) else { continue }
            let room = model.rooms[source]
            let host = model.rooms[target]
            guard room.floorIndex == host.floorIndex else {
                log("mergeRooms: \(id.uuid) is on floor \(room.floorIndex), not \(host.floorIndex); skipped")
                continue
            }
            let ceilingGap = abs(room.ceiling.height - host.ceiling.height)
            if ceilingGap > RoomEditLimits.ceilingDifferenceLog {
                log("mergeRooms: ceilings of \(id.uuid) and \(into.uuid) differ by \(ceilingGap) m; keeping \(host.ceiling.height) m")
            }
            var outlines = host.floor.mergedOutlines ?? []
            if room.floor.outline.count >= 3 { outlines.append(room.floor.outline) }
            outlines.append(contentsOf: (room.floor.mergedOutlines ?? []).filter { $0.count >= 3 })
            model.rooms[target].walls.append(contentsOf: room.walls)
            model.rooms[target].openings.append(contentsOf: room.openings)
            model.rooms[target].objects.append(contentsOf: room.objects)
            if !outlines.isEmpty { model.rooms[target].floor.mergedOutlines = outlines }
            model.rooms.remove(at: source)
        }
        if let target = model.roomIndex(into) { model.refresh(target) }
        self = model
        return true
    }

    // MARK: - Split

    /// `splitRoom`: false when `room` is missing. True unchanged when `newRoom` already exists
    /// (a replay), when `line` has fewer than two points or its first and last points coincide
    /// or are not finite, or when either side holds less than 0.01 square meters (logged).
    /// Every floor part is cut with `Polygon2D.clipped(leftOf: first, last)` for `room` and
    /// `clipped(leftOf: last, first)` for the new room; a side's largest piece becomes its
    /// outline and the others its merged outlines (nil when none). Walls go to the side of their
    /// plan midpoint (on the line: `room`), openings follow their wall (no wall: `room`),
    /// objects follow their center. The new room has `room`'s record, floor, floor elevation,
    /// floor provenance and ceiling, no name, no section label and no RoomPlan identifier, and is
    /// inserted right after `room`.
    mutating func splitRoom(_ id: ElementID, line: [Vec2], newRoom: ElementID) -> Bool {
        guard let r = roomIndex(id) else { return false }
        if roomIndex(newRoom) != nil { return true }
        guard line.count >= 2, let first = line.first?.simd, let last = line.last?.simd,
              first.x.isFinite, first.y.isFinite, last.x.isFinite, last.y.isFinite,
              simd_distance(first, last) > RoomEditLimits.coincidentPoints else {
            log("splitRoom \(id.uuid): split line unusable (\(line.count) points); unchanged")
            return true
        }
        let room = rooms[r]
        let parts = RoomMetricsCalculator.floorParts(of: room)
        let leftPieces = CleanModel.splitPieces(parts, leftOf: first, last)
        let rightPieces = CleanModel.splitPieces(parts, leftOf: last, first)
        let leftArea = CleanModel.totalArea(leftPieces)
        let rightArea = CleanModel.totalArea(rightPieces)
        guard leftArea >= RoomEditLimits.minimumSplitArea, rightArea >= RoomEditLimits.minimumSplitArea,
              let leftFloor = CleanModel.floorRings(leftPieces), let rightFloor = CleanModel.floorRings(rightPieces) else {
            log("splitRoom \(id.uuid): sides of \(leftArea) and \(rightArea) square meters; unchanged")
            return true
        }
        let direction = last - first
        /// True when a plan point is on the left of first -> last or on the line (stays in `room`).
        func staysInRoom(_ p: SIMD2<Float>) -> Bool {
            Segment2D.cross(direction, p - first) >= 0
        }
        var kept = room
        kept.walls = []
        kept.openings = []
        kept.objects = []
        kept.floor.outline = leftFloor.outline
        kept.floor.mergedOutlines = leftFloor.merged
        let newFloor = CleanFloor(outline: rightFloor.outline, elevation: room.floor.elevation, occludedArea: 0,
                                  provenance: room.floor.provenance, mergedOutlines: rightFloor.merged)
        var created = CleanRoom(id: ElementID(uuid: newRoom.uuid), recordID: room.recordID, name: "", sectionLabel: nil,
                                floorIndex: room.floorIndex, walls: [], openings: [], floor: newFloor, ceiling: room.ceiling,
                                objects: [], metrics: .zero)
        for wall in room.walls {
            let middle = (PlanAxes.toPlan(wall.start.simd) + PlanAxes.toPlan(wall.end.simd)) * 0.5
            if staysInRoom(middle) {
                kept.walls.append(wall)
            } else {
                created.walls.append(wall)
            }
        }
        let movedWalls = Set(created.walls.map { $0.id })
        for opening in room.openings {
            if let wallID = opening.wallID, movedWalls.contains(wallID) {
                created.openings.append(opening)
            } else {
                kept.openings.append(opening)
            }
        }
        for object in room.objects {
            if staysInRoom(PlanAxes.toPlan(object.transform.translation)) {
                kept.objects.append(object)
            } else {
                created.objects.append(object)
            }
        }
        rooms[r] = kept
        rooms.insert(created, at: r + 1)
        refresh(r)
        refresh(r + 1)
        log("splitRoom \(id.uuid): \(leftArea) and \(rightArea) square meters, \(created.walls.count) walls to the new room")
        return true
    }

    /// The non-empty pieces of `parts` on the left of the directed line a -> b, one per part
    /// (`Polygon2D.clipped(leftOf:_:)`; a concave part cut into several pieces stays one ring
    /// joined along the line).
    static func splitPieces(_ parts: [[SIMD2<Float>]], leftOf a: SIMD2<Float>, _ b: SIMD2<Float>) -> [[SIMD2<Float>]] {
        parts.compactMap { part in
            let piece = Polygon2D(points: part).clipped(leftOf: a, b)
            return piece.points.count >= 3 ? piece.points : nil
        }
    }

    /// Summed polygon area of rings, square meters.
    static func totalArea(_ rings: [[SIMD2<Float>]]) -> Float {
        rings.reduce(Float(0)) { $0 + Polygon2D(points: $1).area }
    }

    /// The largest ring as the outline (the first one on a tie) and the others, in order, as
    /// merged outlines (nil when there are none); nil for no rings.
    static func floorRings(_ rings: [[SIMD2<Float>]]) -> (outline: [Vec2], merged: [[Vec2]]?)? {
        guard !rings.isEmpty else { return nil }
        var largest = 0
        var largestArea = -Float.greatestFiniteMagnitude
        for (i, ring) in rings.enumerated() {
            let area = Polygon2D(points: ring).area
            if area > largestArea {
                largestArea = area
                largest = i
            }
        }
        let outline: [Vec2] = rings[largest].map { Vec2($0) }
        var others: [[Vec2]] = []
        for (i, ring) in rings.enumerated() where i != largest {
            others.append(ring.map { Vec2($0) })
        }
        let merged: [[Vec2]]? = others.isEmpty ? nil : others
        return (outline, merged)
    }

    // MARK: - Batch and shared helpers

    /// `batch`: the operations applied in order to a copy; the first one that returns false
    /// makes the batch return false and leaves the model unchanged; else the copy replaces the
    /// model and the batch returns true.
    mutating func applyBatch(_ operations: [EditOperation]) -> Bool {
        var copy = self
        for (i, op) in operations.enumerated() {
            guard copy.apply(op) else {
                log("batch: operation \(i + 1) of \(operations.count) has a missing target; batch not applied")
                return false
            }
        }
        self = copy
        return true
    }

    /// Moves every merged-outline vertex of room `r` lying within 1 mm of `old` to `point`
    /// (`moveWallEndpoint`).
    mutating func moveMergedOutlineVertices(room r: Int, from old: SIMD2<Float>, to point: SIMD2<Float>) {
        guard var outlines = rooms[r].floor.mergedOutlines else { return }
        for i in outlines.indices {
            for v in outlines[i].indices where simd_distance(outlines[i][v].simd, old) <= RoomEditLimits.outlineFollowDistance {
                outlines[i][v] = Vec2(point)
            }
        }
        rooms[r].floor.mergedOutlines = outlines
    }

    /// Writes a RoomModel log line.
    private func log(_ message: String) {
        LogStore.shared.write(message, category: RoomOutline.logCategory)
    }
}
