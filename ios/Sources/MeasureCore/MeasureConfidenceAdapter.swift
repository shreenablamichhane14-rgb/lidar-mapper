import Foundation
import simd

/// Turns geometry plus capture evidence into honest `MeasuredValue`s (docs/ARCHITECTURE.md 8.2).
///
/// Every sigma is about one standard deviation, in the value's own unit. Lengths come from
/// Coverage's `MeasurementConfidence` (see the formula in Coverage/MeasurementConfidence.swift:
/// depth noise by distance and confidence, tracking factor, snap factor, observations, plus a
/// drift term proportional to length). This adapter adds three rules on top:
/// 1. RoomPlan floor (docs/RESEARCH.md ruling 4 and gotcha 22): a RoomPlan-derived length is
///    never better than `roomPlanMinimumSigma` (0.015 m, shown as plus or minus 3 cm at 2 sigma),
///    the RoomPlan wall voxel size. It replaces Coverage's `roomSurfaceLengthFloor` (0.0125 m).
/// 2. When Coverage flags a value as low confidence (weak tracking, weak depth, no observations,
///    or accuracy above max(5 cm, 3 percent)), the sigma is raised to `lowConfidenceSigma(length:)`,
///    so Core's one rule (CR-2, `MeasuredValue.isLowConfidence(length:)`) sees the flag too.
/// 3. Inferred and user values carry no sigma, so no plus-minus is ever shown for them.
///
/// All constants of the measurement confidence model live here and in Coverage's
/// `MeasurementConfidence`; they are tuned with the docs/TEST_PLAN.md section 3 tape protocol.
enum ConfidenceAdapter {
    /// RESEARCH ruling 4: RoomPlan-derived lengths never better than +-3 cm displayed (2 sigma).
    static let roomPlanMinimumSigma: Float = 0.015
    /// Camera distance assumed for a wall without evidence, meters (a typical room scan).
    static let defaultDistance: Float = 2.0
    /// Observation count assumed for a wall without evidence.
    static let defaultObservations = 3
    /// Factor of `lowConfidenceSigma(length:)`: just over half the CR-2 limit, so 2 sigma lands
    /// just above max(4 cm, 3 percent of the length) and the flag also survives through products
    /// (an area from a flagged side stays above 3 percent of the area).
    static let lowConfidenceSigmaFactor: Double = 0.505

    // MARK: - Lengths

    /// A RoomPlan-derived length (wall, opening, room side, height): evidence of both ends is the
    /// wall's (or defaults), snap .roomSurface; sigma = max(Coverage accuracy, 0.015); when Coverage
    /// flags low confidence the sigma is raised to `lowConfidenceSigma(length:)` so the flag survives.
    static func roomPlanLength(_ length: Float, wall: WallEvidence?, room: RoomEvidence, provenance: Provenance) -> MeasuredValue {
        roomPlanLength(length, distance: wall?.medianDistance, observations: wall?.observations,
                       room: room, provenance: provenance)
    }

    /// `roomPlanLength(_:wall:room:provenance:)` with explicit evidence (for lengths that span
    /// several walls, such as the room length, which use `RoomEvidence.typicalWall`).
    static func roomPlanLength(_ length: Float, distance: Float?, observations: Int?,
                               room: RoomEvidence, provenance: Provenance) -> MeasuredValue {
        let value = Double(length)
        guard length.isFinite, carriesSigma(provenance) else {
            return MeasuredValue(value: value, sigma: nil, provenance: provenance)
        }
        let endpoint = evidence(distance: distance, observations: observations,
                                room: room, snap: .roomSurface)
        let span = abs(length)
        let confidence = MeasurementConfidence.estimate(start: endpoint, end: endpoint, length: span)
        var sigma = max(Double(confidence.accuracy), Double(roomPlanMinimumSigma))
        if confidence.isLowConfidence {
            sigma = max(sigma, lowConfidenceSigma(length: span))
        }
        return MeasuredValue(value: value, sigma: sigma, provenance: provenance)
    }

    /// A height measured from the mesh (D13: ceiling from ceiling mesh faces against floor mesh
    /// faces): the depth model at the typical camera distance with both ends snapped to fitted
    /// planes. No RoomPlan floor, because the value does not come from RoomPlan.
    static func meshHeight(_ height: Float, distance: Float?, observations: Int?,
                           room: RoomEvidence) -> MeasuredValue {
        let value = Double(height)
        guard height.isFinite else {
            return MeasuredValue(value: value, sigma: nil, provenance: .measured)
        }
        let endpoint = evidence(distance: distance, observations: observations, room: room, snap: .plane)
        let span = abs(height)
        let confidence = MeasurementConfidence.estimate(start: endpoint, end: endpoint, length: span)
        var sigma = Double(confidence.accuracy)
        if confidence.isLowConfidence {
            sigma = max(sigma, lowConfidenceSigma(length: span))
        }
        return MeasuredValue(value: value, sigma: sigma, provenance: .measured)
    }

