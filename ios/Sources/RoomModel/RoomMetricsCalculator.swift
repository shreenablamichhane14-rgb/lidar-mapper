import Foundation
import simd

/// Room measurements, mesh-based floor and ceiling heights (D13) and the build 4 occlusion
/// heuristic. Pure functions, safe on any queue.
enum RoomMetricsCalculator {
    /// ARKit mesh classification of floor faces (`ARMeshClassification.floor`).
    static let floorClass: UInt8 = 2
    /// ARKit mesh classification of ceiling faces (`ARMeshClassification.ceiling`).
    static let ceilingClass: UInt8 = 3
    /// Faces whose unit normal has |y| below this are not treated as floor or ceiling.
    static let minimumHorizontalness: Float = 0.7
    /// Ceiling faces lower than this above the floor are ignored, meters.
    static let minimumCeilingClearance: Float = 1.0

    /// Floor area and perimeter are sums (shoelace) over `floor.outline` and every
    /// `floor.mergedOutlines` part (build 5, 3.37b); length and width come from the minimum-area
    /// rectangle of the points of all parts; wall area is the walls minus hosted openings
    /// (curved walls by arc length); volume is the total area times the ceiling height, with the
    /// ceiling's provenance. No scale correction is applied here.
    static func metrics(for room: CleanRoom) -> RoomMetrics {
        let parts = floorParts(of: room)
        let points = parts.flatMap { $0 }
        var area: Float = 0
        var perimeter: Float = 0
        for part in parts {
            let polygon = Polygon2D(points: part)
            area += polygon.area
            perimeter += polygon.perimeter
        }
        var length: Float = 0
        var width: Float = 0
        if points.count >= 3, let rectangle = Rectangle2D.minimumArea(enclosing: points) {
            let sideA = rectangle.halfExtents.x * 2
            let sideB = rectangle.halfExtents.y * 2
            length = Swift.max(sideA, sideB)
            width = Swift.min(sideA, sideB)
        }
        var wallArea: Float = 0
        for wall in room.walls {
            let surface = RoomOutline.surfaceLength(start: PlanAxes.toPlan(wall.start.simd), end: PlanAxes.toPlan(wall.end.simd),
                                                    arc: wall.arc)
            let gross = surface * wall.height
            var cut: Float = 0
            for opening in room.openings where opening.wallID == wall.id {
                let top = Swift.min(opening.headHeight, wall.height)
                cut += opening.width * Swift.max(0, top - opening.sillHeight)
            }
            wallArea += Swift.max(0, gross - cut)
        }
        let height = room.ceiling.height
        return RoomMetrics(floorArea: area, perimeter: perimeter, ceilingHeight: height,
                           ceilingProvenance: room.ceiling.provenance, wallArea: wallArea, length: length, width: width,
                           volume: area * height, volumeProvenance: room.ceiling.provenance)
    }

    /// The floor parts of a room in plan meters: `floor.outline` followed by every
    /// `floor.mergedOutlines` ring (CR-1 merges and splits), keeping only rings with at least 3
    /// points. Empty when the room has no usable outline.
    static func floorParts(of room: CleanRoom) -> [[SIMD2<Float>]] {
        var rings: [[Vec2]] = [room.floor.outline]
        if let merged = room.floor.mergedOutlines { rings.append(contentsOf: merged) }
        return rings.filter { $0.count >= 3 }.map { ring in ring.map { $0.simd } }
    }

    /// True when a plan point lies inside any floor part of the room.
    static func floorContains(_ room: CleanRoom, point: SIMD2<Float>) -> Bool {
        floorParts(of: room).contains { Polygon2D(points: $0).contains(point: point) }
    }

    /// Metrics for a uniform scale correction (D21): lengths times `factor`, areas times its
    /// square, volume times its cube. Provenance is unchanged.
    static func scaled(_ metrics: RoomMetrics, by factor: Float) -> RoomMetrics {
        var result = metrics
        let square = factor * factor
        result.floorArea *= square
        result.perimeter *= factor
        result.ceilingHeight *= factor
        result.wallArea *= square
        result.length *= factor
        result.width *= factor
        result.volume *= square * factor
        return result
    }

    /// D13: median Y of ceiling faces (class 3) inside the outline minus floor Y, when they cover
    /// at least `gate` of the outline area.
    static func ceilingFromMesh(_ mesh: MeshWithAttributes, outline: [SIMD2<Float>], floorY: Float, gate: Float) -> (height: Float, coverage: Float)? {
        guard let sample = horizontalFaces(mesh, outline: outline, surfaceClass: ceilingClass,
                                           minimumY: floorY + minimumCeilingClearance) else { return nil }
        let height = sample.medianY - floorY
        guard sample.coverage >= gate, height > 0.5, height.isFinite else { return nil }
        return (height, Swift.min(1, sample.coverage))
    }

    /// D13 for the floor: area-weighted median Y of floor faces (class 2) inside the outline,
    /// when they cover at least `gate` of the outline area.
    static func floorFromMesh(_ mesh: MeshWithAttributes, outline: [SIMD2<Float>], gate: Float) -> (elevation: Float, coverage: Float)? {
        guard let sample = horizontalFaces(mesh, outline: outline, surfaceClass: floorClass, minimumY: nil),
              sample.coverage >= gate, sample.medianY.isFinite else { return nil }
        return (sample.medianY, Swift.min(1, sample.coverage))
    }

