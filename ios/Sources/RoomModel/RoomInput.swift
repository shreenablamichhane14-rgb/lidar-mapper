import Foundation
import simd

// A testable mirror of RoomPlan's `CapturedRoom` (docs/MODULES.md 3.12). RoomPlan types have
// no public initializer, so everything RoomModel computes starts from these plain values; the
// only conversion from RoomPlan lives in `RoomInput+RoomPlan.swift`. All values are world
// space (ARKit, meters, +Y up) exactly as RoomPlan reports them.

/// What a RoomPlan surface is. Raw values are persisted in `RoomInput` JSON.
enum SurfaceKind: String, Codable, CaseIterable, Sendable {
    /// Wall, closed door, door open during the scan, window, opening without a leaf, floor.
    case wall, door, openDoor, window, opening, floor

    /// The Core opening kind for doors, windows and openings; nil for walls and floors.
    var openingKind: OpeningKind? {
        switch self {
        case .door: return .door
        case .openDoor: return .openDoor
        case .window: return .window
        case .opening: return .opening
        case .wall, .floor: return nil
        }
    }

    /// True for doors (closed or open during the scan).
    var isDoor: Bool { self == .door || self == .openDoor }
}

/// RoomPlan `Surface.Curve` of a curved wall, in the wall's local frame: `center` is the local
/// (x, z) center, angles are radians measured from local +x toward local +z.
struct WallArcInput: Codable, Equatable, Sendable {
    /// Arc center, local (x, z), meters.
    var center: Vec2
    /// Radius, meters.
    var radius: Float
    /// Start angle, radians.
    var startAngle: Float
    /// End angle, radians.
    var endAngle: Float
}

/// One RoomPlan surface (wall, door, window, opening or floor).
struct SurfaceInput: Codable, Equatable, Sendable {
    /// RoomPlan `identifier`.
    var identifier: UUID
    /// RoomPlan `parentIdentifier` (the host wall of a door or window), when set.
    var parentIdentifier: UUID?
    /// What the surface is.
    var kind: SurfaceKind
    /// Surface pose, world. Walls and openings: columns.0 along the surface, columns.1 up,
    /// columns.3 the center (mid-height). Floors: columns.2 is world up.
    var transform: Transform4
    /// Bounding size, meters: walls and openings (width, height, 0), floors (width, depth, 0).
    var dimensions: Vec3
    /// RoomPlan detection confidence.
    var confidence: DetectionConfidence
    /// Number of edges RoomPlan marked complete, 0...4.
    var completedEdges: Int
    /// Arc of a curved wall, nil for straight surfaces.
    var curve: WallArcInput?
    /// Polygon corners in the surface's local plane coordinates (floors, non-rectangular walls).
    var polygonCorners: [Vec3]
    /// RoomPlan story hint.
    var story: Int
}

/// One RoomPlan object (furniture or fixture box).
struct ObjectInput: Codable, Equatable, Sendable {
    /// RoomPlan `identifier`.
    var identifier: UUID
    /// RoomPlan `parentIdentifier` (for example a chair's table), when set.
    var parentIdentifier: UUID?
    /// Mapped category.
    var category: ObjectCategory
    /// Box center pose, world.
    var transform: Transform4
    /// Box size, meters.
    var dimensions: Vec3
    /// RoomPlan detection confidence.
    var confidence: DetectionConfidence
    /// RoomPlan story hint.
    var story: Int
}

/// One RoomPlan section (a labeled part of a room).
struct SectionInput: Codable, Equatable, Sendable {
    /// Section label name (livingRoom, kitchen, diningRoom, bedroom, bathroom, unidentified).
    var label: String
    /// Section center, world.
    var center: Vec3
    /// RoomPlan story hint.
    var story: Int
}

/// Everything Mapper uses from one CapturedRoom, constructible in tests.
struct RoomInput: Codable, Equatable, Sendable {
    /// RoomPlan room identifier.
    var identifier: UUID
    /// Walls, in RoomPlan order (winding and order are derived later from connectivity).
    var walls: [SurfaceInput]
    /// Doors, windows and openings together (their `kind` tells them apart).
    var openings: [SurfaceInput]
    /// Floor surfaces (cross-check only, never the outline or area source).
    var floors: [SurfaceInput]
    /// Furniture and fixtures.
    var objects: [ObjectInput]
    /// Labeled sections.
    var sections: [SectionInput]
    /// RoomPlan story hint.
    var story: Int
    /// True when loaded from `capturedroom-live.json` (a killed capture): not final, so the
    /// builder gives every wall, opening, floor and object provenance `.estimated`.
    var isProvisional: Bool = false

    /// Label value RoomPlan uses for a section it could not classify.
    static let unidentifiedSectionLabel = "unidentified"

    /// Number of doors (closed or open), windows and openings.
    var openingCounts: (doors: Int, windows: Int, openings: Int) {
        var doors = 0, windows = 0, others = 0
        for surface in openings {
            switch surface.kind {
            case .door, .openDoor: doors += 1
            case .window: windows += 1
            case .opening: others += 1
            case .wall, .floor: break
            }
        }
        return (doors, windows, others)
    }
}
