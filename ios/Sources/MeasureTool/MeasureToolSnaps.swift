import Foundation
import CoreGraphics
import simd

/// Pure logic of the tools: the snap context, point resolution, room lookup and evidence
/// (this file); values, records and flags (MeasureToolSnaps+Values.swift). Nonisolated, any queue.
enum MeasureToolSnaps {
    /// Mesh vertex snap radius, meters.
    static let meshVertexRadius: Float = 0.02
    /// A tap this close on screen to the first area point closes the area, points.
    static let closeRadiusPoints: CGFloat = 24
    /// Most points of one area.
    static let maximumAreaPoints = 50
    /// A floor at most this far above a point still holds it (`room(containing:in:)`), meters.
    static let floorAbovePointTolerance: Float = 0.5
    /// A floor at most this far above a point is preferred as the point's own floor, meters.
    static let ownFloorTolerance: Float = 0.05
    /// Wall tool: a tap this close to a wall (plan distance, and within its height) picks it, meters.
    static let wallPickRadius: Float = 0.10

    // MARK: - Context

    /// The context: `SnapSet.build(from:includeObjects: true)` of every room (movable objects removed
    /// from a copy of the room first when `excludeMovable`), plus, for each `floor.mergedOutlines` entry
    /// (CR-1), a set built from a copy of the room whose floor outline is that part and whose walls,
    /// openings and objects are empty (its floor and ceiling planes), all joined with `combined(_:)`;
    /// `wallEvidence` from every room's evidence (rooms in UUID order, the first entry of a wall wins).
    static func context(model: CleanModel, evidence: [UUID: RoomEvidence], excludeMovable: Bool) -> MeasureToolContext {
        var sets: [SnapSet] = []
        for room in model.rooms {
            var copy = room
            if excludeMovable {
                copy.objects = room.objects.filter { !$0.isMovable }
            }
            sets.append(SnapSet.build(from: copy, includeObjects: true))
            for part in room.floor.mergedOutlines ?? [] where part.count >= 3 {
                var piece = room
                piece.walls = []
                piece.openings = []
                piece.objects = []
                piece.floor.outline = part
                piece.floor.mergedOutlines = nil
                sets.append(SnapSet.build(from: piece, includeObjects: false))
            }
        }
        var walls: [ElementID: WallEvidence] = [:]
        let keys = evidence.keys.sorted { $0.uuidString < $1.uuidString }
        for key in keys {
            guard let roomEvidence = evidence[key] else { continue }
            for wall in roomEvidence.walls where walls[wall.wallID] == nil {
                walls[wall.wallID] = wall
            }
        }
        return MeasureToolContext(model: model, snaps: combined(sets), roomEvidence: evidence, wallEvidence: walls)
    }

    /// The candidates of several sets in order, with every parallel array kept in step. A set whose
    /// optional arrays are shorter than its candidates is padded (element nil; feature `.corner`,
    /// `.edge` or `.wall`; region nil); longer arrays are cut to the candidate count.
    static func combined(_ sets: [SnapSet]) -> SnapSet {
        var out = SnapSet.empty
        for set in sets {
            let corners = set.corners.count
            out.corners.append(contentsOf: set.corners)
            out.cornerElements.append(contentsOf: fitted(set.cornerElements, corners, pad: nil))
            out.cornerFeatures.append(contentsOf: fitted(set.cornerFeatures, corners, pad: .corner))
            let edges = set.edges.count
            out.edges.append(contentsOf: set.edges)
            out.edgeElements.append(contentsOf: fitted(set.edgeElements, edges, pad: nil))
            out.edgeFeatures.append(contentsOf: fitted(set.edgeFeatures, edges, pad: .edge))
            let planes = set.planes.count
            out.planes.append(contentsOf: set.planes)
            out.planeElements.append(contentsOf: fitted(set.planeElements, planes, pad: nil))
            out.planeFeatures.append(contentsOf: fitted(set.planeFeatures, planes, pad: .wall))
            out.planeRegions.append(contentsOf: fitted(set.planeRegions, planes, pad: nil))
        }
        return out
    }

    /// `array` cut or padded with `pad` to exactly `count` entries.
    private static func fitted<T>(_ array: [T], _ count: Int, pad: T) -> [T] {
        if array.count == count { return array }
        if array.count > count { return Array(array.prefix(count)) }
        return array + [T](repeating: pad, count: count - array.count)
    }

    // MARK: - Points