    /// Area-weighted median Y and plan-projected coverage fraction of the roughly horizontal
    /// faces of one class whose centroid lies inside the outline (and above `minimumY`).
    static func horizontalFaces(_ input: MeshWithAttributes, outline: [SIMD2<Float>], surfaceClass: UInt8,
                                minimumY: Float?) -> (medianY: Float, coverage: Float)? {
        guard outline.count >= 3, let classes = input.faceClass, classes.count == input.triangleCount else { return nil }
        let polygon = Polygon2D(points: outline)
        let outlineArea = polygon.area
        guard outlineArea > 1e-4, let bounds = polygon.boundingBox else { return nil }
        var samples: [(y: Float, area: Float)] = []
        var covered: Float = 0
        for t in 0..<input.triangleCount where classes[t] == surfaceClass {
            guard let corners = input.mesh.triangle(t) else { continue }
            let (a, b, c) = corners
            let cross = simd_cross(b - a, c - a)
            let doubleArea = simd_length(cross)
            guard doubleArea > 1e-9, abs(cross.y) >= minimumHorizontalness * doubleArea else { continue }
            let centroid = (a + b + c) / 3
            if let minimumY, centroid.y < minimumY { continue }
            let p = PlanAxes.toPlan(centroid)
            guard p.x >= bounds.min.x, p.x <= bounds.max.x, p.y >= bounds.min.y, p.y <= bounds.max.y,
                  polygon.contains(point: p) else { continue }
            let projected = abs(cross.y) * 0.5
            samples.append((centroid.y, projected))
            covered += projected
        }
        guard !samples.isEmpty, covered > 0 else { return nil }
        samples.sort { $0.y < $1.y }
        let half = covered * 0.5
        var accumulated: Float = 0
        var median = samples[samples.count - 1].y
        for sample in samples {
            accumulated += sample.area
            if accumulated >= half {
                median = sample.y
                break
            }
        }
        return (median, covered / outlineArea)
    }

    /// Movable objects within `distance` of a wall add occluded spans; their footprints add occluded floor area.
    /// Straight walls only (curved walls get no spans in build 4); spans are merged and sorted.
    /// The footprints of movable objects whose center lies inside a floor part (the outline or
    /// a merged outline) add up to the occluded floor area, capped at the total floor area.
    /// Replaces any previous values.
    static func applyOcclusion(_ room: inout CleanRoom, distance: Float) {
        for i in room.walls.indices { room.walls[i].occludedSpans = [] }
        room.floor.occludedArea = 0
        let movers = room.objects.filter { $0.isMovable }
        guard !movers.isEmpty else { return }
        let parts = floorParts(of: room).map { Polygon2D(points: $0) }
        let totalArea = parts.reduce(Float(0)) { $0 + $1.area }
        var hidden: Float = 0
        for object in movers {
            let center = PlanAxes.toPlan(object.transform.translation)
            if parts.isEmpty || parts.contains(where: { $0.contains(point: center) }) {
                hidden += Polygon2D(points: footprint(of: object)).area
            }
        }
        room.floor.occludedArea = parts.isEmpty ? hidden : Swift.min(hidden, totalArea)
        for w in room.walls.indices where room.walls[w].arc == nil {
            var spans: [ClosedRange<Float>] = []
            for object in movers {
                if let span = occlusionSpan(of: object, wall: room.walls[w], distance: distance) { spans.append(span) }
            }
            room.walls[w].occludedSpans = mergedSpans(spans)
        }
    }

    /// Plan footprint of an object's box (convex hull of its corners), counter-clockwise.
    static func footprint(of object: DetectedObject) -> [SIMD2<Float>] {
        Polygon2D.convexHull(object.orientedBox.corners.map { PlanAxes.toPlan($0) }).points
    }

    /// World Y of the top of an object's box.
    static func occluderTop(_ object: DetectedObject) -> Float {
        object.orientedBox.corners.map { $0.y }.max() ?? object.transform.translation.y
    }

    /// The span along a straight wall (meters from its start, clamped to the wall) covered by
    /// an object's footprint when the footprint comes within `distance` of the wall line on
    /// either side; nil when it is farther or the overlap is under 1 cm.
    static func occlusionSpan(of object: DetectedObject, wall: CleanWall, distance: Float) -> ClosedRange<Float>? {
        let a = PlanAxes.toPlan(wall.start.simd)
        let b = PlanAxes.toPlan(wall.end.simd)
        let length = simd_distance(a, b)
        guard length > 1e-3 else { return nil }
        let direction = (b - a) / length
        let normal = SIMD2<Float>(-direction.y, direction.x)
        var lowT = Float.greatestFiniteMagnitude
        var highT = -Float.greatestFiniteMagnitude
        var lowD = Float.greatestFiniteMagnitude
        var highD = -Float.greatestFiniteMagnitude
        for corner in footprint(of: object) {
            let offset = corner - a
            let t = simd_dot(offset, direction)
            let d = simd_dot(offset, normal)
            lowT = Swift.min(lowT, t)
            highT = Swift.max(highT, t)
            lowD = Swift.min(lowD, d)
            highD = Swift.max(highD, d)
        }
        guard lowT <= highT else { return nil }
        let gap: Float
        if lowD <= 0 && highD >= 0 {
            gap = 0
        } else {
            gap = lowD > 0 ? lowD : -highD
        }
        guard gap <= distance else { return nil }
        let start = Swift.max(0, lowT)
        let end = Swift.min(length, highT)
        guard end - start >= 0.01 else { return nil }
        return start...end
    }

    /// Spans sorted by start, with overlapping or touching (within 1 mm) spans merged.
    static func mergedSpans(_ spans: [ClosedRange<Float>]) -> [ClosedRange<Float>] {
        let sorted = spans.sorted { $0.lowerBound < $1.lowerBound }
        var result: [ClosedRange<Float>] = []
        for span in sorted {
            if let last = result.last, span.lowerBound <= last.upperBound + 0.001 {
                result[result.count - 1] = last.lowerBound...Swift.max(last.upperBound, span.upperBound)
            } else {
                result.append(span)
            }
        }
        return result
    }
}
