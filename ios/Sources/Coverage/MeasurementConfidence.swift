import Foundation
import simd

// Measurement confidence: an honest "Estimated accuracy +/-x" for every length the app shows,
// plus the "Low confidence - rescan this section" rule from docs/SPEC.txt (MEASUREMENT
// CONFIDENCE section). The on-screen wording lives in Copy.swift; this file only decides the
// number and the flag.
//
// Published iPhone LiDAR accuracy figures this model is grounded in
// (docs/research/raw/quality-coverage-measure.json, docs/research/raw/arkit-mesh-depth.json):
// - Small objects larger than 10 cm: about +/-1 cm absolute at close range
//   (Luetzenburg et al., Sci. Rep. 2021, iPhone 12 Pro).
// - Point cloud RMSE against known shapes about 2 cm (2.05 cm iPhone 12 Pro, 2.06 cm iPhone 15).
// - ARKit depth versus a Faro laser scanner: 3.7 cm median (ARKitScenes analysis).
// - Reasonable accuracy up to about 4 m, noisy toward the roughly 5 m LiDAR limit.
// - Building scale scans (iPhone 13 Pro, MDPI 2023): 69 to 83 percent of points within 5 cm
//   of a terrestrial laser scan.
// - Per point depth noise about 0.5 to 1 cm at 1 to 2 m and about 2 cm at 3 to 4 m.
// - RoomPlan per wall error up to +/-5 cm; RoomPlan drifts 0.5 to 2 percent over a room loop
//   (room scale length error 0.5 to 2 percent without loop closure).
// - Errors grow with distance and with path length (SLAM drift) and whenever tracking is
//   limited (excessive motion, insufficient features, relocalization).
// Apple publishes no accuracy specification for LiDAR, RoomPlan or Measure, so these constants
// are conservative engineering estimates, not a guarantee.
//
// FORMULA (all values in meters):
//
//   base(d)  = 0.005                                  for d <= 0.5
//            = 0.005 + 0.004 * (d - 0.5)              for 0.5 < d <= 4
//            = base(4) + 0.012 * (d - 4)              for d > 4 (steeper, noisy toward 5 m)
//     so base(1) = 0.007, base(2) = 0.011, base(3) = 0.015, base(4) = 0.019, base(5) = 0.031.
//
//   confidenceFactor(c) with c = mean depth confidence 0...1 (ARConfidenceLevel / 2):
//            = 3 - 3 * c              for c <= 0.5   (low = 3.0, medium = 1.5)
//            = 1.5 - (c - 0.5)        for c > 0.5    (high = 1.0)
//            = 1.5 when unknown (nil).
//   trackingFactor(f) with f = fraction of frames with normal tracking, 0...1:
//            = 1 + 2 * (1 - f)        (1.0 when always normal, 3.0 when never normal)
//   snapFactor: none 1.2, vertex 1.0, edge 0.9, plane 0.7, roomSurface 0.7
//            (a snap onto a fitted plane or RoomPlan surface averages many depth samples).
//   n = clamp(observations, 1, 9)
//
//   pointSigma = max(0.004, base(d) * confidenceFactor * trackingFactor * snapFactor / sqrt(n))
//     capped at 1.0 m so infinite or NaN inputs still give a finite (and alarming) number.
//
//   Length between endpoints A and B:
//   driftRate  = 0.002 + 0.018 * (1 - min(fA, fB))   (0.2 percent per meter with clean tracking,
//                up to 2 percent when tracking was never normal; a single wall is a fraction of
//                a room loop, so the 0.5 to 2 percent loop figure is the upper end)
//   accuracy   = sqrt(pointSigma(A)^2 + pointSigma(B)^2 + (driftRate * length)^2)
//   When both endpoints snapped to RoomPlan surfaces the accuracy is never better than
//   0.0125 m (RoomPlan derived lengths are no better than +/-2.5 cm at two sigma).
//
// MEANING OF `accuracy`: about one standard deviation, i.e. the typical error (roughly 68
// percent of measurements land within it). Example matching SPEC.txt: an 18 ft 7 in (5.66 m)
// wall with both endpoints snapped to RoomPlan surfaces from 2 m away, 9 observations, high
// confidence and clean tracking gives about 0.0126 m, shown as "Estimated accuracy +/-0.5 in".
//
// LOW CONFIDENCE RULE ("Low confidence - rescan this section" in SPEC.txt), true when ANY of:
//   1. accuracy > max(0.05 m, 3 percent of the length)   (0.05 m for a single point)
//   2. any endpoint trackingNormalFraction < 0.7
//   3. any endpoint has a known depthConfidence < 0.34   (mostly low confidence depth pixels)
//   4. any endpoint has observations <= 0                (no depth evidence at all)
// NaN inputs count as the worst value (NaN confidence or tracking fraction is 0, NaN distance is
// infinite); negative distances and observations are treated as 0.
//
// Monotonic by construction: accuracy is non-decreasing in distance and non-increasing in
// observations, depthConfidence and trackingNormalFraction, because every factor above is
// monotonic in its input and the floor, cap and sqrt are monotonic.

