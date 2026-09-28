import Foundation

/// Formats lengths given in meters: feet-inches with reduced fractions, metric with
/// size-dependent precision, or both. Non-finite input gives "--".
enum LengthFormat {
    static let metersPerInch = 0.0254
    static let metersPerFoot = 0.3048
    /// Shown for NaN, infinity and absurdly large values.
    static let invalid = "--"
    /// Largest count of inch fractions converted to Int (far beyond any real scan).
    private static let maxFractionUnits = 1.0e15

    /// 12' 7 3/8", 7 3/8", 3/8", 1' 0", 0". Rounds to the nearest 1/8 or 1/16 inch with
    /// carry into inches and feet; negative values keep a leading minus.
    static func feetInches(_ meters: Double, denominator: FractionDenominator) -> String {
        guard meters.isFinite else { return invalid }
        let den = denominator.rawValue
        let scaled = (abs(meters) / metersPerInch * Double(den)).rounded()
        guard scaled < maxFractionUnits else { return invalid }
        let total = Int(scaled)
        if total == 0 { return "0\"" }

        let unitsPerFoot = 12 * den
        let feet = total / unitsPerFoot
        let remainder = total % unitsPerFoot
        let wholeInches = remainder / den
        let numerator = remainder % den

        let inchText: String
        if numerator == 0 {
            inchText = "\(wholeInches)"
        } else {
            let divisor = gcd(numerator, den)
            let fraction = "\(numerator / divisor)/\(den / divisor)"
            inchText = (feet == 0 && wholeInches == 0) ? fraction : "\(wholeInches) \(fraction)"
        }
        let sign = meters < 0 ? "-" : ""
        if feet == 0 { return "\(sign)\(inchText)\"" }
        return "\(sign)\(feet)' \(inchText)\""
    }

    /// 845 mm under 1 m, 3.845 m from 1 m to 10 m, 12.35 m from 10 m up.
    static func metric(_ meters: Double) -> String {
        guard meters.isFinite else { return invalid }
        let millimeters = (abs(meters) * 1000).rounded()
        if millimeters < 1000 { return "\(decimal(meters * 1000, places: 0)) mm" }
        if millimeters < 10_000 { return "\(decimal(meters, places: 3)) m" }
        return "\(decimal(meters, places: 2)) m"
    }

    /// The preferred system only.
    static func primary(_ meters: Double, prefs: UnitPreferences) -> String {
        switch prefs.system {
        case .imperial: return feetInches(meters, denominator: prefs.fraction)
        case .metric: return metric(meters)
        }
    }

    /// Preferred system first, the other in parentheses: 12' 7 3/8" (3.845 m).
    static func both(_ meters: Double, prefs: UnitPreferences) -> String {
        guard meters.isFinite else { return invalid }
        let imperial = feetInches(meters, denominator: prefs.fraction)
        switch prefs.system {
        case .imperial: return "\(imperial) (\(metric(meters)))"
        case .metric: return "\(metric(meters)) (\(imperial))"
        }
    }

    /// `both` when `prefs.showBoth` is on, otherwise `primary`.
    static func display(_ meters: Double, prefs: UnitPreferences) -> String {
        prefs.showBoth ? both(meters, prefs: prefs) : primary(meters, prefs: prefs)
    }

    /// Fixed decimals, rounded half away from zero, never "-0.0".
    static func decimal(_ value: Double, places: Int) -> String {
        guard value.isFinite else { return invalid }
        let scale = pow(10.0, Double(places))
        let scaled = (abs(value) * scale).rounded()
        let sign = (value < 0 && scaled > 0) ? "-" : ""
        return sign + String(format: "%.\(places)f", scaled / scale)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = a
        var y = b
        while y != 0 {
            (x, y) = (y, x % y)
        }
        return x
    }
}

/// Formats areas given in square meters: sq ft to 1 decimal, m² to 2 decimals.
enum AreaFormat {
    static let squareFeetPerSquareMeter = 1.0 / (0.3048 * 0.3048)

    /// 107.6 sq ft
    static func imperial(_ squareMeters: Double) -> String {
        guard squareMeters.isFinite else { return LengthFormat.invalid }
        return "\(LengthFormat.decimal(squareMeters * squareFeetPerSquareMeter, places: 1)) sq ft"
    }

