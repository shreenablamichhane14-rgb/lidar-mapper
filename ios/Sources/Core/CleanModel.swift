import Foundation
import simd

/// Where a value came from; shown as Measured / Estimated / Inferred / Edited through Copy.
enum Provenance: String, Codable, CaseIterable, Sendable {
    case measured, estimated, inferred, user
}

/// The clean architectural model of a project (`derived/clean.json`), before edits are
/// applied. Built by RoomModel from RoomPlan results and the consolidated mesh.
struct CleanModel: Codable, Equatable, Sendable {
    /// All rooms, in capture order.
    var rooms: [CleanRoom]
    /// True when built from a merged `CapturedStructure` instead of single rooms.
    var sourceIsStructure: Bool
    /// Stamp of the step that produced it (D11).
    var stamp: DerivedStamp?

    /// An empty model.
    static let empty = CleanModel(rooms: [], sourceIsStructure: false, stamp: nil)
}

/// One room of the clean model.
struct CleanRoom: Codable, Equatable, Identifiable, Sendable {
    /// Element identifier of the room.
    var id: ElementID
    /// Our `RoomRecord.id`.
    var recordID: UUID
    /// Room name (user text or empty for the Copy default).
    var name: String
    /// RoomPlan section label raw value (livingRoom, kitchen, ...), when detected.
    var sectionLabel: String?
    /// Floor index.
    var floorIndex: Int
    /// Walls in loop order.
    var walls: [CleanWall]
    /// Doors, windows and openings.
    var openings: [CleanOpening]
    /// Floor outline and elevation.
    var floor: CleanFloor
    /// Ceiling height.
    var ceiling: CleanCeiling
    /// Detected furniture and fixtures.
    var objects: [DetectedObject]
    /// Derived measurements.
    var metrics: RoomMetrics
}

/// One wall: a vertical rectangle from `start` to `end` at floor level, `height` tall.
struct CleanWall: Codable, Equatable, Identifiable, Sendable {
    /// Element identifier.
    var id: ElementID
    /// Bottom start point, world meters.
    var start: Vec3
    /// Bottom end point, world meters.
    var end: Vec3
    /// Height, meters.
    var height: Float
    /// Horizontal unit normal pointing into the room.
    var normal: Vec3
    /// Thickness, meters.
    var thickness: Float
    /// Where the thickness came from.
    var thicknessSource: Provenance
    /// Arc for curved walls.
    var arc: WallArc?
    /// RoomPlan detection confidence.
    var confidence: DetectionConfidence
    /// Number of edges RoomPlan marked complete, 0...4.
    var completedEdges: Int
    /// Spans along the wall, meters from `start`, hidden behind objects.
    var occludedSpans: [ClosedRange<Float>]
    /// Where the geometry came from.
    var provenance: Provenance

    /// Straight-line length from start to end, meters.
    var length: Float { simd_distance(start.simd, end.simd) }
}

/// Arc of a curved wall (RoomPlan `Surface.Curve`, angles in radians).
struct WallArc: Codable, Equatable, Sendable {
    /// Arc center, world meters.
    var center: Vec3
    /// Radius, meters.
    var radius: Float
    /// Start angle, radians.
    var startAngle: Float
    /// End angle, radians.
    var endAngle: Float
}

/// A door, window or opening in a wall.
struct CleanOpening: Codable, Equatable, Identifiable, Sendable {
    /// Element identifier.
    var id: ElementID
    /// Wall it belongs to, when known.
    var wallID: ElementID?
    /// What it is.
    var kind: OpeningKind
    /// Distance from the wall start to the opening's near edge, meters.
    var offsetAlongWall: Float
    /// Width, meters.
    var width: Float
    /// Bottom height above the floor, meters (0 for doors).
    var sillHeight: Float
    /// Top height above the floor, meters.
    var headHeight: Float
    /// Door swing, when known.
    var swing: DoorSwing?
    /// Where the geometry came from.
    var provenance: Provenance
}

/// Opening kinds. Raw values are persisted.
enum OpeningKind: String, Codable, CaseIterable, Sendable {
    case door, openDoor, window, opening
}

/// How a door swings.
struct DoorSwing: Codable, Equatable, Sendable {
    /// True when hinged at the end nearer the wall start.
    var hingeAtStart: Bool
    /// True when it opens toward the wall's normal side (into the room).
    var opensToNormalSide: Bool
    /// Where the swing came from.
    var source: Provenance
}

/// Floor of a room.
struct CleanFloor: Codable, Equatable, Sendable {
    /// Outline in plan coordinates (see `PlanAxes`), counter-clockwise.
    var outline: [Vec2]
    /// Floor elevation (world y), meters.
    var elevation: Float
    /// Floor area hidden under objects, square meters.
    var occludedArea: Float
    /// Where the elevation came from (D13).
    var provenance: Provenance
}

