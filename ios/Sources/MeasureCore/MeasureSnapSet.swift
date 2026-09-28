import Foundation
import simd

/// What a snap candidate belongs to, in the SPEC's snapping list order ("corner, wall, edge,
/// floor, ceiling, door, window, object edge", `Copy.Measure.snapTargets`).
enum SnapSetFeature: Int, CaseIterable, Sendable {
    case corner = 0, wall, edge, floor, ceiling, door, window, objectEdge

    /// The target word for "Snapped to {target}" (`Copy.Measure.snapTargets`), or nil if missing.
    var targetName: String? {
        let names = Copy.Measure.snapTargets
        return rawValue < names.count ? names[rawValue] : nil
    }

    /// "Snapped to door" (`Copy.Measure.snapped(to:)`), or nil if the name is missing.
    var snappedText: String? {
        targetName.map { Copy.Measure.snapped(to: $0) }
    }
}

/// The finite region of a snap plane, so a point near the infinite extension of a wall (for
/// example across an L-shaped room) does not snap to it.
enum SnapSetPlaneRegion: Equatable {
    /// A rectangle from `origin` spanning `lengthU` along unit `axisU` and `lengthV` along unit `axisV`.
    case rectangle(origin: SIMD3<Float>, axisU: SIMD3<Float>, lengthU: Float, axisV: SIMD3<Float>, lengthV: Float)
    /// A polygon in plan coordinates (`PlanAxes`), for the floor and the ceiling.
    case outline([SIMD2<Float>])

    /// True when `p` (already on the plane) lies inside the region or within `margin` of it.
    func contains(_ p: SIMD3<Float>, margin: Float) -> Bool {
        switch self {
        case let .rectangle(origin, axisU, lengthU, axisV, lengthV):
            let d = p - origin
            let u = simd_dot(d, axisU)
            let v = simd_dot(d, axisV)
            let insideU = u >= -margin && u <= lengthU + margin
            let insideV = v >= -margin && v <= lengthV + margin
            return insideU && insideV
        case let .outline(points):
            guard points.count >= 3 else { return true }
            let q = PlanAxes.toPlan(p)
            if Polygon2D(points: points).contains(point: q) { return true }
            for i in 0..<points.count {
                let edge = Segment2D(a: points[i], b: points[(i + 1) % points.count])
                if edge.distance(to: q) <= margin { return true }
            }
            return false
        }
    }
}

/// A snap with what it attached to.
struct SnapSetHit: Equatable {
    /// Snapped point (the input point when nothing was in range), world meters.
    var point: SIMD3<Float>
    /// Core snap kind stored in `MeasurementRecord.snaps`.
    var kind: SnapKind
    /// What the candidate belongs to, nil for `.none`.
    var feature: SnapSetFeature?
    /// The wall, opening or object the candidate came from, when known.
    var element: ElementID?
}

/// Snap candidates from the clean model (world meters), in priority order corner, edge, plane.
///
/// Corners: wall-wall-floor and wall-wall-ceiling corners, opening corners, then object box
/// corners. Edges: wall bottom, top and vertical edges, opening edges, object box edges.
/// Planes: floor, ceiling, then each straight wall, each limited to its own region. Curved walls
/// give corners only (their surface is not a plane). The parallel arrays (`cornerFeatures`,
/// `edgeElements`, ...) default to empty; a missing entry means "unknown" and an unbounded plane.
struct SnapSet: Equatable {
    /// Corner candidates and the element each came from.
    var corners: [SIMD3<Float>]; var cornerElements: [ElementID?]
    /// Edge candidates (3D segments).
    var edges: [(SIMD3<Float>, SIMD3<Float>)]
    /// Plane candidates.
    var planes: [Plane]
    /// Feature of each corner.
    var cornerFeatures: [SnapSetFeature] = []
    /// Element and feature of each edge.
    var edgeElements: [ElementID?] = []
    var edgeFeatures: [SnapSetFeature] = []
    /// Element, feature and finite region of each plane.
    var planeElements: [ElementID?] = []
    var planeFeatures: [SnapSetFeature] = []
    var planeRegions: [SnapSetPlaneRegion?] = []

    /// Snap radii, meters (docs/ARCHITECTURE.md 8.4; RESEARCH: 10 cm world radius for corners).
    static let cornerRadius: Float = 0.10
    static let edgeRadius: Float = 0.05
    static let planeRadius: Float = 0.05
    /// Corners closer than this are the same corner, meters.
    static let mergeDistance: Float = 0.01

    /// An empty set.
    static let empty = SnapSet(corners: [], cornerElements: [], edges: [], planes: [])

    /// Candidates of `room`; objects (not hidden) are added when `includeObjects` is true.
    static func build(from room: CleanRoom, includeObjects: Bool) -> SnapSet {
        var builder = SnapSetBuilder()
        builder.addRoom(room)
        if includeObjects {
            for object in room.objects where !object.isHidden {
                builder.addObject(object)
            }
        }
        return builder.result
    }