    /// A tapped point. With snapping on: `context.snaps.hit(hit.position)` when its kind is not `.none`;
    /// else for a `.rawMesh` pick tag the nearest corner of triangle `hit.triangle` of the part
    /// `hit.partID` in `parts` within `meshVertexRadius` (`.meshVertex`), else `.meshSurface`; for an
    /// `.element(id)` pick tag (3D Clean surfaces are RoomPlan surfaces) `.plane` with that element.
    /// With snapping off: `.meshSurface` or `.plane` at `hit.position`, no feature (an element
    /// tag keeps its element, so the point still gets that wall's evidence).
    static func resolve(_ hit: ViewerHit, parts: [ViewerPart], context: MeasureToolContext,
                        snapping: Bool) -> MeasureToolPoint {
        let position = hit.position
        if !snapping {
            if case .element(let id)? = hit.pickTag {
                return MeasureToolPoint(position: position, snap: .plane, feature: nil, element: id)
            }
            return MeasureToolPoint(position: position, snap: .meshSurface)
        }
        let snapped = context.snaps.hit(position)
        if snapped.kind != SnapKind.none {
            return MeasureToolPoint(position: snapped.point, snap: snapped.kind, feature: snapped.feature,
                                    element: snapped.element)
        }
        switch hit.pickTag {
        case .element(let id)?:
            return MeasureToolPoint(position: position, snap: .plane, feature: nil, element: id)
        case .rawMesh?, nil:
            if let vertex = nearestTriangleCorner(hit, parts: parts) {
                return MeasureToolPoint(position: vertex, snap: .meshVertex)
            }
            return MeasureToolPoint(position: position, snap: .meshSurface)
        }
    }

    /// The corner of the hit triangle nearest to the hit, when within `meshVertexRadius`.
    static func nearestTriangleCorner(_ hit: ViewerHit, parts: [ViewerPart]) -> SIMD3<Float>? {
        guard let part = parts.first(where: { $0.id == hit.partID }), hit.triangle >= 0 else { return nil }
        let base = hit.triangle * 3
        guard base + 2 < part.indices.count else { return nil }
        var best: SIMD3<Float>?
        var bestDistance = meshVertexRadius
        for k in 0..<3 {
            let index = Int(part.indices[base + k])
            guard index >= 0, index < part.positions.count else { continue }
            let corner = part.positions[index]
            let d = simd_distance(corner, hit.position)
            if d.isFinite, d <= bestDistance {
                bestDistance = d
                best = corner
            }
        }
        return best
    }

    // MARK: - Rooms

    /// The room whose floor outline or merged outline contains the point in plan (`PlanAxes`), among
    /// rooms whose floor elevation is at most 0.5 m above the point (the highest floor not above the
    /// point by more than 5 cm first, so a ceiling point stays in the room below a stacked room);
    /// else the room with the nearest outline centroid (plan distance plus the height above or
    /// below its floor); nil without rooms.
    static func room(containing point: SIMD3<Float>, in model: CleanModel) -> CleanRoom? {
        guard !model.rooms.isEmpty else { return nil }
        let plan = PlanAxes.toPlan(point)
        var own: CleanRoom?
        var ownElevation = -Float.greatestFiniteMagnitude
        var other: CleanRoom?
        var otherElevation = Float.greatestFiniteMagnitude
        for room in model.rooms where contains(plan, room: room) {
            let elevation = room.floor.elevation
            guard elevation.isFinite, elevation <= point.y + floorAbovePointTolerance else { continue }
            if elevation <= point.y + ownFloorTolerance {
                if elevation > ownElevation {
                    own = room
                    ownElevation = elevation
                }
            } else if elevation < otherElevation {
                other = room
                otherElevation = elevation
            }
        }
        if let found = own ?? other { return found }
        return nearestRoom(to: point, in: model)
    }

    /// True when a plan point lies inside the room's outline or one of its merged outlines.
    static func contains(_ plan: SIMD2<Float>, room: CleanRoom) -> Bool {
        let outline = MeasureRoomSizes.outlinePoints(room)
        if outline.count >= 3, Polygon2D(points: outline).contains(point: plan) { return true }
        for part in room.floor.mergedOutlines ?? [] where part.count >= 3 {
            if Polygon2D(points: part.map { $0.simd }).contains(point: plan) { return true }
        }
        return false
    }

    /// The room whose outline centroid (at floor height) is nearest to the point; the first room
    /// when no room has an outline.
    private static func nearestRoom(to point: SIMD3<Float>, in model: CleanModel) -> CleanRoom? {
        var best: CleanRoom?
        var bestDistance = Float.greatestFiniteMagnitude
        for room in model.rooms {
            let outline = MeasureRoomSizes.outlinePoints(room)
            guard outline.count >= 1 else { continue }
            let centroid = outline.count >= 3 ? Polygon2D(points: outline).centroid : outline[0]
            let elevation = room.floor.elevation.isFinite ? room.floor.elevation : point.y
            let center = PlanAxes.toWorld(centroid, y: elevation)
            let d = simd_distance_squared(center, point)
            if d.isFinite, d < bestDistance {
                bestDistance = d
                best = room
            }
        }
        return best ?? model.rooms.first
    }

    /// The room holding the wall `id`, if any.
    static func room(ofWall id: ElementID, in model: CleanModel) -> CleanRoom? {
        model.rooms.first { room in room.walls.contains { $0.id == id } }
    }

