import Foundation

/// Plain-Swift checks for the units module (no XCTest), meant to run at launch in
/// debug builds. `run()` returns one line per failing case; empty means all passed.
enum UnitsSelfTest {
    /// Failing cases as "name: expected X, got Y".
    static func run() -> [String] {
        var failures: [String] = []
        var count = 0

        func expect(_ name: String, _ actual: String, _ expected: String) {
            count += 1
            if actual != expected {
                failures.append("\(name): expected \(expected), got \(actual)")
            }
        }

        func expectMeters(_ name: String, _ actual: Double?, _ expected: Double?, within tolerance: Double = 1e-6) {
            count += 1
            switch (actual, expected) {
            case (nil, nil):
                return
            case let (a?, e?) where abs(a - e) <= tolerance:
                return
            default:
                let a = actual.map { "\($0)" } ?? "nil"
                let e = expected.map { "\($0)" } ?? "nil"
                failures.append("\(name): expected \(e), got \(a)")
            }
        }

        let inch = LengthFormat.metersPerInch
        let imperial8 = UnitPreferences.standard
        let imperial16 = UnitPreferences(system: .imperial, fraction: .sixteenth, showBoth: true)
        let metric = UnitPreferences(system: .metric, fraction: .eighth, showBoth: true)
        let metricOnly = UnitPreferences(system: .metric, fraction: .eighth, showBoth: false)

        // Feet-inches
        expect("feetInches.spec", LengthFormat.feetInches(3.845, denominator: .eighth), "12' 7 3/8\"")
        expect("feetInches.sixteenthReduces", LengthFormat.feetInches(3.845, denominator: .sixteenth), "12' 7 3/8\"")
        expect("feetInches.zero", LengthFormat.feetInches(0, denominator: .eighth), "0\"")
        expect("feetInches.carry16", LengthFormat.feetInches(11.99 * inch, denominator: .sixteenth), "1' 0\"")
        expect("feetInches.carry8", LengthFormat.feetInches(11.99 * inch, denominator: .eighth), "1' 0\"")
        expect("feetInches.underFoot", LengthFormat.feetInches(7.375 * inch, denominator: .eighth), "7 3/8\"")
        expect("feetInches.underInch", LengthFormat.feetInches(0.375 * inch, denominator: .eighth), "3/8\"")
        expect("feetInches.sixteenthOnly", LengthFormat.feetInches(inch / 16, denominator: .sixteenth), "1/16\"")
        expect("feetInches.tinyRoundsToZero", LengthFormat.feetInches(0.9 * inch / 16, denominator: .eighth), "0\"")
        expect("feetInches.negative", LengthFormat.feetInches(-3.845, denominator: .eighth), "-12' 7 3/8\"")
        expect("feetInches.negativeZero", LengthFormat.feetInches(-0.0001, denominator: .eighth), "0\"")
        expect("feetInches.exactFeet", LengthFormat.feetInches(3.048, denominator: .eighth), "10' 0\"")
        expect("feetInches.oddSixteenth", LengthFormat.feetInches(5.0625 * inch, denominator: .sixteenth), "5 1/16\"")
        expect("feetInches.half", LengthFormat.feetInches(2.5 * inch, denominator: .sixteenth), "2 1/2\"")
        expect("feetInches.zeroInchesWithFraction", LengthFormat.feetInches(12.25 * inch, denominator: .eighth), "1' 0 1/4\"")
        expect("feetInches.nan", LengthFormat.feetInches(Double.nan, denominator: .eighth), "--")
        expect("feetInches.infinity", LengthFormat.feetInches(-Double.infinity, denominator: .eighth), "--")

        // Metric
        expect("metric.mm", LengthFormat.metric(0.845), "845 mm")
        expect("metric.m3dp", LengthFormat.metric(3.845), "3.845 m")
        expect("metric.over10m", LengthFormat.metric(12.3456), "12.35 m")
        expect("metric.zero", LengthFormat.metric(0), "0 mm")
        expect("metric.negative", LengthFormat.metric(-0.845), "-845 mm")
        expect("metric.negativeOver10m", LengthFormat.metric(-12.3456), "-12.35 m")
        expect("metric.roundsUpTo1m", LengthFormat.metric(0.9996), "1.000 m")
        expect("metric.exactly1m", LengthFormat.metric(1.0), "1.000 m")
        expect("metric.roundsUpTo10m", LengthFormat.metric(9.9996), "10.00 m")
        expect("metric.negativeTinyIsZero", LengthFormat.metric(-0.0004), "0 mm")
        expect("metric.nan", LengthFormat.metric(Double.nan), "--")

        // Both / primary / display
        expect("both.imperial", LengthFormat.both(3.845, prefs: imperial8), "12' 7 3/8\" (3.845 m)")
        expect("both.metric", LengthFormat.both(3.845, prefs: metric), "3.845 m (12' 7 3/8\")")
        expect("both.infinity", LengthFormat.both(Double.infinity, prefs: imperial8), "--")
        expect("primary.imperial16", LengthFormat.primary(0.1285875, prefs: imperial16), "5 1/16\"")
        expect("primary.metric", LengthFormat.primary(3.845, prefs: metric), "3.845 m")
        expect("display.showBothOff", LengthFormat.display(3.845, prefs: metricOnly), "3.845 m")
        expect("display.showBothOn", LengthFormat.display(0.845, prefs: metric), "845 mm (2' 9 1/4\")")

        // Area, volume, angle
        expect("area.imperial", AreaFormat.imperial(10), "107.6 sq ft")
        expect("area.metric", AreaFormat.metric(10), "10.00 m\u{00B2}")
        expect("area.both", AreaFormat.both(10, prefs: imperial8), "107.6 sq ft (10.00 m\u{00B2})")
        expect("area.zero", AreaFormat.imperial(0), "0.0 sq ft")
        expect("area.nan", AreaFormat.both(Double.nan, prefs: metric), "--")
        expect("volume.imperial", VolumeFormat.imperial(1), "35.3 cu ft")
        expect("volume.metricBoth", VolumeFormat.both(2.5, prefs: metric), "2.50 m\u{00B3} (88.3 cu ft)")
        expect("angle.right", AngleFormat.degrees(90), "90.0\u{00B0}")
        expect("angle.decimal", AngleFormat.degrees(33.333), "33.3\u{00B0}")
        expect("angle.negativeZero", AngleFormat.degrees(-0.01), "0.0\u{00B0}")
        expect("angle.negative", AngleFormat.degrees(-12.34), "-12.3\u{00B0}")
        expect("angle.radians", AngleFormat.radians(Double.pi / 2), "90.0\u{00B0}")
        expect("angle.nan", AngleFormat.degrees(Double.nan), "--")

        // Tolerance
        expect("tolerance.subInch", Tolerance.plusMinus(0.6 * inch, prefs: imperial8), "\u{00B1}0.6\"")
        expect("tolerance.mm", Tolerance.plusMinus(0.015, prefs: metric), "\u{00B1}15 mm")
        expect("tolerance.fraction", Tolerance.plusMinus(1.5 * inch, prefs: imperial8), "\u{00B1}1 1/2\"")
        expect("tolerance.negativeInput", Tolerance.plusMinus(-0.6 * inch, prefs: imperial8), "\u{00B1}0.6\"")
        expect("tolerance.roundsToOneInch", Tolerance.plusMinus(0.99 * inch, prefs: imperial8), "\u{00B1}1\"")
        expect("tolerance.nan", Tolerance.plusMinus(Double.nan, prefs: metric), "--")

        // Parser
        let spec = 151.375 * inch
        expectMeters("parse.spec", LengthParser.meters(from: "12' 7 3/8\"", prefs: metric), spec)
        expectMeters("parse.ftIn", LengthParser.meters(from: "12 ft 7 in", prefs: metric), 151 * inch)
        expectMeters("parse.words", LengthParser.meters(from: "12 Feet 7 Inches", prefs: metric), 151 * inch)
        expectMeters("parse.decimalInches", LengthParser.meters(from: "7.5\"", prefs: metric), 7.5 * inch)
        expectMeters("parse.meters", LengthParser.meters(from: "3.845 m", prefs: imperial8), 3.845)
        expectMeters("parse.cm", LengthParser.meters(from: "384.5 cm", prefs: imperial8), 3.845)
        expectMeters("parse.mm", LengthParser.meters(from: "845 mm", prefs: imperial8), 0.845)
        expectMeters("parse.bareMetric", LengthParser.meters(from: "3.845", prefs: metric), 3.845)
        expectMeters("parse.bareImperialFeet", LengthParser.meters(from: "12", prefs: imperial8), 12 * 0.3048)
        expectMeters("parse.bareImperialFraction", LengthParser.meters(from: "7 3/8", prefs: imperial8), 7.375 * inch)
        expectMeters("parse.unicodePrimes", LengthParser.meters(from: "12\u{2032} 7 3\u{2044}8\u{2033}", prefs: metric), spec)
        expectMeters("parse.curlyQuotes", LengthParser.meters(from: "12\u{2019} 7\u{201D}", prefs: metric), 151 * inch)
        expectMeters("parse.noSpaces", LengthParser.meters(from: "12'7\"", prefs: metric), 151 * inch)
        expectMeters("parse.architecturalHyphen", LengthParser.meters(from: "12'-7 3/8\"", prefs: metric), spec)
        expectMeters("parse.trailingBareInches", LengthParser.meters(from: "12' 7", prefs: metric), 151 * inch)
        expectMeters("parse.negative", LengthParser.meters(from: "-2' 3\"", prefs: metric), -27 * inch)
        expectMeters("parse.padding", LengthParser.meters(from: "  3.845M  ", prefs: imperial8), 3.845)
        expectMeters("parse.bothOutput", LengthParser.meters(from: "12' 7 3/8\" (3.845 m)", prefs: metric), spec)
        expectMeters("parse.empty", LengthParser.meters(from: "", prefs: metric), nil)
        expectMeters("parse.garbage", LengthParser.meters(from: "abc", prefs: metric), nil)
        expectMeters("parse.mixedSystems", LengthParser.meters(from: "3 m 7 in", prefs: metric), nil)
        expectMeters("parse.wrongOrder", LengthParser.meters(from: "7 in 12 ft", prefs: metric), nil)
        expectMeters("parse.divideByZero", LengthParser.meters(from: "3/0\"", prefs: metric), nil)
        expectMeters("parse.twoDots", LengthParser.meters(from: "1.2.3 m", prefs: metric), nil)
        expectMeters("parse.twoBareNumbers", LengthParser.meters(from: "12 7", prefs: imperial8), nil)
        expectMeters("parse.dashes", LengthParser.meters(from: "--", prefs: metric), nil)

        // Round trips: format then parse, within 1 mm (1/16" rounding is at most 0.8 mm).
        for value in [0.001, 0.187325, 0.5, 1.2345, 3.845, 12.3456, 27.5, -3.845] {
            let text = LengthFormat.feetInches(value, denominator: .sixteenth)
            expectMeters("roundTrip.imperial16 \(text)", LengthParser.meters(from: text, prefs: imperial16), value, within: 0.001)
        }
        for value in [0.001, 0.845, 0.9996, 3.845, 9.87654, -2.5] {
            let text = LengthFormat.metric(value)
            expectMeters("roundTrip.metric \(text)", LengthParser.meters(from: text, prefs: imperial8), value, within: 0.001)
        }
        let bothText = LengthFormat.both(1.2345, prefs: metric)
        expectMeters("roundTrip.both \(bothText)", LengthParser.meters(from: bothText, prefs: imperial8), 1.2345, within: 0.001)

        // Preferences decoding never fails on partial or unknown data
        let decoder = JSONDecoder()
        let partial = try? decoder.decode(UnitPreferences.self, from: Data("{\"system\":\"metric\"}".utf8))
        expect("prefs.partialJSON", "\(partial == UnitPreferences(system: .metric, fraction: .eighth, showBoth: true))", "true")
        let unknown = try? decoder.decode(UnitPreferences.self, from: Data("{\"system\":\"furlongs\",\"fraction\":16}".utf8))
        expect("prefs.unknownSystem", "\(unknown == imperial16)", "true")
        let encoded = try? JSONEncoder().encode(metricOnly)
        let decoded = encoded.flatMap { try? decoder.decode(UnitPreferences.self, from: $0) }
        expect("prefs.jsonRoundTrip", "\(decoded == metricOnly)", "true")
        let suite = "com.shreehub.mapper.units-selftest"
        if let defaults = UserDefaults(suiteName: suite) {
            defaults.set(Data("not json".utf8), forKey: UnitPreferences.defaultsKey)
            expect("prefs.loadCorrupt", "\(UnitPreferences.load(from: defaults) == .standard)", "true")
            defaults.set("metric", forKey: UnitPreferences.defaultsKey)
            expect("prefs.loadLegacyString", "\(UnitPreferences.load(from: defaults).system)", "metric")
            metricOnly.save(to: defaults)
            expect("prefs.saveLoad", "\(UnitPreferences.load(from: defaults) == metricOnly)", "true")
            defaults.removePersistentDomain(forName: suite)
        }

        if failures.isEmpty && count < 40 {
            failures.append("selfTest: only \(count) cases ran")
        }
        return failures
    }

    /// One log line: "units self-test: all passed" or the failures joined.
    static func summary() -> String {
        let failures = run()
        if failures.isEmpty { return "units self-test: all passed" }
        return "units self-test: \(failures.count) failed: " + failures.joined(separator: "; ")
    }
}