/// How a measured endpoint was placed: free (raw depth hit) or snapped to a mesh vertex, an
/// edge, a fitted plane or a RoomPlan surface.
enum MeasurementSnapKind: UInt8 {
    case none, vertex, edge, plane, roomSurface
}

/// Evidence for one measured endpoint.
struct MeasurementEvidence {
    /// Camera to point distance at capture, meters.
    var distance: Float
    /// Mean depth confidence 0...1 around the point (ARConfidenceLevel / 2), nil when unknown.
    var depthConfidence: Float?
    /// Number of depth observations supporting the point.
    var observations: Int
    /// Fraction 0...1 of frames with normal tracking during capture.
    var trackingNormalFraction: Float
    /// How the endpoint was snapped.
    var snap: MeasurementSnapKind
}

/// Accuracy estimate for one point or one length measurement.
struct MeasurementConfidence: Equatable {
    /// Estimated accuracy, +/- meters, about one standard deviation (see file header).
    var accuracy: Float
    /// True when the UI should show "Low confidence - rescan this section" (Copy.swift).
    var isLowConfidence: Bool

    // MARK: - Constants

    /// Base depth noise at close range (0.5 m or nearer), meters.
    static let closeRangeSigma: Float = 0.005
    /// Distance up to which `closeRangeSigma` applies, meters.
    static let closeRangeDistance: Float = 0.5
    /// Growth of base noise per meter between `closeRangeDistance` and `reliableRange`.
    static let sigmaPerMeter: Float = 0.004
    /// Distance up to which LiDAR accuracy is reasonable (published: about 4 m), meters.
    static let reliableRange: Float = 4.0
    /// Steeper growth of base noise per meter beyond `reliableRange` (noisy toward 5 m).
    static let sigmaPerMeterFar: Float = 0.012
    /// Maximum number of observations that still reduce noise (sqrt(9) = 3x improvement).
    static let observationCap: Int = 9
    /// Floor on per point sigma, meters.
    static let minimumPointSigma: Float = 0.004
    /// Cap on any accuracy value so infinite or NaN inputs stay finite, meters.
    static let maximumSigma: Float = 1.0
    /// Confidence factor used when depth confidence is unknown (same as medium).
    static let unknownConfidenceFactor: Float = 1.5
    /// Drift rate per meter of length with fully normal tracking (0.2 percent).
    static let baseDriftRate: Float = 0.002
    /// Additional drift rate per meter when tracking was never normal (up to 2 percent total).
    static let limitedTrackingDriftRate: Float = 0.018
    /// Minimum length accuracy when both endpoints snap to RoomPlan surfaces, meters.
    static let roomSurfaceLengthFloor: Float = 0.0125

    /// Absolute low confidence threshold on accuracy, meters.
    static let lowConfidenceAbsolute: Float = 0.05
    /// Relative low confidence threshold on accuracy, as a fraction of the length.
    static let lowConfidenceRelative: Float = 0.03
    /// Endpoints captured with less normal tracking than this are low confidence.
    static let minimumTrackingNormalFraction: Float = 0.7
    /// Endpoints with a known depth confidence below this are low confidence.
    static let minimumDepthConfidence: Float = 0.34

    // MARK: - Factors

    /// Base depth noise in meters as a function of camera distance (non-decreasing).
    static func baseSigma(distance: Float) -> Float {
        let d: Float = distance.isNaN ? Float.infinity : max(0, distance)
        if d <= closeRangeDistance { return closeRangeSigma }
        if d <= reliableRange {
            return closeRangeSigma + sigmaPerMeter * (d - closeRangeDistance)
        }
        let atReliable = closeRangeSigma + sigmaPerMeter * (reliableRange - closeRangeDistance)
        return atReliable + sigmaPerMeterFar * (d - reliableRange)
    }