/// Ceiling of a room.
struct CleanCeiling: Codable, Equatable, Sendable {
    /// Height above the floor, meters.
    var height: Float
    /// Measured from ceiling mesh faces, or estimated from wall heights (D13).
    var provenance: Provenance
}

/// Detection confidence (RoomPlan category certainty, not dimensional accuracy).
enum DetectionConfidence: String, Codable, CaseIterable, Sendable {
    case low, medium, high
}

/// A detected piece of furniture or fixture, as an oriented box.
struct DetectedObject: Codable, Equatable, Identifiable, Sendable {
    /// Element identifier.
    var id: ElementID
    /// Category.
    var category: ObjectCategory
    /// User label (empty means "use the category name from Copy").
    var label: String
    /// Box center pose, world (RoomPlan `Object.transform`).
    var transform: Transform4
    /// Box size, meters (RoomPlan `Object.dimensions`).
    var dimensions: Vec3
    /// Detection confidence.
    var confidence: DetectionConfidence
    /// True when hidden by the user or by Hide Furniture.
    var isHidden: Bool
    /// Where the object came from.
    var provenance: Provenance

    /// True for furniture that Hide Furniture removes.
    var isMovable: Bool { category.isMovable }

    /// The object's box as a Geometry `OrientedBox`.
    var orientedBox: OrientedBox {
        let t = transform.simd
        let axes = simd_float3x3(columns: (simd_normalize(SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z)),
                                           simd_normalize(SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z)),
                                           simd_normalize(SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z))))
        return OrientedBox(center: transform.translation, axes: axes, halfExtents: dimensions.simd * 0.5)
    }
}

/// Object categories: the 16 RoomPlan categories plus SPEC categories RoomPlan lacks.
/// Display names come from Copy through `copyKey`. Raw values are persisted.
enum ObjectCategory: String, Codable, CaseIterable, Sendable {
    case bathtub, bed, chair, dishwasher, fireplace, oven, refrigerator, sink, sofa, stairs,
         storage, stove, table, television, toilet, washerDryer
    case desk, cabinet, shelf, lamp, plant, appliance, vehicle, other

    /// True for furniture (removed by Hide Furniture); false for built-in fixtures.
    var isMovable: Bool {
        switch self {
        case .bed, .chair, .sofa, .storage, .table, .television, .desk, .shelf, .lamp, .plant, .vehicle, .other:
            return true
        case .bathtub, .dishwasher, .fireplace, .oven, .refrigerator, .sink, .stairs, .stove, .toilet,
             .washerDryer, .cabinet, .appliance:
            return false
        }
    }

    /// Key the UI maps to a Copy string.
    var copyKey: String { rawValue }
}

/// Derived room measurements (meters, square meters, cubic meters).
struct RoomMetrics: Codable, Equatable, Sendable {
    /// Floor area from the wall loop (D12).
    var floorArea: Float
    /// Perimeter of the wall loop.
    var perimeter: Float
    /// Ceiling height.
    var ceilingHeight: Float
    /// Where the ceiling height came from.
    var ceilingProvenance: Provenance
    /// Wall area minus openings.
    var wallArea: Float
    /// Longer side of the minimum-area bounding rectangle of the outline.
    var length: Float
    /// Shorter side of that rectangle.
    var width: Float
    /// Floor area times ceiling height.
    var volume: Float
    /// Where the volume came from (follows the ceiling).
    var volumeProvenance: Provenance

    /// All zeros, provenance inferred.
    static let zero = RoomMetrics(floorArea: 0, perimeter: 0, ceilingHeight: 0, ceilingProvenance: .inferred,
                                  wallArea: 0, length: 0, width: 0, volume: 0, volumeProvenance: .inferred)
}

/// The one plan coordinate convention: plan x = world x, plan y = -world z (so a plan
/// seen from above with y up matches the world seen from above). Every module converts
/// through these functions.
enum PlanAxes {
    /// World point to plan point (height dropped).
    static func toPlan(_ p: SIMD3<Float>) -> SIMD2<Float> {
        SIMD2<Float>(p.x, -p.z)
    }

    /// Plan point to world point at height `y`.
    static func toWorld(_ p: SIMD2<Float>, y: Float) -> SIMD3<Float> {
        SIMD3<Float>(p.x, y, -p.y)
    }

    /// World vector to plan vector (Codable forms).
    static func toPlan(_ p: Vec3) -> Vec2 {
        Vec2(toPlan(p.simd))
    }
}
