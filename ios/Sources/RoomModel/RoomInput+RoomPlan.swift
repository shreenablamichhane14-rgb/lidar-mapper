import Foundation
import RoomPlan
import simd

// The only conversion from RoomPlan result types into RoomModel's testable mirror. RoomPlan
// values are read, never constructed or mutated (docs/MODULES.md 3.12 "Must NOT do"). Every
// switch over a RoomPlan enum has `@unknown default` because those enums are not frozen.

extension RoomInput {
    /// Mirrors a decoded `CapturedRoom`. Doors, windows and openings are merged into
    /// `openings` (their `kind` keeps them apart). `isProvisional` is false; the store sets it
    /// when the room came from `capturedroom-live.json`.
    init(_ room: CapturedRoom) {
        let wallInputs = room.walls.map { SurfaceInput($0) }
        var openingInputs: [SurfaceInput] = []
        openingInputs.append(contentsOf: room.doors.map { SurfaceInput($0) })
        openingInputs.append(contentsOf: room.windows.map { SurfaceInput($0) })
        openingInputs.append(contentsOf: room.openings.map { SurfaceInput($0) })
        self.init(identifier: room.identifier,
                  walls: wallInputs,
                  openings: openingInputs,
                  floors: room.floors.map { SurfaceInput($0) },
                  objects: room.objects.map { ObjectInput($0) },
                  sections: room.sections.map { SectionInput($0) },
                  story: room.story,
                  isProvisional: false)
    }
}

extension SurfaceInput {
    /// Mirrors one RoomPlan surface. Curve angles are converted with
    /// `.converted(to: .radians).value`; `completedEdges` keeps only the count.
    init(_ surface: CapturedRoom.Surface) {
        var arc: WallArcInput?
        if let curve = surface.curve {
            let start = Float(curve.startAngle.converted(to: .radians).value)
            let end = Float(curve.endAngle.converted(to: .radians).value)
            arc = WallArcInput(center: Vec2(curve.center), radius: curve.radius, startAngle: start, endAngle: end)
        }
        self.init(identifier: surface.identifier,
                  parentIdentifier: surface.parentIdentifier,
                  kind: SurfaceInput.kind(of: surface.category),
                  transform: Transform4(surface.transform),
                  dimensions: Vec3(surface.dimensions),
                  confidence: DetectionConfidence(surface.confidence),
                  completedEdges: surface.completedEdges.count,
                  curve: arc,
                  polygonCorners: surface.polygonCorners.map { Vec3($0) },
                  story: surface.story)
    }

    /// Maps RoomPlan's surface category; unknown future categories become `.opening`.
    static func kind(of category: CapturedRoom.Surface.Category) -> SurfaceKind {
        switch category {
        case .wall: return .wall
        case .floor: return .floor
        case .door(let isOpen): return isOpen ? .openDoor : .door
        case .window: return .window
        case .opening: return .opening
        @unknown default: return .opening
        }
    }
}

extension ObjectInput {
    /// Mirrors one RoomPlan object through Core's category and confidence mappings.
    init(_ object: CapturedRoom.Object) {
        self.init(identifier: object.identifier,
                  parentIdentifier: object.parentIdentifier,
                  category: ObjectCategory(object.category),
                  transform: Transform4(object.transform),
                  dimensions: Vec3(object.dimensions),
                  confidence: DetectionConfidence(object.confidence),
                  story: object.story)
    }
}

extension SectionInput {
    /// Mirrors one RoomPlan section. The label is stored by its case name (for example
    /// "livingRoom"), which is also what `CleanRoom.sectionLabel` persists.
    init(_ section: CapturedRoom.Section) {
        self.init(label: SectionInput.labelName(section.label),
                  center: Vec3(section.center),
                  story: section.story)
    }

    /// Stable case name of a RoomPlan section label. An explicit switch instead of
    /// `String(describing:)`, which depends on RoomPlan's reflection metadata and description;
    /// unknown future labels become "unidentified".
    static func labelName(_ label: CapturedRoom.Section.Label) -> String {
        switch label {
        case .livingRoom: return "livingRoom"
        case .kitchen: return "kitchen"
        case .diningRoom: return "diningRoom"
        case .bedroom: return "bedroom"
        case .bathroom: return "bathroom"
        case .unidentified: return RoomInput.unidentifiedSectionLabel
        @unknown default: return RoomInput.unidentifiedSectionLabel
        }
    }
}
