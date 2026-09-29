import Foundation
import simd

// Edit replay on the clean model (D3). `apply` changes geometry and labels and returns false
// only when its target is missing; operations meant for other models (plan annotations and
// dimensions, room alignment, object crop) return true unchanged. Geometric edits refresh the
// room's occlusion and unscaled metrics; `applyingEdits(_:)` recomputes every room at the end
// and re-applies the last active scale correction of each room, so a later geometric edit
// never drops a scale correction.

extension CleanModel: EditApplicable {
    /// Applies one operation (see the file comment for the rules).
    mutating func apply(_ op: EditOperation) -> Bool {
        switch op {
        case .renameRoom(let room, let name):
            guard let r = roomIndex(room) else { return false }
            rooms[r].name = name
            return true
        case .relabelObject(let object, let label):
            guard let at = objectLocation(object) else { return false }
            rooms[at.room].objects[at.index].label = label
            return true
        case .recategorizeObject(let object, let category):
            guard let at = objectLocation(object) else { return false }
            rooms[at.room].objects[at.index].category = category
            refresh(at.room)
            return true
        case .setHidden(let element, let hidden):
            return setHidden(element, hidden: hidden)
        case .deleteElement(let element):
            return delete(element)
        case .moveObject(let object, let transform):
            guard let at = objectLocation(object) else { return false }
            rooms[at.room].objects[at.index].transform = transform
            refresh(at.room)
            return true
        case .moveWallEndpoint(let wall, let atStart, let point):
            return moveWallEndpoint(wall, atStart: atStart, to: point.simd)
        case .addWall(let wall, let level):
            return addWall(wall, level: level)
        case .addOpening(let opening, let level):
            return addOpening(opening, level: level)
        case .setDoorSwing(let door, let swing):
            guard let at = openingLocation(door) else { return false }
            rooms[at.room].openings[at.index].swing = swing
            return true
        case .setWallThickness(let wall, let thickness):
            guard let at = wallLocation(wall) else { return false }
            if thickness.isFinite && thickness >= 0 {
                rooms[at.room].walls[at.index].thickness = thickness
                rooms[at.room].walls[at.index].thicknessSource = .user
            }
            return true
        case .setScaleCorrection(let room, let factor):
            guard let r = roomIndex(room) else { return false }
            guard factor.isFinite, factor > 0 else {
                LogStore.shared.write("scale correction \(factor) ignored for room \(room.uuid)", category: RoomOutline.logCategory)
                return true
            }
            rooms[r].metrics = RoomMetricsCalculator.scaled(RoomMetricsCalculator.metrics(for: rooms[r]), by: factor)
            return true
        case .setRoomAlignment, .cropObject, .addAnnotation, .addDimension:
            return true
        case .moveOpening, .resizeOpening, .mergeRooms, .splitRoom, .batch:
            // CR-1 stubs (pre-5a Core commit): no behavior until the RoomModel revision (3.37b).
            return true
        }
    }

    /// Replays the active operations of `log`, then recomputes occlusion and metrics of every
    /// room and applies each room's last active scale correction. Returns the edited model and
    /// the operations whose target was missing.
    func applyingEdits(_ log: EditLog) -> (model: CleanModel, orphaned: [EditOperation]) {
        let (edited, orphaned) = log.applied(to: self)
        var model = edited
        var factors: [ElementID: Float] = [:]
        for op in log.active {
            if case .setScaleCorrection(let room, let factor) = op, factor.isFinite, factor > 0 {
                factors[room] = factor
            }
        }
        let distance = CleanBuildOptions().occlusionDistance
        for i in model.rooms.indices {
            RoomMetricsCalculator.applyOcclusion(&model.rooms[i], distance: distance)
            var metrics = RoomMetricsCalculator.metrics(for: model.rooms[i])
            if let factor = factors[model.rooms[i].id] {
                metrics = RoomMetricsCalculator.scaled(metrics, by: factor)
            }
            model.rooms[i].metrics = metrics
        }
        return (model, orphaned)
    }

    // MARK: - Lookup

    /// Index of the room with this id.
    func roomIndex(_ id: ElementID) -> Int? {
        rooms.firstIndex { $0.id == id }
    }

