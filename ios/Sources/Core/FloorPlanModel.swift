import Foundation
import simd

/// The 2D floor plan of a project (`derived/plan.json`), before edits are applied. All
/// coordinates are plan meters (`PlanAxes`: plan x = world x, plan y = -world z).
struct PlanModel: Codable, Equatable, Sendable {
    /// One level per floor.
    var levels: [PlanLevel]
    /// Angle of true north measured counter-clockwise from plan +y, radians (0 when unknown).
    /// Export's `PDFPlanWriter.Options.northAngle` is measured counter-clockwise from +x, so
    /// callers pass `Double.pi / 2 + Double(northAngle)`.
    var northAngle: Float
    /// Stamp of the step that produced it (D11).
    var stamp: DerivedStamp?

    /// An empty plan.
    static let empty = PlanModel(levels: [], northAngle: 0, stamp: nil)
}

/// One floor of the plan.
struct PlanLevel: Codable, Equatable, Identifiable, Sendable {
    /// Floor index (matches `FloorRecord.id`).
    var id: Int
    /// Level name (user text or empty for the Copy default).
    var name: String
    /// Floor elevation, meters.
    var elevation: Float
    /// Room outlines and labels.
    var rooms: [PlanRoom]
    /// Walls.
    var walls: [PlanWall]
    /// Doors, windows and openings.
    var openings: [PlanOpening]
    /// Furniture and fixture symbols.
    var fixtures: [PlanFixture]
    /// Text, symbols and notes.
    var annotations: [PlanAnnotation]
    /// Dimension lines.
    var dimensions: [PlanDimension]
}

/// A room outline on the plan.
struct PlanRoom: Codable, Equatable, Identifiable, Sendable {
    /// Same identifier as the `CleanRoom`.
    var id: ElementID
    /// Room name (user text or empty for the Copy default).
    var name: String
    /// Outline, counter-clockwise, plan meters.
    var outline: [Vec2]
    /// Where the name and area label is drawn.
    var labelAt: Vec2
    /// Floor area, square meters.
    var area: Float
}

/// A wall centerline on the plan.
struct PlanWall: Codable, Equatable, Identifiable, Sendable {
    /// Same identifier as the `CleanWall` (or a new one for user-drawn walls).
    var id: ElementID
    /// Start point, plan meters.
    var a: Vec2
    /// End point, plan meters.
    var b: Vec2
    /// Thickness, meters.
    var thickness: Float
    /// Where the thickness came from.
    var thicknessSource: Provenance
    /// Arc for curved walls (center in world coordinates, as in the clean model).
    var arc: WallArc?
    /// Where the geometry came from.
    var provenance: Provenance
    /// Spans along the wall, meters from `a`, hidden behind objects (drawn dashed).
    var occludedSpans: [ClosedRange<Float>]
}

/// A door, window or opening on the plan.
struct PlanOpening: Codable, Equatable, Identifiable, Sendable {
    /// Same identifier as the `CleanOpening`.
    var id: ElementID
    /// Host wall.
    var wallID: ElementID
    /// What it is.
    var kind: OpeningKind
    /// Distance from the wall's `a` end to the opening's near edge, meters.
    var offset: Float
    /// Width, meters.
    var width: Float
    /// Door swing, when known.
    var swing: DoorSwing?
}

/// A furniture or fixture symbol on the plan.
struct PlanFixture: Codable, Equatable, Identifiable, Sendable {
    /// Same identifier as the `DetectedObject`.
    var id: ElementID
    /// Category (selects the symbol).
    var category: ObjectCategory
    /// Center, plan meters.
    var center: Vec2
    /// Footprint size (along the object's own x and z), meters.
    var size: Vec2
    /// Rotation in the plan, radians counter-clockwise.
    var yaw: Float
    /// True for furniture, false for fixtures.
    var isMovable: Bool
    /// True when hidden.
    var isHidden: Bool
}

/// Annotation kinds. Raw values are persisted.
enum AnnotationKind: String, Codable, CaseIterable, Sendable {
    case text, symbol, note
}

/// A user annotation on the plan.
struct PlanAnnotation: Codable, Equatable, Identifiable, Sendable {
    /// Element identifier.
    var id: ElementID
    /// Kind.
    var kind: AnnotationKind
    /// Anchor point, plan meters.
    var at: Vec2
    /// User text.
    var text: String
    /// Symbol name for `.symbol` annotations.
    var symbol: String?
}

/// A dimension line on the plan.
struct PlanDimension: Codable, Equatable, Identifiable, Sendable {
    /// Element identifier.
    var id: ElementID
    /// First point, plan meters.
    var a: Vec2
    /// Second point, plan meters.
    var b: Vec2
    /// Perpendicular offset of the drawn line, meters (positive to the left of a to b).
    var offset: Float
    /// True when placed by the user, false when generated.
    var isUser: Bool

    /// Measured length, meters.
    var length: Float { simd_distance(a.simd, b.simd) }
}