    /// Multiplier from depth confidence: low (0) 3.0, medium (0.5) 1.5, high (1) 1.0, nil 1.5.
    static func confidenceFactor(_ confidence: Float?) -> Float {
        guard let raw = confidence else { return unknownConfidenceFactor }
        let c = mcfClamp01(raw)
        if c <= 0.5 { return 3 - 3 * c }
        return 1.5 - (c - 0.5)
    }

    /// Multiplier from tracking quality: 1.0 when always normal, up to 3.0 when never normal.
    static func trackingFactor(_ normalFraction: Float) -> Float {
        let f = mcfClamp01(normalFraction)
        return 1 + 2 * (1 - f)
    }

    /// Multiplier from the snapping type.
    static func snapFactor(_ snap: MeasurementSnapKind) -> Float {
        switch snap {
        case .none: return 1.2
        case .vertex: return 1.0
        case .edge: return 0.9
        case .plane: return 0.7
        case .roomSurface: return 0.7
        }
    }

    /// Drift rate per meter of length for a given worst endpoint tracking fraction.
    static func driftRate(trackingNormalFraction: Float) -> Float {
        let f = mcfClamp01(trackingNormalFraction)
        return baseDriftRate + limitedTrackingDriftRate * (1 - f)
    }

    // MARK: - Estimates

    /// Per point accuracy (about one sigma) in meters; see the file header for the formula.
    static func pointAccuracy(_ e: MeasurementEvidence) -> Float {
        let n = Float(min(max(e.observations, 1), observationCap))
        let raw = baseSigma(distance: e.distance)
            * confidenceFactor(e.depthConfidence)
            * trackingFactor(e.trackingNormalFraction)
            * snapFactor(e.snap)
            / n.squareRoot()
        return mcfBound(raw, lower: minimumPointSigma)
    }

    /// Length measurement between two endpoints: root-sum-square of endpoint accuracies plus
    /// drift proportional to length.
    static func estimate(start: MeasurementEvidence, end: MeasurementEvidence, length: Float) -> MeasurementConfidence {
        let len: Float = length.isNaN ? 0 : max(0, length)
        let a = pointAccuracy(start)
        let b = pointAccuracy(end)
        let worstTracking = min(mcfClamp01(start.trackingNormalFraction), mcfClamp01(end.trackingNormalFraction))
        let drift = driftRate(trackingNormalFraction: worstTracking) * min(len, 1_000)
        var accuracy = (a * a + b * b + drift * drift).squareRoot()
        if start.snap == .roomSurface && end.snap == .roomSurface {
            accuracy = max(accuracy, roomSurfaceLengthFloor)
        }
        accuracy = mcfBound(accuracy, lower: minimumPointSigma)
        let threshold = max(lowConfidenceAbsolute, lowConfidenceRelative * len)
        let low = accuracy > threshold || isWeak(start) || isWeak(end)
        return MeasurementConfidence(accuracy: accuracy, isLowConfidence: low)
    }

    /// Accuracy of a single measured point (for example a height above the floor snapped to a point).
    static func estimate(point: MeasurementEvidence) -> MeasurementConfidence {
        let accuracy = pointAccuracy(point)
        let low = accuracy > lowConfidenceAbsolute || isWeak(point)
        return MeasurementConfidence(accuracy: accuracy, isLowConfidence: low)
    }

    /// True when an endpoint's evidence alone forces low confidence (rules 2 to 4 in the header).
    static func isWeak(_ e: MeasurementEvidence) -> Bool {
        if e.observations <= 0 { return true }
        if mcfClamp01(e.trackingNormalFraction) < minimumTrackingNormalFraction { return true }
        if let c = e.depthConfidence, mcfClamp01(c) < minimumDepthConfidence { return true }
        return false
    }
}

/// Clamps to 0...1, mapping NaN to 0 (the worst value for confidences and fractions).
private func mcfClamp01(_ x: Float) -> Float {
    if x.isNaN { return 0 }
    return min(max(x, 0), 1)
}

/// Clamps a sigma into lower...MeasurementConfidence.maximumSigma, mapping NaN to the maximum.
private func mcfBound(_ x: Float, lower: Float) -> Float {
    if x.isNaN { return MeasurementConfidence.maximumSigma }
    return min(max(x, lower), MeasurementConfidence.maximumSigma)
}