    /// Room and wall index of a wall.
    func wallLocation(_ id: ElementID) -> (room: Int, index: Int)? {
        for (r, room) in rooms.enumerated() {
            if let i = room.walls.firstIndex(where: { $0.id == id }) { return (r, i) }
        }
        return nil
    }

    /// Room and opening index of a door, window or opening.
    func openingLocation(_ id: ElementID) -> (room: Int, index: Int)? {
        for (r, room) in rooms.enumerated() {
            if let i = room.openings.firstIndex(where: { $0.id == id }) { return (r, i) }
        }
        return nil
    }

    /// Room and object index of an object.
    func objectLocation(_ id: ElementID) -> (room: Int, index: Int)? {
        for (r, room) in rooms.enumerated() {
            if let i = room.objects.firstIndex(where: { $0.id == id }) { return (r, i) }
        }
        return nil
    }

    // MARK: - Operations

    /// Recomputes a room's occlusion and unscaled metrics after a change.
    private mutating func refresh(_ r: Int) {
        RoomMetricsCalculator.applyOcclusion(&rooms[r], distance: CleanBuildOptions().occlusionDistance)
        rooms[r].metrics = RoomMetricsCalculator.metrics(for: rooms[r])
    }

    /// Hides or shows an object. Walls, openings and rooms have no hidden state in the clean
    /// model, so they return true unchanged; an unknown id returns false.
    private mutating func setHidden(_ element: ElementID, hidden: Bool) -> Bool {
        if let at = objectLocation(element) {
            rooms[at.room].objects[at.index].isHidden = hidden
            return true
        }
        return wallLocation(element) != nil || openingLocation(element) != nil || roomIndex(element) != nil
    }

    /// Deletes a wall (with the openings it hosts), an opening or an object. A room id returns
    /// true unchanged (rooms are not deleted through edits); an unknown id returns false.
    private mutating func delete(_ element: ElementID) -> Bool {
        if let at = wallLocation(element) {
            rooms[at.room].walls.remove(at: at.index)
            rooms[at.room].openings.removeAll { $0.wallID == element }
            refresh(at.room)
            return true
        }
        if let at = openingLocation(element) {
            rooms[at.room].openings.remove(at: at.index)
            refresh(at.room)
            return true
        }
        if let at = objectLocation(element) {
            rooms[at.room].objects.remove(at: at.index)
            refresh(at.room)
            return true
        }
        if roomIndex(element) != nil {
            LogStore.shared.write("deleteElement on room \(element.uuid) ignored by the clean model", category: RoomOutline.logCategory)
            return true
        }
        return false
    }

    /// Moves one end of a wall to a plan point at the room's floor elevation. Outline vertices
    /// at the old end (within 1 mm) move with it so area and perimeter follow; the normal keeps
    /// its side; hosted openings are clamped to the new length.
    private mutating func moveWallEndpoint(_ id: ElementID, atStart: Bool, to point: SIMD2<Float>) -> Bool {
        guard let at = wallLocation(id) else { return false }
        guard point.x.isFinite, point.y.isFinite else { return true }
        var wall = rooms[at.room].walls[at.index]
        let elevation = rooms[at.room].floor.elevation
        let old = PlanAxes.toPlan(atStart ? wall.start.simd : wall.end.simd)
        let moved = Vec3(PlanAxes.toWorld(point, y: elevation))
        if atStart { wall.start = moved } else { wall.end = moved }
        let a = PlanAxes.toPlan(wall.start.simd)
        let b = PlanAxes.toPlan(wall.end.simd)
        let direction = Segment2D(a: a, b: b).direction
        if direction != .zero {
            var planNormal = SIMD2<Float>(-direction.y, direction.x)
            if simd_dot(planNormal, PlanAxes.toPlan(wall.normal.simd)) < 0 { planNormal = -planNormal }
            wall.normal = Vec3(PlanAxes.toWorld(planNormal, y: 0))
        }
        rooms[at.room].walls[at.index] = wall
        for v in rooms[at.room].floor.outline.indices where simd_distance(rooms[at.room].floor.outline[v].simd, old) <= 0.001 {
            rooms[at.room].floor.outline[v] = Vec2(point)
        }
        let length = simd_distance(a, b)
        for o in rooms[at.room].openings.indices where rooms[at.room].openings[o].wallID == id {
            let width = Swift.min(rooms[at.room].openings[o].width, length)
            rooms[at.room].openings[o].width = width
            rooms[at.room].openings[o].offsetAlongWall = Swift.min(Swift.max(0, rooms[at.room].openings[o].offsetAlongWall),
                                                                   Swift.max(0, length - width))
        }
        refresh(at.room)
        return true
    }