    /// Free point-to-point distance (build 5 tools).
    static func distance(start: MeasurementEvidence, end: MeasurementEvidence, length: Float) -> MeasuredValue {
        let value = Double(length)
        guard length.isFinite else {
            return MeasuredValue(value: value, sigma: nil, provenance: .measured)
        }
        let span = abs(length)
        let confidence = MeasurementConfidence.estimate(start: start, end: end, length: span)
        var sigma = Double(confidence.accuracy)
        if start.snap == .roomSurface && end.snap == .roomSurface {
            sigma = max(sigma, Double(roomPlanMinimumSigma))
        }
        if confidence.isLowConfidence {
            sigma = max(sigma, lowConfidenceSigma(length: span))
        }
        return MeasuredValue(value: value, sigma: sigma, provenance: .measured)
    }

    // MARK: - Combinations

    /// Rectangle-like area from its two sides: sigma = sqrt((b sa)^2 + (a sb)^2).
    /// Also serves any product of two independent values (volume = floor area x height).
    /// Provenance is the weakest of the sides (`combined(_:)`).
    static func area(_ area: Float, sideA: MeasuredValue, sideB: MeasuredValue) -> MeasuredValue {
        let provenance = combined([sideA.provenance, sideB.provenance])
        let value = Double(area)
        guard area.isFinite, carriesSigma(provenance),
              let sa = sigmaContribution(sideA), let sb = sigmaContribution(sideB) else {
            return MeasuredValue(value: value, sigma: nil, provenance: provenance)
        }
        let termA: Double = abs(sideB.value) * sa
        let termB: Double = abs(sideA.value) * sb
        let sigma = (termA * termA + termB * termB).squareRoot()
        return MeasuredValue(value: value, sigma: sigma.isFinite ? sigma : nil, provenance: provenance)
    }

    /// Sum of lengths: sigma = sqrt(sum of sigma^2). Provenance is the weakest of the parts; an
    /// empty sum is 0 with no sigma and provenance inferred.
    static func sum(_ values: [MeasuredValue]) -> MeasuredValue {
        guard !values.isEmpty else {
            return MeasuredValue(value: 0, sigma: nil, provenance: .inferred)
        }
        var total = 0.0
        for v in values { total += v.value }
        let provenance = combined(values.map { $0.provenance })
        guard carriesSigma(provenance) else {
            return MeasuredValue(value: total, sigma: nil, provenance: provenance)
        }
        var squares = 0.0
        for v in values {
            guard let s = sigmaContribution(v) else {
                return MeasuredValue(value: total, sigma: nil, provenance: provenance)
            }
            squares += s * s
        }
        let sigma = squares.squareRoot()
        return MeasuredValue(value: total, sigma: sigma.isFinite ? sigma : nil, provenance: provenance)
    }

    /// The sigma that makes a length read as low confidence under CR-2:
    /// 0.505 * max(0.04, 0.03 * length), so 2 sigma is just above Core's limit.
    static func lowConfidenceSigma(length: Float) -> Double {
        let span: Double = length.isFinite ? Double(abs(length)) : 0
        let limit = max(MeasuredValue.lowConfidenceLimit, MeasuredValue.lowConfidenceRelative * span)
        return lowConfidenceSigmaFactor * limit
    }

    // MARK: - Helpers

    /// Weakest provenance of the parts: inferred if any part is inferred, else estimated if any
    /// is estimated, else measured if any is measured, else user (all parts set by the user).
    static func combined(_ provenances: [Provenance]) -> Provenance {
        if provenances.contains(.inferred) { return .inferred }
        if provenances.contains(.estimated) { return .estimated }
        if provenances.contains(.measured) { return .measured }
        return provenances.isEmpty ? .inferred : .user
    }

    /// True for provenances that show a plus-minus (measured and estimated).
    static func carriesSigma(_ provenance: Provenance) -> Bool {
        switch provenance {
        case .measured, .estimated: return true
        case .inferred, .user: return false
        }
    }

    /// Coverage snap kind for a Core snap kind: clean-model corners, edges and planes come from
    /// RoomPlan surfaces; a mesh vertex is a vertex; a raw mesh surface hit is treated as free.
    static func measurementSnapKind(_ kind: SnapKind) -> MeasurementSnapKind {
        switch kind {
        case .corner, .edge, .plane: return .roomSurface
        case .meshVertex: return .vertex
        case .meshSurface, .none: return MeasurementSnapKind.none
        }
    }

    /// Coverage evidence for one endpoint on a scanned surface: the given distance and
    /// observations (defaults when missing or invalid), the room's tracking fraction, unknown
    /// depth confidence.
    static func evidence(distance: Float?, observations: Int?, room: RoomEvidence,
                         snap: MeasurementSnapKind) -> MeasurementEvidence {
        var d = defaultDistance
        if let given = distance, given.isFinite, given > 0 { d = given }
        let n = observations.map { max(0, $0) } ?? defaultObservations
        return MeasurementEvidence(distance: d, depthConfidence: nil, observations: n,
                                   trackingNormalFraction: room.trackingNormalFraction, snap: snap)
    }

    /// Sigma a value contributes to a combination: 0 for user values, its finite sigma for
    /// measured and estimated values, nil when that sigma is missing (the result then has none).
    private static func sigmaContribution(_ v: MeasuredValue) -> Double? {
        if v.provenance == .user { return 0 }
        guard let s = v.sigma, s.isFinite else { return nil }
        return abs(s)
    }
}
