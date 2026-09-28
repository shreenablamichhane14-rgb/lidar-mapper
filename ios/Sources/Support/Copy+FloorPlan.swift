import Foundation

/// Floor plan strings added by the FloorPlan module (docs/MODULES.md 3.16): default room
/// titles, RoomPlan section label names, stair labels, the room tag and the display name of
/// every object category. `Copy.FloorPlan` itself is declared in `Copy.swift`.
extension Copy.FloorPlan {
    /// Title of a room that has no user name and no RoomPlan section label ("Room 2").
    static func defaultRoomTitle(_ n: Int) -> String { "Room \(n)" }

    /// RoomPlan section label names (RoomPlan knows only these five room types).
    static let sectionLivingRoom = "Living Room", sectionKitchen = "Kitchen", sectionDiningRoom = "Dining Room"
    static let sectionBedroom = "Bedroom", sectionBathroom = "Bathroom"

    /// Stair direction labels drawn on the plan.
    static let stairsUp = "UP", stairsDown = "DN"

    /// Room tag on the plan: the room title with its area on the next line. The drawing splits
    /// it into one text line per row, because plan text entities are single-line.
    static func roomTag(name: String, area: String) -> String { "\(name)\n\(area)" }

    /// Display name of an object category, for fixture labels, the Results object card and
    /// exports. Exhaustive on purpose: a new category is a compile error until it has text.
    static func categoryName(_ category: ObjectCategory) -> String {
        switch category {
        case .bathtub: return "Bathtub"
        case .bed: return "Bed"
        case .chair: return "Chair"
        case .dishwasher: return "Dishwasher"
        case .fireplace: return "Fireplace"
        case .oven: return "Oven"
        case .refrigerator: return "Refrigerator"
        case .sink: return "Sink"
        case .sofa: return "Sofa"
        case .stairs: return "Stairs"
        case .storage: return "Storage"
        case .stove: return "Stove"
        case .table: return "Table"
        case .television: return "TV"
        case .toilet: return "Toilet"
        case .washerDryer: return "Washer or Dryer"
        case .desk: return "Desk"
        case .cabinet: return "Cabinet"
        case .shelf: return "Shelf"
        case .lamp: return "Lamp"
        case .plant: return "Plant"
        case .appliance: return "Appliance"
        case .vehicle: return "Vehicle"
        case .other: return "Object"
        }
    }
}
