import Foundation
import RoomPlan

// The only Core file that imports RoomPlan (D27): mappings from RoomPlan enums to Core's
// persisted enums. Every switch has `@unknown default` because RoomPlan enums are not
// frozen (D26); if the compiler says the default is never executed, that warning is fine.

extension ObjectCategory {
    /// Maps a RoomPlan object category; unknown future categories become `.other`.
    init(_ category: CapturedRoom.Object.Category) {
        switch category {
        case .bathtub: self = .bathtub
        case .bed: self = .bed
        case .chair: self = .chair
        case .dishwasher: self = .dishwasher
        case .fireplace: self = .fireplace
        case .oven: self = .oven
        case .refrigerator: self = .refrigerator
        case .sink: self = .sink
        case .sofa: self = .sofa
        case .stairs: self = .stairs
        case .storage: self = .storage
        case .stove: self = .stove
        case .table: self = .table
        case .television: self = .television
        case .toilet: self = .toilet
        case .washerDryer: self = .washerDryer
        @unknown default: self = .other
        }
    }
}

extension DetectionConfidence {
    /// Maps RoomPlan's category confidence; unknown future values become `.low`.
    init(_ confidence: CapturedRoom.Confidence) {
        switch confidence {
        case .low: self = .low
        case .medium: self = .medium
        case .high: self = .high
        @unknown default: self = .low
        }
    }
}

extension OpeningKind {
    /// Maps a RoomPlan surface category; nil for walls, floors and unknown categories.
    init?(_ category: CapturedRoom.Surface.Category) {
        switch category {
        case .door(let isOpen): self = isOpen ? .openDoor : .door
        case .window: self = .window
        case .opening: self = .opening
        case .wall, .floor: return nil
        @unknown default: return nil
        }
    }
}