    /// Geometry `Snap.best` with radii 0.10 corner, 0.05 edge, 0.05 plane; maps the target to Core SnapKind.
    func snap(_ point: SIMD3<Float>) -> (point: SIMD3<Float>, kind: SnapKind) {
        let result = hit(point)
        return (result.point, result.kind)
    }

    /// `snap(_:)` with the feature and element the point attached to.
    func hit(_ point: SIMD3<Float>) -> SnapSetHit {
        var candidates: [Plane] = []
        var candidateIndex: [Int] = []
        for (i, plane) in planes.enumerated() {
            if i < planeRegions.count, let region = planeRegions[i],
               !region.contains(plane.project(point), margin: SnapSet.planeRadius) {
                continue
            }
            candidates.append(plane)
            candidateIndex.append(i)
        }
        let result = Snap.best(point, corners: corners, edges: edges, planes: candidates,
                               cornerRadius: SnapSet.cornerRadius, edgeRadius: SnapSet.edgeRadius,
                               planeRadius: SnapSet.planeRadius)
        switch result.target {
        case .corner(let i):
            return SnapSetHit(point: result.point, kind: .corner,
                              feature: SnapSet.entry(cornerFeatures, i),
                              element: SnapSet.entry(cornerElements, i) ?? nil)
        case .edge(let i):
            return SnapSetHit(point: result.point, kind: .edge,
                              feature: SnapSet.entry(edgeFeatures, i),
                              element: SnapSet.entry(edgeElements, i) ?? nil)
        case .plane(let j):
            let i = j < candidateIndex.count ? candidateIndex[j] : -1
            return SnapSetHit(point: result.point, kind: .plane,
                              feature: SnapSet.entry(planeFeatures, i),
                              element: SnapSet.entry(planeElements, i) ?? nil)
        case .none:
            return SnapSetHit(point: point, kind: SnapKind.none, feature: nil, element: nil)
        }
    }

    /// Equal when every candidate and every parallel array match.
    static func == (lhs: SnapSet, rhs: SnapSet) -> Bool {
        guard lhs.corners == rhs.corners, lhs.cornerElements == rhs.cornerElements,
              lhs.planes == rhs.planes, lhs.edges.count == rhs.edges.count,
              lhs.cornerFeatures == rhs.cornerFeatures, lhs.edgeElements == rhs.edgeElements,
              lhs.edgeFeatures == rhs.edgeFeatures, lhs.planeElements == rhs.planeElements,
              lhs.planeFeatures == rhs.planeFeatures, lhs.planeRegions == rhs.planeRegions else { return false }
        for (a, b) in zip(lhs.edges, rhs.edges) where a.0 != b.0 || a.1 != b.1 {
            return false
        }
        return true
    }

    /// The element at `index`, or nil when out of range.
    private static func entry<T>(_ array: [T], _ index: Int) -> T? {
        index >= 0 && index < array.count ? array[index] : nil
    }
}

/// Collects the candidates of a `SnapSet` with their parallel arrays in step.
private struct SnapSetBuilder {
    /// The set being built.
    var result = SnapSet.empty

    /// Walls, openings, floor and ceiling of a room.
    mutating func addRoom(_ room: CleanRoom) {
        let up = SIMD3<Float>(0, 1, 0)
        for wall in room.walls {
            let start = wall.start.simd
            let end = wall.end.simd
            let height = max(0, wall.height)
            guard SnapSetBuilder.isFinite(start), SnapSetBuilder.isFinite(end), height.isFinite else { continue }
            let top = up * height
            addCorner(start, feature: .corner, element: wall.id)
            addCorner(end, feature: .corner, element: wall.id)
            addCorner(start + top, feature: .corner, element: wall.id)
            addCorner(end + top, feature: .corner, element: wall.id)
            addEdge(start, start + top, feature: .edge, element: wall.id)
            addEdge(end, end + top, feature: .edge, element: wall.id)
            guard wall.arc == nil else { continue }
            addEdge(start, end, feature: .edge, element: wall.id)
            addEdge(start + top, end + top, feature: .edge, element: wall.id)
        }
        for opening in room.openings {
            addOpening(opening, walls: room.walls)
        }
        addFloorAndCeiling(room)
        for wall in room.walls where wall.arc == nil {
            addWallPlane(wall)
        }
    }

    /// The four corners and edges of a door, window or opening on a straight wall.
    mutating func addOpening(_ opening: CleanOpening, walls: [CleanWall]) {
        guard let wallID = opening.wallID, let wall = walls.first(where: { $0.id == wallID }),
              wall.arc == nil else { return }
        let start = wall.start.simd
        let direction = wall.end.simd - start
        let length = simd_length(direction)
        guard length > 1e-4, length.isFinite else { return }
        let along = direction / length
        let up = SIMD3<Float>(0, 1, 0)
        let left = start + along * opening.offsetAlongWall
        let right = start + along * (opening.offsetAlongWall + opening.width)
        let p0 = left + up * opening.sillHeight
        let p1 = right + up * opening.sillHeight
        let p2 = right + up * opening.headHeight
        let p3 = left + up * opening.headHeight
        let points = [p0, p1, p2, p3]
        guard points.allSatisfy({ SnapSetBuilder.isFinite($0) }) else { return }
        let feature = SnapSetBuilder.feature(for: opening.kind)
        for p in points {
            addCorner(p, feature: feature == .edge ? .corner : feature, element: opening.id)
        }
        for i in 0..<4 {
            addEdge(points[i], points[(i + 1) % 4], feature: feature, element: opening.id)
        }
    }

