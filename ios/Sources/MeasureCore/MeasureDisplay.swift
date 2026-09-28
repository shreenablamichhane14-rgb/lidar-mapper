import Foundation

/// The text every screen shows for a measured value (docs/ARCHITECTURE.md 8.2 and 8.3): the
/// value in the user's units, the accuracy line, the one low-confidence rule and the VoiceOver
/// phrase. All number formatting goes through `ios/Sources/Units/`.
///
/// Provenance rules: measured and estimated values show value plus accuracy text; inferred
/// values show value plus `Copy.Measure.notMeasured` and no plus-minus; user values show no
/// plus-minus. The accuracy is 2 sigma, floored at 1 cm (RESEARCH section 1) and rounded up to
/// the display step (0.5 cm, 0.1 in under an inch, the preferred inch fraction above), so the
/// shown figure is never smaller than the computed one.
enum MeasureDisplay {
    /// Smallest accuracy shown for a length, meters (RESEARCH: 2 sigma floored at 1 cm).
    static let minimumShownLength: Double = 0.01
    /// Smallest accuracy shown for an area, square meters.
    static let minimumShownArea: Double = 0.01
    /// Smallest accuracy shown for a volume, cubic meters.
    static let minimumShownVolume: Double = 0.01
    /// Smallest accuracy shown for an angle, degrees.
    static let minimumShownAngleDegrees: Double = 0.1
    /// Metric display step for length accuracy, meters (RESEARCH: rounded up to 0.5 cm).
    static let metricLengthStep: Double = 0.005
    /// Imperial display step for length accuracy under one inch, inches (RESEARCH: 0.1 in).
    static let imperialSmallStepInches: Double = 0.1
    /// Display steps for area and volume accuracy (the resolution of AreaFormat and VolumeFormat).
    static let metricAreaStep: Double = 0.01, imperialAreaStepSquareFeet: Double = 0.1
    static let metricVolumeStep: Double = 0.01, imperialVolumeStepCubicFeet: Double = 0.1
    /// Relative slack so a value that is already on a step is not pushed to the next one.
    private static let stepSlack: Double = 1e-6

    // MARK: - Low confidence

    /// The one rule every screen uses (CR-2): returns `value.isLowConfidence(length: length)` from
    /// Core, that is 2 sigma > max(0.04 m, 3 percent of `length`) for lengths and 2 sigma > 3 percent
    /// of the value for areas and volumes (`length` nil). False without sigma.
    static func isLowConfidence(_ value: MeasuredValue, length: Double?) -> Bool {
        value.isLowConfidence(length: length)
    }

    /// The same rule with the `length` argument chosen from the kind (`lengthArgument`).
    static func isLowConfidence(_ value: MeasuredValue, kind: MeasurementKind) -> Bool {
        isLowConfidence(value, length: lengthArgument(value, kind: kind))
    }

    /// The `length` argument of the rule: the value itself for lengths, nil for areas,
    /// volumes and angles (same mapping as Core's `isLowConfidence(kind:)`).
    static func lengthArgument(_ value: MeasuredValue, kind: MeasurementKind) -> Double? {
        isLength(kind) ? value.value : nil
    }

    /// True for kinds measured in meters.
    static func isLength(_ kind: MeasurementKind) -> Bool {
        switch kind {
        case .distance, .wallLength, .height, .perimeter: return true
        case .area, .volume, .angle: return false
        }
    }

    // MARK: - Text

    /// Value text in the user's units: LengthFormat.display / AreaFormat.display / VolumeFormat / AngleFormat.
    static func valueText(_ value: MeasuredValue, kind: MeasurementKind, prefs: UnitPreferences) -> String {
        switch kind {
        case .distance, .wallLength, .height, .perimeter:
            return LengthFormat.display(value.value, prefs: prefs)
        case .area:
            return AreaFormat.display(value.value, prefs: prefs)
        case .volume:
            return prefs.showBoth ? VolumeFormat.both(value.value, prefs: prefs)
                                  : VolumeFormat.primary(value.value, prefs: prefs)
        case .angle:
            return AngleFormat.degrees(value.value * 180 / Double.pi)
        }
    }

    /// "Estimated accuracy ±0.6\"" (Copy.Measure.accuracy with Tolerance.plusMinus minus its leading
    /// "±", because Copy adds the sign), Copy.Measure.lowConfidence, Copy.Measure.notMeasured for
    /// inferred values, or nil when there is no sigma.
    static func accuracyText(_ value: MeasuredValue, kind: MeasurementKind, prefs: UnitPreferences) -> String? {
        switch value.provenance {
        case .inferred: return Copy.Measure.notMeasured
        case .user: return nil
        case .measured, .estimated: break
        }
        guard let sigma = value.sigma, sigma.isFinite else { return nil }
        if isLowConfidence(value, kind: kind) { return Copy.Measure.lowConfidence }
        guard let body = toleranceText(sigma: sigma, kind: kind, prefs: prefs) else { return nil }
        return Copy.Measure.accuracy(body)
    }

