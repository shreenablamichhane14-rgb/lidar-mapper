import Foundation

// Floor levels of a house by floor elevation (ARCHITECTURE 4.3: RoomPlan's `story` and the
// user's Add Floor are hints; the structure-frame elevation decides). Pure functions,
// nonisolated, deterministic, safe on any queue.

/// One room's input to the floor assignment.
struct FloorAssignmentInput: Equatable, Sendable {
    /// Our `RoomRecord.id`.
    var roomID: UUID
    /// `RoomRecord.floorIndex` (Add Floor in HouseUI).
    var userFloor: Int
    /// Floor elevation in the structure frame; nil for parked or unplaced rooms.
    var elevation: Float?
}

/// Clusters rooms into floors by elevation and gives each cluster a floor index.
enum StructureFloors {
    /// Two neighboring elevations further apart than this start a new floor, meters.
    static let defaultGap: Float = 1.2

    /// Cluster rank per room, 0 for the lowest cluster: elevations sorted, a new cluster starts
    /// where two neighbors differ by more than `gap`. Non-finite elevations are left out; equal
    /// elevations are ordered by room id so the result never depends on dictionary order.
    static func group(elevations: [UUID: Float], gap: Float = 1.2) -> [UUID: Int] {
        let sorted = elevations.filter { $0.value.isFinite }.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key.uuidString < rhs.key.uuidString
        }
        var result: [UUID: Int] = [:]
        var rank = 0
        var previous: Float?
        for entry in sorted {
            if let last = previous, entry.value - last > gap { rank += 1 }
            result[entry.key] = rank
            previous = entry.value
        }
        return result
    }

    /// The derived floor index of every room (ARCHITECTURE 4.3: "story as a hint only").
    /// Rooms with an elevation are clustered with `group`; each cluster, lowest first, takes the
    /// user floor most of its rooms carry (ties: the smaller index), unless a lower cluster
    /// already took that index, in which case it takes one more than the largest index used so
    /// far. Rooms without an elevation keep their user floor.
    static func assign(_ rooms: [FloorAssignmentInput], gap: Float = 1.2) -> [UUID: Int] {
        var elevations: [UUID: Float] = [:]
        for room in rooms {
            if let elevation = room.elevation, elevation.isFinite { elevations[room.roomID] = elevation }
        }
        let ranks = group(elevations: elevations, gap: gap)
        let clusterCount = (ranks.values.max() ?? -1) + 1
        var result: [UUID: Int] = [:]
        var taken = Set<Int>()
        var largest = Int.min
        for rank in 0..<Swift.max(0, clusterCount) {
            let members = rooms.filter { ranks[$0.roomID] == rank }
            guard !members.isEmpty else { continue }
            var votes: [Int: Int] = [:]
            for member in members { votes[member.userFloor, default: 0] += 1 }
            let chosen = votes.max { lhs, rhs in
                lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
            }
            var floor = chosen?.key ?? 0
            if taken.contains(floor) { floor = largest + 1 }
            taken.insert(floor)
            largest = Swift.max(largest, floor)
            for member in members { result[member.roomID] = floor }
        }
        for room in rooms where result[room.roomID] == nil {
            result[room.roomID] = room.userFloor
        }
        return result
    }
}
