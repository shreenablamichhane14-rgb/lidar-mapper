import Foundation
import simd

/// Options for building the clean model.
struct CleanBuildOptions: Equatable, Sendable {
    /// Default thickness of every wall of a single room, meters (`.estimated`).
    var interiorThickness: Float = 0.115
    /// Thickness Structure gives exterior walls in build 5, meters (unused for single rooms).
    var exteriorThickness: Float = 0.15
    /// Keep RoomPlan objects in the clean model ("Find furniture and appliances"); when false
    /// every object is left out (raw keeps them).
    var findFurniture = true
    /// Fraction of the outline area that ceiling (or floor) mesh faces must cover for a
    /// measured height (D13).
    var ceilingCoverageGate: Float = 0.25
    /// Movable objects closer than this to a wall occlude it, meters.
    var occlusionDistance: Float = 0.3

    /// Default options.
    init() {}
}

/// Turns RoomPlan rooms (`RoomInput`) into Mapper's clean architectural model
/// (Representation C). Pure functions, safe on any queue.
enum CleanModelBuilder {
    /// Openings with no usable parent attach to the nearest parallel wall within this distance.
    static let openingAttachDistance: Float = 0.3
    /// A floor polygon differing from the loop area by more than this fraction is logged.
    static let floorMismatchLogLimit: Float = 0.05

    /// One room. `mesh` is the world-space consolidated mesh with faceClass (nil: no mesh terms).
    static func buildRoom(_ input: RoomInput, recordID: UUID, name: String, floorIndex: Int,
                          mesh: MeshWithAttributes?, options: CleanBuildOptions = CleanBuildOptions()) -> CleanRoom {
        let outline = RoomOutline.build(input)
        let geometry: Provenance = input.isProvisional ? .estimated : .measured
        if let mismatch = outline.floorPolygonMismatch, mismatch > floorMismatchLogLimit {
            LogStore.shared.write("room \(recordID): floor polygon differs from the wall loop by \(Int(mismatch * 100)) percent",
                                  category: RoomOutline.logCategory)
        }
        if !outline.isClosed {
            LogStore.shared.write("room \(recordID): wall loop did not close (\(outline.walls.count) walls); outline estimated",
                                  category: RoomOutline.logCategory)
        }
        let polygon = outline.polygon
        let segments = outline.walls + outline.strayWalls

        let floorLevel = floorElevation(input, polygon: polygon, segments: segments, mesh: mesh, gate: options.ceilingCoverageGate)
        let floorProvenance: Provenance = (input.isProvisional || !outline.isClosed) ? .estimated : floorLevel.provenance
        let reference = referencePoint(polygon: polygon, segments: segments)
        var walls: [CleanWall] = []
        var outsideLoop = 0
        var reversedCount = 0
        for (index, segment) in segments.enumerated() {
            let inLoop = outline.isClosed && index < outline.walls.count
            if !inLoop {
                outsideLoop += 1
                if needsReversal(segment, reference: reference) { reversedCount += 1 }
            }
            walls.append(cleanWall(segment, inLoop: inLoop, reference: reference, geometry: geometry, options: options))
        }
        if outsideLoop > 0 {
            LogStore.shared.write("room \(recordID): \(reversedCount) of \(outsideLoop) walls outside the loop reversed (room on the left)",
                                  category: RoomOutline.logCategory)
        }

        let ceiling = ceilingFor(segments: segments, polygon: polygon, floorY: floorLevel.elevation, mesh: mesh,
                                 gate: options.ceilingCoverageGate)
        // Openings attach to the built (possibly reversed) walls, so their offsets and default
        // swings are measured from each wall's final start.
        var openings: [CleanOpening] = []
        for surface in input.openings {
            if let opening = cleanOpening(surface, walls: walls, polygon: polygon, floorY: floorLevel.elevation,
                                          geometry: geometry, roomID: recordID) {
                openings.append(opening)
            }
        }
        var objects: [DetectedObject] = []
        if options.findFurniture {
            objects = input.objects.map { object in
                DetectedObject(id: ElementID.derived(fromRoomPlan: object.identifier), category: object.category, label: "",
                               transform: object.transform, dimensions: object.dimensions, confidence: object.confidence,
                               isHidden: false, provenance: geometry)
            }
        }
        let floor = CleanFloor(outline: polygon.map { Vec2($0) }, elevation: floorLevel.elevation, occludedArea: 0,
                               provenance: floorProvenance)
        var room = CleanRoom(id: ElementID(uuid: recordID, roomPlanID: input.identifier), recordID: recordID, name: name,
                             sectionLabel: sectionLabel(input, polygon: polygon), floorIndex: floorIndex, walls: walls,
                             openings: openings, floor: floor, ceiling: ceiling, objects: objects, metrics: .zero)
        RoomMetricsCalculator.applyOcclusion(&room, distance: options.occlusionDistance)
        room.metrics = RoomMetricsCalculator.metrics(for: room)
        return room
    }

