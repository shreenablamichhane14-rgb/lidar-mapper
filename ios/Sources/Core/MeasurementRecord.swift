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
    /// Absolute part of the low-confidence limit on 2 sigma, meters (CR-2, RESEARCH section 1).
    static let lowConfidenceLimit = 0.04
    /// Relative part of the low-confidence limit on 2 sigma, a fraction of the length (CR-2).
    static let lowConfidenceRelative = 0.03

    /// Value in meters, square meters, cubic meters or radians depending on the kind.
    var value: Double
    /// One standard deviation in the same unit, or nil when no confidence is available.
    var sigma: Double?
    /// Where the value came from; inferred values show "Estimated" without plus-minus.
    var provenance: Provenance

    /// The one low-confidence rule (CR-2), used by MeasureCore and every screen.
    /// - For a length (`length` not nil, meters): 2 sigma > max(4 cm, 3 percent of `length`).
    /// - For areas, volumes and angles (`length` nil): 2 sigma > 3 percent of the value.
    /// False when there is no sigma or the sigma is not finite.
    func isLowConfidence(length: Double?) -> Bool {
        guard let sigma = sigma, sigma.isFinite else { return false }
        let twoSigma = 2 * sigma
        if let length = length {
            return twoSigma > Swift.max(MeasuredValue.lowConfidenceLimit, MeasuredValue.lowConfidenceRelative * abs(length))
        }
        return twoSigma > MeasuredValue.lowConfidenceRelative * abs(value)
    }

    /// The rule for a measurement kind: distance, wall length, height and perimeter use the
    /// value as the length; area, volume and angle use the relative part only.
    func isLowConfidence(kind: MeasurementKind) -> Bool {
        switch kind {
        case .distance, .wallLength, .height, .perimeter:
            return isLowConfidence(length: value)
        case .area, .volume, .angle:
            return isLowConfidence(length: nil)
        }
    }

    /// The rule with `value` taken as a length (meters). For areas, volumes and angles use
    /// `isLowConfidence(kind:)` or `isLowConfidence(length: nil)`.
    var isLowConfidence: Bool { isLowConfidence(length: value) }
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