    /// 10.00 m²
    static func metric(_ squareMeters: Double) -> String {
        guard squareMeters.isFinite else { return LengthFormat.invalid }
        return "\(LengthFormat.decimal(squareMeters, places: 2)) m\u{00B2}"
    }

    /// The preferred system only.
    static func primary(_ squareMeters: Double, prefs: UnitPreferences) -> String {
        prefs.system == .imperial ? imperial(squareMeters) : metric(squareMeters)
    }

    /// 107.6 sq ft (10.00 m²), preferred system first.
    static func both(_ squareMeters: Double, prefs: UnitPreferences) -> String {
        guard squareMeters.isFinite else { return LengthFormat.invalid }
        switch prefs.system {
        case .imperial: return "\(imperial(squareMeters)) (\(metric(squareMeters)))"
        case .metric: return "\(metric(squareMeters)) (\(imperial(squareMeters)))"
        }
    }

    /// `both` when `prefs.showBoth` is on, otherwise `primary`.
    static func display(_ squareMeters: Double, prefs: UnitPreferences) -> String {
        prefs.showBoth ? both(squareMeters, prefs: prefs) : primary(squareMeters, prefs: prefs)
    }
}

/// Formats volumes given in cubic meters: cu ft to 1 decimal, m³ to 2 decimals.
enum VolumeFormat {
    static let cubicFeetPerCubicMeter = 1.0 / (0.3048 * 0.3048 * 0.3048)

    /// 35.3 cu ft
    static func imperial(_ cubicMeters: Double) -> String {
        guard cubicMeters.isFinite else { return LengthFormat.invalid }
        return "\(LengthFormat.decimal(cubicMeters * cubicFeetPerCubicMeter, places: 1)) cu ft"
    }

    /// 1.00 m³
    static func metric(_ cubicMeters: Double) -> String {
        guard cubicMeters.isFinite else { return LengthFormat.invalid }
        return "\(LengthFormat.decimal(cubicMeters, places: 2)) m\u{00B3}"
    }

    /// The preferred system only.
    static func primary(_ cubicMeters: Double, prefs: UnitPreferences) -> String {
        prefs.system == .imperial ? imperial(cubicMeters) : metric(cubicMeters)
    }

    /// 35.3 cu ft (1.00 m³), preferred system first.
    static func both(_ cubicMeters: Double, prefs: UnitPreferences) -> String {
        guard cubicMeters.isFinite else { return LengthFormat.invalid }
        switch prefs.system {
        case .imperial: return "\(imperial(cubicMeters)) (\(metric(cubicMeters)))"
        case .metric: return "\(metric(cubicMeters)) (\(imperial(cubicMeters)))"
        }
    }
}

/// Formats angles to 1 decimal degree: 90.0°.
enum AngleFormat {
    /// From degrees.
    static func degrees(_ degrees: Double) -> String {
        guard degrees.isFinite else { return LengthFormat.invalid }
        return "\(LengthFormat.decimal(degrees, places: 1))\u{00B0}"
    }

    /// From radians.
    static func radians(_ radians: Double) -> String {
        degrees(radians * 180 / Double.pi)
    }
}

/// Formats measurement accuracy as ±0.6" or ±15 mm (sign ignored).
enum Tolerance {
    /// Imperial: inches to 1 decimal under 1", otherwise feet-inches with the preferred
    /// fraction. Metric: same rules as `LengthFormat.metric`.
    static func plusMinus(_ meters: Double, prefs: UnitPreferences) -> String {
        guard meters.isFinite else { return LengthFormat.invalid }
        let magnitude = abs(meters)
        switch prefs.system {
        case .imperial:
            let inches = magnitude / LengthFormat.metersPerInch
            if (inches * 10).rounded() < 10 {
                return "\u{00B1}\(LengthFormat.decimal(inches, places: 1))\""
            }
            let text = LengthFormat.feetInches(magnitude, denominator: prefs.fraction)
            return text == LengthFormat.invalid ? text : "\u{00B1}\(text)"
        case .metric:
            let text = LengthFormat.metric(magnitude)
            return text == LengthFormat.invalid ? text : "\u{00B1}\(text)"
        }
    }
}