    /// Every room with its record; `meshes` by `RoomRecord.id`.
    static func buildModel(_ rooms: [(input: RoomInput, record: RoomRecord)], meshes: [UUID: MeshWithAttributes],
                           options: CleanBuildOptions = CleanBuildOptions()) -> CleanModel {
        let built = rooms.map { entry in
            buildRoom(entry.input, recordID: entry.record.id, name: entry.record.name, floorIndex: entry.record.floorIndex,
                      mesh: meshes[entry.record.id], options: options)
        }
        return CleanModel(rooms: built, sourceIsStructure: false, stamp: nil)
    }

    /// Hinge at the end nearer a wall corner; opens toward the room normal; source .estimated.
    /// "Opens toward the room normal" means into the room: `opensToNormalSide` is false only
    /// when the point 0.3 m in front of the door lies outside the outline and the point behind
    /// it lies inside.
    static func defaultSwing(opening: CleanOpening, wall: CleanWall, outline: [SIMD2<Float>]) -> DoorSwing {
        let a = PlanAxes.toPlan(wall.start.simd)
        let b = PlanAxes.toPlan(wall.end.simd)
        let direction = Segment2D(a: a, b: b).direction
        let near = a + direction * opening.offsetAlongWall
        let far = a + direction * (opening.offsetAlongWall + opening.width)
        let corners = outline.count >= 3 ? outline : [a, b]
        let nearDistance = corners.map { simd_distance($0, near) }.min() ?? 0
        let farDistance = corners.map { simd_distance($0, far) }.min() ?? 0
        var opensToNormal = true
        if outline.count >= 3 {
            let normal = PlanAxes.toPlan(wall.normal.simd)
            let length = simd_length(normal)
            if length > 1e-6 {
                let unit = normal / length
                let middle = (near + far) * 0.5
                let polygon = Polygon2D(points: outline)
                let front = polygon.contains(point: middle + unit * 0.3)
                let back = polygon.contains(point: middle - unit * 0.3)
                opensToNormal = front || !back
            }
        }
        return DoorSwing(hingeAtStart: nearDistance <= farDistance, opensToNormalSide: opensToNormal, source: .estimated)
    }

    // MARK: - Pieces

    /// Floor elevation (D13): mesh floor faces when they pass the gate (`.measured`), else the
    /// first RoomPlan floor's Y, else the lowest wall base (`.estimated`).
    static func floorElevation(_ input: RoomInput, polygon: [SIMD2<Float>], segments: [WallSegment],
                               mesh: MeshWithAttributes?, gate: Float) -> (elevation: Float, provenance: Provenance) {
        if let mesh, let measured = RoomMetricsCalculator.floorFromMesh(mesh, outline: polygon, gate: gate) {
            return (measured.elevation, .measured)
        }
        if let floorY = input.floors.first?.transform.translation.y, floorY.isFinite {
            return (floorY, .estimated)
        }
        if let lowest = segments.map({ $0.baseY }).min() {
            return (lowest, .estimated)
        }
        return (0, .estimated)
    }