    /// Adds a user-drawn wall to the room on `level` whose outline contains its midpoint (else
    /// the room whose outline centroid is nearest). Height is the room's ceiling height. An
    /// existing id returns true unchanged; no room on the level returns false.
    private mutating func addWall(_ planWall: PlanWall, level: Int) -> Bool {
        if wallLocation(planWall.id) != nil { return true }
        let candidates = rooms.indices.filter { rooms[$0].floorIndex == level }
        guard !candidates.isEmpty else { return false }
        let a = planWall.a.simd
        let b = planWall.b.simd
        let middle = (a + b) * 0.5
        var host = candidates[0]
        var bestDistance = Float.greatestFiniteMagnitude
        for r in candidates {
            let outline = Polygon2D(points: rooms[r].floor.outline.map { $0.simd })
            if outline.contains(point: middle) {
                host = r
                break
            }
            let distance = simd_distance(outline.centroid, middle)
            if distance < bestDistance {
                bestDistance = distance
                host = r
            }
        }
        let room = rooms[host]
        let outline = Polygon2D(points: room.floor.outline.map { $0.simd })
        let direction = Segment2D(a: a, b: b).direction
        var planNormal = SIMD2<Float>(-direction.y, direction.x)
        if !outline.contains(point: middle + planNormal * 0.1) && outline.contains(point: middle - planNormal * 0.1) {
            planNormal = -planNormal
        }
        let wall = CleanWall(id: planWall.id,
                             start: Vec3(PlanAxes.toWorld(a, y: room.floor.elevation)),
                             end: Vec3(PlanAxes.toWorld(b, y: room.floor.elevation)),
                             height: room.ceiling.height, normal: Vec3(PlanAxes.toWorld(planNormal, y: 0)),
                             thickness: planWall.thickness, thicknessSource: planWall.thicknessSource, arc: planWall.arc,
                             confidence: .high, completedEdges: 4, occludedSpans: [], provenance: planWall.provenance)
        rooms[host].walls.append(wall)
        refresh(host)
        return true
    }

    /// Adds a door, window or opening on an existing wall with default heights (doors 0 to
    /// 2.03 m, windows 0.9 to 2.1 m, openings 0 to 2.1 m, capped by the wall height), provenance
    /// `.user`. An existing id returns true unchanged; a missing host wall returns false.
    private mutating func addOpening(_ planOpening: PlanOpening, level: Int) -> Bool {
        if openingLocation(planOpening.id) != nil { return true }
        guard let at = wallLocation(planOpening.wallID) else { return false }
        let wall = rooms[at.room].walls[at.index]
        let length = wall.length
        let width = Swift.min(Swift.max(0, planOpening.width), length)
        let offset = Swift.min(Swift.max(0, planOpening.offset), Swift.max(0, length - width))
        let sill: Float
        let head: Float
        switch planOpening.kind {
        case .door, .openDoor:
            sill = 0
            head = 2.03
        case .window:
            sill = 0.9
            head = 2.1
        case .opening:
            sill = 0
            head = 2.1
        }
        let cappedHead = Swift.min(head, wall.height)
        var opening = CleanOpening(id: planOpening.id, wallID: wall.id, kind: planOpening.kind, offsetAlongWall: offset,
                                   width: width, sillHeight: Swift.min(sill, cappedHead), headHeight: cappedHead,
                                   swing: planOpening.swing, provenance: .user)
        if opening.swing == nil && (planOpening.kind == .door || planOpening.kind == .openDoor) {
            let outline = rooms[at.room].floor.outline.map { $0.simd }
            opening.swing = CleanModelBuilder.defaultSwing(opening: opening, wall: wall, outline: outline)
        }
        rooms[at.room].openings.append(opening)
        refresh(at.room)
        if rooms[at.room].floorIndex != level {
            LogStore.shared.write("addOpening level \(level) differs from its wall's floor \(rooms[at.room].floorIndex)",
                                  category: RoomOutline.logCategory)
        }
        return true
    }
}
