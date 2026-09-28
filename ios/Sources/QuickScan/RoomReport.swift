import Foundation
import simd
import RoomPlan

/// Measured summary of one scanned room, saved as report.json next to the 3D model.
/// All lengths in meters, areas in square meters. Plan coordinates: x = world x,
/// y = -world z (so "forward" when the scan started is plan-up).
struct RoomReport: Codable {
    struct Segment: Codable {
        var kind: String          // wall, door, window, opening
        var a: [Double]           // plan start point [x, y]
        var b: [Double]           // plan end point [x, y]
        var length: Double
        var height: Double
        var confidence: String
    }

    struct Item: Codable {
        var category: String
        var width: Double
        var height: Double
        var depth: Double
        var corners: [[Double]]   // plan footprint, 4 points
        var confidence: String
    }

    var name: String
    var date: Date
    var walls: [Segment]
    var doors: [Segment]
    var windows: [Segment]
    var openings: [Segment]
    var objects: [Item]
    var floorPolygon: [[Double]]
    var floorArea: Double?
    var perimeter: Double
    var ceilingHeight: Double
    var wallArea: Double
    /// "object" for object scans; nil (older files) or "room" for rooms.
    var kind: String?
    /// Object scans: bounding box size [width, height, depth] in meters.
    var objectSize: [Double]?
    /// Plain-language notes about automatic cleanup (object scans).
    var notes: [String]?

    var isObject: Bool { kind == "object" }

    /// Report for an object scan (no walls or floor).
    init(objectName: String, date: Date, size: [Double]) {
        name = objectName
        self.date = date
        walls = []; doors = []; windows = []; openings = []; objects = []
        floorPolygon = []
        floorArea = nil
        perimeter = 0
        ceilingHeight = 0
        wallArea = 0
        kind = "object"
        objectSize = size
        notes = nil
    }

    /// Builds the report from RoomPlan's result.
    init(room: CapturedRoom, name: String, date: Date) {
        self.name = name
        self.date = date
        walls = room.walls.map { RoomReport.segment($0, kind: "wall") }
        doors = room.doors.map { RoomReport.segment($0, kind: "door") }
        windows = room.windows.map { RoomReport.segment($0, kind: "window") }
        openings = room.openings.map { RoomReport.segment($0, kind: "opening") }
        objects = room.objects.map { RoomReport.item($0) }

        var polygon: [[Double]] = []
        if let floor = room.floors.first {
            for corner in floor.polygonCorners {
                let world = floor.transform * SIMD4<Float>(corner.x, corner.y, corner.z, 1)
                polygon.append([Double(world.x), Double(-world.z)])
            }
        }
        floorPolygon = polygon
        floorArea = polygon.count >= 3 ? RoomReport.shoelace(polygon) : nil
        perimeter = polygon.count >= 3 ? RoomReport.ringLength(polygon) : walls.reduce(0) { $0 + $1.length }
        ceilingHeight = walls.map(\.height).max() ?? 0
        let openingArea = (doors + windows + openings).reduce(0.0) { $0 + $1.length * $1.height }
        wallArea = max(0, walls.reduce(0.0) { $0 + $1.length * $1.height } - openingArea)
        kind = "room"
        objectSize = nil
        notes = nil
    }

    private static func confidenceText(_ confidence: CapturedRoom.Confidence) -> String {
        switch confidence {
        case .high: return "high"
        case .medium: return "medium"
        case .low: return "low"
        @unknown default: return "unknown"
        }
    }

    private static func segment(_ surface: CapturedRoom.Surface, kind: String) -> Segment {
        let t = surface.transform
        let center = SIMD2<Double>(Double(t.columns.3.x), Double(-t.columns.3.z))
        var axis = SIMD2<Double>(Double(t.columns.0.x), Double(-t.columns.0.z))
        let axisLength = simd_length(axis)
        axis = axisLength > 1e-6 ? axis / axisLength : SIMD2<Double>(1, 0)
        let half = Double(surface.dimensions.x) / 2
        let a = center - axis * half
        let b = center + axis * half
        return Segment(kind: kind, a: [a.x, a.y], b: [b.x, b.y],
                       length: Double(surface.dimensions.x), height: Double(surface.dimensions.y),
                       confidence: confidenceText(surface.confidence))
    }

