import Foundation

/// What a measurement measures. Raw values are persisted.
enum MeasurementKind: String, Codable, CaseIterable, Sendable {
    case distance, wallLength, height, area, perimeter, angle, volume
}

/// What a measurement point snapped to (drives the pick uncertainty). Raw values are persisted.
enum SnapKind: String, Codable, CaseIterable, Sendable {
    case corner, edge, plane, meshVertex, meshSurface, none
}

/// Where a measurement was made. Raw values are persisted.
enum MeasurementSource: String, Codable, CaseIterable, Sendable {
    case live, viewer, plan, automatic
}

/// A measured number with its uncertainty and provenance.
struct MeasuredValue: Codable, Equatable, Sendable {
    /// Largest displayed uncertainty (2 sigma), meters, above which a length shows
    /// "Low confidence" instead of a number (ship-first 6).
    static let lowConfidenceLimit = 0.04

    /// Value in meters, square meters, cubic meters or radians depending on the kind.
    var value: Double
    /// One standard deviation in the same unit, or nil when no confidence is available.
    var sigma: Double?
    /// Where the value came from; inferred values show "Estimated" without plus-minus.
    var provenance: Provenance

    /// True when the 2-sigma uncertainty exceeds `lowConfidenceLimit`. Meaningful for
    /// lengths; false when there is no sigma.
    var isLowConfidence: Bool {
        guard let sigma = sigma else { return false }
        return sigma * 2 > MeasuredValue.lowConfidenceLimit
    }
}

/// A saved measurement (`edits/measurements.json`, `raw/measure/quick.json`).
struct MeasurementRecord: Codable, Equatable, Identifiable, Sendable {
    /// Identifier.
    var id: UUID
    /// What it measures.
    var kind: MeasurementKind
    /// Picked points, world meters (2 for a distance, 3 for an angle, n for an area).
    var points: [Vec3]
    /// What each point snapped to, one per point.
    var snaps: [SnapKind]
    /// The value.
    var result: MeasuredValue
    /// Where it was made.
    var source: MeasurementSource
    /// User name (may be empty).
    var name: String
    /// Room it belongs to, when any.
    var roomID: ElementID?
    /// When it was made.
    var createdAt: Date
}