    /// VoiceOver text: "Wall length, 12 feet 7 and 3 eighths inches, Estimated accuracy plus or
    /// minus 1.2 inches" (Copy.A11y.measurement, Copy.Measure.accuracySpoken, units spoken in full).
    static func accessibilityText(label: String, value: MeasuredValue, kind: MeasurementKind, prefs: UnitPreferences) -> String {
        let spokenValue = MeasureSpoken.text(valueText(value, kind: kind, prefs: prefs))
        let measurement = Copy.A11y.measurement(label, value: spokenValue)
        guard let accuracy = spokenAccuracy(value, kind: kind, prefs: prefs) else { return measurement }
        return Copy.MeasureCore.spokenWithAccuracy(measurement, accuracy: accuracy)
    }

    /// The accuracy part of `accessibilityText`, or nil when nothing is said about accuracy.
    static func spokenAccuracy(_ value: MeasuredValue, kind: MeasurementKind, prefs: UnitPreferences) -> String? {
        switch value.provenance {
        case .inferred: return Copy.Measure.notMeasured
        case .user: return nil
        case .measured, .estimated: break
        }
        guard let sigma = value.sigma, sigma.isFinite else { return nil }
        if isLowConfidence(value, kind: kind) { return Copy.Measure.lowConfidence }
        guard let body = toleranceText(sigma: sigma, kind: kind, prefs: prefs) else { return nil }
        return Copy.Measure.accuracySpoken(MeasureSpoken.text(body))
    }

    /// The shown accuracy without the plus-minus sign ("0.6\"", "30 mm", "1.2 sq ft"): 2 sigma,
    /// floored and rounded up to the display step of the preferred system. Nil for invalid input.
    static func toleranceText(sigma: Double, kind: MeasurementKind, prefs: UnitPreferences) -> String? {
        guard sigma.isFinite else { return nil }
        let twoSigma = 2 * abs(sigma)
        let text: String
        switch kind {
        case .distance, .wallLength, .height, .perimeter:
            let shown = shownLength(twoSigma, prefs: prefs)
            text = withoutPlusMinus(Tolerance.plusMinus(shown, prefs: prefs))
        case .area:
            let step = prefs.system == .metric
                ? metricAreaStep : imperialAreaStepSquareFeet / AreaFormat.squareFeetPerSquareMeter
            let shown = roundedUp(max(twoSigma, minimumShownArea), step: step)
            text = AreaFormat.primary(shown, prefs: prefs)
        case .volume:
            let step = prefs.system == .metric
                ? metricVolumeStep : imperialVolumeStepCubicFeet / VolumeFormat.cubicFeetPerCubicMeter
            let shown = roundedUp(max(twoSigma, minimumShownVolume), step: step)
            text = VolumeFormat.primary(shown, prefs: prefs)
        case .angle:
            let degrees = twoSigma * 180 / Double.pi
            let shown = roundedUp(max(degrees, minimumShownAngleDegrees), step: minimumShownAngleDegrees)
            text = AngleFormat.degrees(shown)
        }
        return text == LengthFormat.invalid ? nil : text
    }

    // MARK: - Helpers

    /// A length accuracy (meters) floored at 1 cm and rounded up to the display step: 0.5 cm in
    /// metric; 0.1 in under an inch and the preferred fraction of an inch above in imperial.
    static func shownLength(_ meters: Double, prefs: UnitPreferences) -> Double {
        let floored = max(meters, minimumShownLength)
        switch prefs.system {
        case .metric:
            return roundedUp(floored, step: metricLengthStep)
        case .imperial:
            let inch = LengthFormat.metersPerInch
            let small = roundedUp(floored / inch, step: imperialSmallStepInches)
            if small < 1 { return small * inch }
            let fraction = 1.0 / Double(prefs.fraction.rawValue)
            return roundedUp(floored / inch, step: fraction) * inch
        }
    }

    /// Rounds `x` up to a multiple of `step` (values already on a step stay there).
    static func roundedUp(_ x: Double, step: Double) -> Double {
        guard x.isFinite, step > 0 else { return x }
        let units = (x / step - stepSlack).rounded(.up)
        return max(units, 1) * step
    }

    /// Drops the leading plus-minus sign of a `Tolerance` text (Copy adds its own).
    private static func withoutPlusMinus(_ text: String) -> String {
        guard text.hasPrefix("\u{00B1}") else { return text }
        return String(text.dropFirst())
    }
}