    /// The wall `id`, if it is in the model.
    static func wall(_ id: ElementID, in model: CleanModel) -> CleanWall? {
        for room in model.rooms {
            if let wall = room.walls.first(where: { $0.id == id }) { return wall }
        }
        return nil
    }

    /// The opening `id`, if it is in the model.
    static func opening(_ id: ElementID, in model: CleanModel) -> CleanOpening? {
        for room in model.rooms {
            if let opening = room.openings.first(where: { $0.id == id }) { return opening }
        }
        return nil
    }

    // MARK: - Evidence

    /// Coverage evidence of one endpoint through `ConfidenceAdapter.evidence(distance:observations:room:snap:)`:
    /// the WallEvidence of the snapped wall (an opening uses its host wall), else the point's room
    /// `typicalWall`, else the ConfidenceAdapter defaults; room evidence of the point's room
    /// (`RoomEvidence.unknown` without); snap `ConfidenceAdapter.measurementSnapKind(point.snap)`.
    static func evidence(for point: MeasureToolPoint, context: MeasureToolContext) -> MeasurementEvidence {
        let owner = room(containing: point.position, in: context.model)
        let roomEvidence = owner.flatMap { context.roomEvidence[$0.recordID] } ?? RoomEvidence.unknown
        let snap = ConfidenceAdapter.measurementSnapKind(point.snap)
        if let wall = wallEvidence(for: point.element, context: context) {
            return ConfidenceAdapter.evidence(distance: wall.medianDistance, observations: wall.observations,
                                              room: roomEvidence, snap: snap)
        }
        let typical = roomEvidence.typicalWall
        return ConfidenceAdapter.evidence(distance: typical?.distance, observations: typical?.observations,
                                          room: roomEvidence, snap: snap)
    }

    /// The WallEvidence of a wall element, or of the host wall of an opening element.
    static func wallEvidence(for element: ElementID?, context: MeasureToolContext) -> WallEvidence? {
        guard let id = element else { return nil }
        if let direct = context.wallEvidence[id] { return direct }
        if let opening = opening(id, in: context.model), let host = opening.wallID {
            return context.wallEvidence[host]
        }
        return nil
    }

    // MARK: - Wall tool

    /// The wall a Wall-tool tap refers to: an `.element` pick tag of a wall, the host wall of a picked
    /// opening, or a SnapSet hit whose feature is `.wall`; nil otherwise. For taps on the scan
    /// (`.rawMesh`) a wall whose base line (or arc) is within `wallPickRadius` in plan and whose
    /// height span holds the point also counts, so a tap near a wall's edge or on a curved wall
    /// (curved walls have no snap plane) still finds it.
    static func wall(for hit: ViewerHit, context: MeasureToolContext) -> CleanWall? {
        let model = context.model
        if case .element(let id)? = hit.pickTag {
            if let wall = wall(id, in: model) { return wall }
            if let opening = opening(id, in: model), let host = opening.wallID {
                return wall(host, in: model)
            }
            return nil
        }
        let snapped = context.snaps.hit(hit.position)
        if snapped.feature == .wall, let id = snapped.element, let wall = wall(id, in: model) {
            return wall
        }
        return nearestWall(to: hit.position, in: model)
    }

    /// The wall nearest to a point within `wallPickRadius` in plan and within its height (plus the
    /// same margin), or nil.
    static func nearestWall(to point: SIMD3<Float>, in model: CleanModel) -> CleanWall? {
        let plan = PlanAxes.toPlan(point)
        var best: CleanWall?
        var bestDistance = wallPickRadius
        for room in model.rooms {
            for wall in room.walls {
                let base = wall.start.y
                let top = base + max(0, wall.height)
                guard point.y >= base - wallPickRadius, point.y <= top + wallPickRadius else { continue }
                let d = planDistance(plan, to: wall)
                if d.isFinite, d <= bestDistance {
                    bestDistance = d
                    best = wall
                }
            }
        }
        return best
    }

    /// Plan distance from a point to a wall's base: the segment for straight walls, the arc for curved ones.
    static func planDistance(_ plan: SIMD2<Float>, to wall: CleanWall) -> Float {
        let a = PlanAxes.toPlan(wall.start.simd)
        let b = PlanAxes.toPlan(wall.end.simd)
        let chord = Segment2D(a: a, b: b).distance(to: plan)
        guard let arc = wall.arc, arc.radius.isFinite, arc.radius > 0, arc.startAngle.isFinite,
              arc.endAngle.isFinite else { return chord }
        let center = PlanAxes.toPlan(arc.center.simd)
        let offset = plan - center
        let twoPi: Float = 2 * Float.pi
        var sweep = (atan2(offset.y, offset.x) - arc.startAngle).truncatingRemainder(dividingBy: twoPi)
        if sweep < 0 { sweep += twoPi }
        guard sweep <= arc.endAngle - arc.startAngle else { return chord }
        let radial: Float = abs(simd_length(offset) - arc.radius)
        return min(radial, chord)
    }
}
