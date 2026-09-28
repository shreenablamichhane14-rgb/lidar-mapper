import Foundation

/// Capture evidence for one wall, filled by Quality from the coverage grid: the median best
/// camera distance to the wall and the number of good observations of it. MeasureCore turns
/// it into a Coverage `MeasurementEvidence` for both ends of every length on that wall.
struct WallEvidence: Codable, Equatable, Sendable {
    /// The wall this evidence describes (`CleanWall.id`).
    var wallID: ElementID
    /// Median best camera distance to the wall during capture, meters.
    var medianDistance: Float
    /// Number of good observations of the wall.
    var observations: Int
}

/// Capture evidence for one room, stored by Quality in `derived/rooms/<r>/quality.json`.
///
/// `relocalizations` is kept for reports only: Coverage's confidence model has no
/// relocalization term, and the limited tracking around a relocalization already lowers
/// `trackingNormalFraction`, which drives the drift part of every sigma.
struct RoomEvidence: Codable, Equatable, Sendable {
    /// Fraction 0...1 of the capture with normal tracking (`1 - RoomCaptureLog.limitedTrackingFraction`).
    var trackingNormalFraction: Float
    /// Number of relocalizations during the capture.
    var relocalizations: Int
    /// Evidence per wall; walls without an entry use `ConfidenceAdapter`'s defaults.
    var walls: [WallEvidence]

    /// No evidence: fraction 1, 0 relocalizations, no walls (every length uses the defaults).
    static let unknown = RoomEvidence(trackingNormalFraction: 1, relocalizations: 0, walls: [])

    /// The evidence for wall `id`, or nil when Quality recorded none.
    func wall(_ id: ElementID) -> WallEvidence? {
        walls.first { $0.wallID == id }
    }

    /// Typical evidence of the room's walls, for lengths that span several walls (room
    /// length, width, perimeter) and for the ceiling: the median of the valid median
    /// distances and the median observation count (lower middle, the conservative side).
    /// Nil when no wall has a finite positive distance.
    var typicalWall: (distance: Float, observations: Int)? {
        var distances: [Float] = []
        var counts: [Int] = []
        for wall in walls where wall.medianDistance.isFinite && wall.medianDistance > 0 {
            distances.append(wall.medianDistance)
            counts.append(max(0, wall.observations))
        }
        guard !distances.isEmpty else { return nil }
        distances.sort()
        counts.sort()
        let middle = distances.count / 2
        let distance: Float
        if distances.count % 2 == 0 {
            distance = (distances[middle - 1] + distances[middle]) * 0.5
        } else {
            distance = distances[middle]
        }
        let observations = counts[(counts.count - 1) / 2]
        return (distance, observations)
    }
}