    /// Ceiling (D13): mesh ceiling faces when they pass the gate (`.measured`), else the highest
    /// wall top above the floor among high-confidence walls (all walls when none is high),
    /// `.estimated`.
    static func ceilingFor(segments: [WallSegment], polygon: [SIMD2<Float>], floorY: Float,
                           mesh: MeshWithAttributes?, gate: Float) -> CleanCeiling {
        if let mesh, let measured = RoomMetricsCalculator.ceilingFromMesh(mesh, outline: polygon, floorY: floorY, gate: gate) {
            return CleanCeiling(height: measured.height, provenance: .measured)
        }
        let confident = segments.filter { $0.confidence == .high }
        let candidates = confident.isEmpty ? segments : confident
        let top = candidates.map { $0.baseY + $0.height }.max()
        let tallest = candidates.map { $0.height }.max() ?? 0
        var height = (top ?? floorY) - floorY
        if !(height > 0.1) || !height.isFinite { height = tallest }
        return CleanCeiling(height: Swift.max(0, height), provenance: .estimated)
    }

    /// A point inside the room used to orient walls outside the loop: the outline centroid, or
    /// the mean wall midpoint.
    static func referencePoint(polygon: [SIMD2<Float>], segments: [WallSegment]) -> SIMD2<Float> {
        if polygon.count >= 3 { return Polygon2D(points: polygon).centroid }
        guard !segments.isEmpty else { return .zero }
        let sum = segments.reduce(SIMD2<Float>.zero) { $0 + ($1.start + $1.end) * 0.5 }
        return sum / Float(segments.count)
    }

    /// A clean wall from a segment, satisfying the orientation invariant (CR-1, 3.37b): the room
    /// is on the left of start -> end and the normal is always the left perpendicular. Loop walls
    /// are unchanged (counter-clockwise loop, room on the left); a wall outside the loop whose
    /// left perpendicular points away from `reference` is reversed (`WallSegment.reversed`:
    /// start and end swapped, arc unchanged).
    static func cleanWall(_ segment: WallSegment, inLoop: Bool, reference: SIMD2<Float>, geometry: Provenance,
                          options: CleanBuildOptions) -> CleanWall {
        let oriented = (!inLoop && needsReversal(segment, reference: reference)) ? segment.reversed : segment
        let normal = PlanAxes.toWorld(leftNormal(oriented), y: 0)
        return CleanWall(id: oriented.id,
                         start: Vec3(PlanAxes.toWorld(oriented.start, y: oriented.baseY)),
                         end: Vec3(PlanAxes.toWorld(oriented.end, y: oriented.baseY)),
                         height: oriented.height, normal: Vec3(normal), thickness: options.interiorThickness,
                         thicknessSource: .estimated, arc: oriented.arc, confidence: oriented.confidence,
                         completedEdges: oriented.completedEdges, occludedSpans: [], provenance: geometry)
    }

    /// Unit left perpendicular of a segment's start -> end in plan coordinates (zero for a
    /// degenerate segment).
    static func leftNormal(_ segment: WallSegment) -> SIMD2<Float> {
        let d = segment.direction
        return SIMD2<Float>(-d.y, d.x)
    }

    /// True when a wall outside the loop must be reversed to put `reference` (a point inside
    /// the room) on its left: `simd_dot(leftNormal, reference - middle) < 0`.
    static func needsReversal(_ segment: WallSegment, reference: SIMD2<Float>) -> Bool {
        let middle = (segment.start + segment.end) * 0.5
        return simd_dot(leftNormal(segment), reference - middle) < 0
    }