    /// The eight corners and twelve edges of a detected object's box.
    mutating func addObject(_ object: DetectedObject) {
        let corners = object.orientedBox.corners
        guard corners.count == 8, corners.allSatisfy({ SnapSetBuilder.isFinite($0) }) else { return }
        for c in corners {
            addCorner(c, feature: .objectEdge, element: object.id)
        }
        for i in 0..<8 {
            for bit in [1, 2, 4] where i & bit == 0 {
                addEdge(corners[i], corners[i | bit], feature: .objectEdge, element: object.id)
            }
        }
    }

    /// Floor plane at the floor elevation and ceiling plane at elevation plus ceiling height,
    /// both limited to the floor outline.
    mutating func addFloorAndCeiling(_ room: CleanRoom) {
        let outline = MeasureRoomSizes.outlinePoints(room)
        let region: SnapSetPlaneRegion? = outline.count >= 3 ? .outline(outline) : nil
        let floorY = room.floor.elevation
        guard floorY.isFinite else { return }
        let up = SIMD3<Float>(0, 1, 0)
        addPlane(Plane(point: SIMD3<Float>(0, floorY, 0), normal: up), feature: .floor, element: room.id, region: region)
        let sizes = MeasureRoomSizes(room: room, wallAreas: [])
        guard MeasureRoomSizes.isPositive(sizes.ceilingHeight) else { return }
        let ceilingY = floorY + sizes.ceilingHeight
        addPlane(Plane(point: SIMD3<Float>(0, ceilingY, 0), normal: -up), feature: .ceiling, element: room.id, region: region)
    }

    /// The plane of a straight wall, limited to its rectangle.
    mutating func addWallPlane(_ wall: CleanWall) {
        let start = wall.start.simd
        let direction = wall.end.simd - start
        let length = simd_length(direction)
        guard length > 1e-4, length.isFinite, wall.height.isFinite, wall.height > 0 else { return }
        let along = direction / length
        let up = SIMD3<Float>(0, 1, 0)
        var normal = wall.normal.simd
        if !SnapSetBuilder.isFinite(normal) || simd_length(normal) < 1e-4 {
            normal = simd_cross(up, along)
        }
        let region = SnapSetPlaneRegion.rectangle(origin: start, axisU: along, lengthU: length,
                                                  axisV: up, lengthV: wall.height)
        addPlane(Plane(point: start, normal: normal), feature: .wall, element: wall.id, region: region)
    }

    // MARK: - Appending

    /// Adds a corner unless an equal one (within `SnapSet.mergeDistance`) exists.
    mutating func addCorner(_ p: SIMD3<Float>, feature: SnapSetFeature, element: ElementID?) {
        for existing in result.corners where simd_distance(existing, p) < SnapSet.mergeDistance {
            return
        }
        result.corners.append(p)
        result.cornerElements.append(element)
        result.cornerFeatures.append(feature)
    }

    /// Adds an edge unless an equal one (either direction) exists or it is degenerate.
    mutating func addEdge(_ a: SIMD3<Float>, _ b: SIMD3<Float>, feature: SnapSetFeature, element: ElementID?) {
        let tolerance = SnapSet.mergeDistance
        guard simd_distance(a, b) >= tolerance else { return }
        for edge in result.edges {
            let same = simd_distance(edge.0, a) < tolerance && simd_distance(edge.1, b) < tolerance
            let reversed = simd_distance(edge.0, b) < tolerance && simd_distance(edge.1, a) < tolerance
            if same || reversed { return }
        }
        result.edges.append((a, b))
        result.edgeElements.append(element)
        result.edgeFeatures.append(feature)
    }

    /// Adds a plane with its region.
    mutating func addPlane(_ plane: Plane, feature: SnapSetFeature, element: ElementID?, region: SnapSetPlaneRegion?) {
        result.planes.append(plane)
        result.planeElements.append(element)
        result.planeFeatures.append(feature)
        result.planeRegions.append(region)
    }

    // MARK: - Helpers

    /// Door and window features; an open passage counts as an edge.
    static func feature(for kind: OpeningKind) -> SnapSetFeature {
        switch kind {
        case .door, .openDoor: return .door
        case .window: return .window
        case .opening: return .edge
        }
    }

    /// True when every component is finite.
    static func isFinite(_ p: SIMD3<Float>) -> Bool {
        p.x.isFinite && p.y.isFinite && p.z.isFinite
    }
}