    private static func item(_ object: CapturedRoom.Object) -> Item {
        let t = object.transform
        let d = object.dimensions
        var corners: [[Double]] = []
        for (sx, sz) in [(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5)] as [(Float, Float)] {
            let local = SIMD4<Float>(d.x * sx, 0, d.z * sz, 1)
            let world = t * local
            corners.append([Double(world.x), Double(-world.z)])
        }
        return Item(category: String(describing: object.category), width: Double(d.x), height: Double(d.y),
                    depth: Double(d.z), corners: corners, confidence: confidenceText(object.confidence))
    }

    private static func shoelace(_ points: [[Double]]) -> Double {
        var sum = 0.0
        for i in points.indices {
            let p = points[i], q = points[(i + 1) % points.count]
            sum += p[0] * q[1] - q[0] * p[1]
        }
        return abs(sum) / 2
    }

    private static func ringLength(_ points: [[Double]]) -> Double {
        var total = 0.0
        for i in points.indices {
            let p = points[i], q = points[(i + 1) % points.count]
            total += hypot(q[0] - p[0], q[1] - p[1])
        }
        return total
    }

    /// Floor plan for the PDF / DXF / SVG writers, with dimension labels in the user's units.
    func plan(prefs: UnitPreferences) -> Plan2D {
        let layers = [
            Plan2D.Layer(name: "Walls", color: SIMD3<Float>(0.1, 0.1, 0.1)),
            Plan2D.Layer(name: "Doors", color: SIMD3<Float>(0.1, 0.35, 0.85)),
            Plan2D.Layer(name: "Windows", color: SIMD3<Float>(0.0, 0.6, 0.75)),
            Plan2D.Layer(name: "Objects", color: SIMD3<Float>(0.55, 0.55, 0.55)),
            Plan2D.Layer(name: "Dimensions", color: SIMD3<Float>(0.8, 0.15, 0.15)),
            Plan2D.Layer(name: "Text", color: SIMD3<Float>(0.1, 0.1, 0.1)),
        ]
        var entities: [Plan2D.Entity] = []
        func point(_ p: [Double]) -> SIMD2<Double> { SIMD2<Double>(p[0], p[1]) }
        for wall in walls {
            entities.append(Plan2D.Entity(layer: "Walls", geometry: .line(from: point(wall.a), to: point(wall.b))))
            entities.append(Plan2D.Entity(layer: "Dimensions", geometry: .dimension(
                from: point(wall.a), to: point(wall.b), offset: 0.35,
                label: LengthFormat.primary(wall.length, prefs: prefs))))
        }
        for door in doors {
            entities.append(Plan2D.Entity(layer: "Doors", geometry: .line(from: point(door.a), to: point(door.b))))
        }
        for window in windows {
            entities.append(Plan2D.Entity(layer: "Windows", geometry: .line(from: point(window.a), to: point(window.b))))
        }
        for opening in openings {
            entities.append(Plan2D.Entity(layer: "Doors", geometry: .line(from: point(opening.a), to: point(opening.b))))
        }
        for object in objects where object.corners.count == 4 {
            entities.append(Plan2D.Entity(layer: "Objects", geometry: .polyline(points: object.corners.map(point), closed: true)))
        }
        if floorPolygon.count >= 3 {
            let cx = floorPolygon.map { $0[0] }.reduce(0, +) / Double(floorPolygon.count)
            let cy = floorPolygon.map { $0[1] }.reduce(0, +) / Double(floorPolygon.count)
            let label = floorArea.map { AreaFormat.primary($0, prefs: prefs) } ?? name
            entities.append(Plan2D.Entity(layer: "Text", geometry: .text(
                position: SIMD2<Double>(cx, cy), height: 0.2, string: label, rotation: 0)))
        }
        return Plan2D(name: name, layers: layers, entities: entities)
    }
}