    /// A clean opening: attached by `parentIdentifier`, else to the nearest parallel wall within
    /// `openingAttachDistance`; ends projected onto the wall and clamped; sill and head relative
    /// to the floor (doors have sill 0); doors get the default swing. Nil for walls and floors.
    static func cleanOpening(_ surface: SurfaceInput, walls: [CleanWall], polygon: [SIMD2<Float>], floorY: Float,
                             geometry: Provenance, roomID: UUID) -> CleanOpening? {
        guard let kind = surface.kind.openingKind else { return nil }
        let centerY = surface.transform.translation.y
        let halfHeight = surface.dimensions.y * 0.5
        let head = Swift.max(0, centerY + halfHeight - floorY)
        let sill = surface.kind.isDoor ? 0 : Swift.min(head, Swift.max(0, centerY - halfHeight - floorY))
        let id = ElementID.derived(fromRoomPlan: surface.identifier)
        guard let ends = RoomOutline.surfaceEndpoints(surface) else {
            LogStore.shared.write("room \(roomID): opening \(surface.identifier) skipped, degenerate transform",
                                  category: RoomOutline.logCategory)
            return nil
        }
        var hostIndex: Int?
        if let parent = surface.parentIdentifier {
            hostIndex = walls.firstIndex { $0.id.roomPlanID == parent }
        }
        if hostIndex == nil {
            hostIndex = nearestParallelWall(start: ends.start, end: ends.end, walls: walls)
        }
        guard let host = hostIndex else {
            LogStore.shared.write("room \(roomID): opening \(surface.identifier) has no wall within \(openingAttachDistance) m",
                                  category: RoomOutline.logCategory)
            return CleanOpening(id: id, wallID: nil, kind: kind, offsetAlongWall: 0, width: Swift.max(0, surface.dimensions.x),
                                sillHeight: sill, headHeight: head, swing: nil, provenance: geometry)
        }
        let wall = walls[host]
        let a = PlanAxes.toPlan(wall.start.simd)
        let b = PlanAxes.toPlan(wall.end.simd)
        let length = simd_distance(a, b)
        let direction = Segment2D(a: a, b: b).direction
        let t0 = simd_dot(ends.start - a, direction)
        let t1 = simd_dot(ends.end - a, direction)
        var near = Swift.min(Swift.max(Swift.min(t0, t1), 0), length)
        var far = Swift.min(Swift.max(Swift.max(t0, t1), 0), length)
        if far - near < 0.01 {
            let width = Swift.min(Swift.max(0, surface.dimensions.x), length)
            near = Swift.min(Swift.max(Swift.min(t0, t1), 0), length - width)
            far = near + width
        }
        var opening = CleanOpening(id: id, wallID: wall.id, kind: kind, offsetAlongWall: near, width: far - near,
                                   sillHeight: sill, headHeight: head, swing: nil, provenance: geometry)
        if surface.kind.isDoor {
            opening.swing = defaultSwing(opening: opening, wall: wall, outline: polygon)
        }
        return opening
    }

    /// Index of the wall parallel to the opening (within `RoomOutline.parallelLimitDegrees`)
    /// whose line is nearest to the opening center and at most `openingAttachDistance` away,
    /// with the center inside the wall's extent (plus the same slack).
    static func nearestParallelWall(start: SIMD2<Float>, end: SIMD2<Float>, walls: [CleanWall]) -> Int? {
        let opening = Segment2D(a: start, b: end)
        guard opening.length > 1e-4 else { return nil }
        let center = (start + end) * 0.5
        let limit = RoomOutline.parallelLimitDegrees * Float.pi / 180
        var best: (index: Int, distance: Float)?
        for (index, wall) in walls.enumerated() {
            let a = PlanAxes.toPlan(wall.start.simd)
            let b = PlanAxes.toPlan(wall.end.simd)
            let line = Segment2D(a: a, b: b)
            guard line.length > 1e-4 else { continue }
            let angle = line.angle(between: opening)
            guard angle <= limit || angle >= Float.pi - limit else { continue }
            let direction = line.direction
            let along = simd_dot(center - a, direction)
            let distance = abs(Segment2D.cross(direction, center - a))
            let slack = openingAttachDistance
            guard distance <= openingAttachDistance, along >= -slack, along <= line.length + slack else { continue }
            if let current = best, current.distance <= distance { continue }
            best = (index, distance)
        }
        return best?.index
    }

    /// Label of the first identified section whose center lies inside the outline (the only
    /// identified section when there is no outline); nil otherwise.
    static func sectionLabel(_ input: RoomInput, polygon: [SIMD2<Float>]) -> String? {
        let identified = input.sections.filter { $0.label != RoomInput.unidentifiedSectionLabel && !$0.label.isEmpty }
        guard polygon.count >= 3 else { return identified.count == 1 ? identified[0].label : nil }
        let outline = Polygon2D(points: polygon)
        let inside = identified.first(where: { outline.contains(point: PlanAxes.toPlan($0.center.simd)) })
        return inside?.label
    }
}
