import Foundation

/// Parses typed lengths into meters: 12' 7 3/8", 12'-7", 12 ft 7 in, 7.5", 3.845 m,
/// 384.5 cm, 845 mm, or a bare number. Accepts Unicode primes, curly quotes, a
/// leading minus, and ignores anything from "(" on, so `LengthFormat.both` output
/// parses back. A bare number is meters in metric; in imperial it is feet, or inches
/// when it has a fraction (7 3/8). After feet, a trailing bare number is inches (12' 7).
enum LengthParser {
    /// Meters, or nil when the text is not a length.
    static func meters(from text: String, prefs: UnitPreferences) -> Double? {
        guard let tokens = tokenize(normalize(text)), !tokens.isEmpty else { return nil }

        var index = 0
        var negative = false
        if case .minus? = tokens.first {
            negative = true
            index = 1
        } else if case .plus? = tokens.first {
            index = 1
        }

        var components: [Component] = []
        while index < tokens.count {
            // Architectural hyphen: 12'-7 3/8"
            if case .minus = tokens[index], let last = components.last, last.unit == .feet {
                index += 1
                continue
            }
            guard let quantity = readQuantity(tokens, &index) else { return nil }
            var unit: ParsedUnit?
            if index < tokens.count, case .word(let word) = tokens[index] {
                guard let parsed = ParsedUnit(word: word) else { return nil }
                unit = parsed
                index += 1
            }
            components.append(Component(value: quantity.value, unit: unit, hasFraction: quantity.hasFraction))
        }
        guard !components.isEmpty else { return nil }

        var total = 0.0
        var previous: ParsedUnit?
        for (position, component) in components.enumerated() {
            let unit: ParsedUnit
            if let explicit = component.unit {
                unit = explicit
            } else if components.count == 1 {
                unit = bareUnit(prefs: prefs, hasFraction: component.hasFraction)
            } else if position == components.count - 1, previous == .feet {
                unit = .inches
            } else {
                return nil
            }
            if let previous = previous {
                // One system, largest unit first, no repeats.
                guard unit.isImperial == previous.isImperial,
                      unit.metersPerUnit < previous.metersPerUnit else { return nil }
            }
            total += component.value * unit.metersPerUnit
            previous = unit
        }
        guard total.isFinite else { return nil }
        return negative ? -total : total
    }

    // MARK: - Internals

    private enum Token {
        case number(Double)
        case slash
        case minus
        case plus
        case word(String)
    }

    private struct Component {
        var value: Double
        var unit: ParsedUnit?
        var hasFraction: Bool
    }

    private enum ParsedUnit {
        case feet, inches, meters, centimeters, millimeters

        init?(word: String) {
            switch word {
            case "'", "ft", "foot", "feet": self = .feet
            case "\"", "in", "inch", "inches": self = .inches
            case "m", "meter", "meters", "metre", "metres": self = .meters
            case "cm", "centimeter", "centimeters", "centimetre", "centimetres": self = .centimeters
            case "mm", "millimeter", "millimeters", "millimetre", "millimetres": self = .millimeters
            default: return nil
            }
        }

        var metersPerUnit: Double {
            switch self {
            case .feet: return LengthFormat.metersPerFoot
            case .inches: return LengthFormat.metersPerInch
            case .meters: return 1
            case .centimeters: return 0.01
            case .millimeters: return 0.001
            }
        }

        var isImperial: Bool { self == .feet || self == .inches }
    }

    private static func bareUnit(prefs: UnitPreferences, hasFraction: Bool) -> ParsedUnit {
        switch prefs.system {
        case .metric: return .meters
        case .imperial: return hasFraction ? .inches : .feet
        }
    }

    /// Lowercase, cut at "(", map primes, curly quotes and odd dashes to ASCII.
    private static func normalize(_ text: String) -> String {
        var result = text.lowercased()
        if let paren = result.firstIndex(of: "(") {
            result = String(result[..<paren])
        }
        let replacements: [(String, String)] = [
            ("\u{2032}", "'"), ("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{00B4}", "'"), ("`", "'"),
            ("\u{2033}", "\""), ("\u{201C}", "\""), ("\u{201D}", "\""), ("''", "\""),
            ("\u{2044}", "/"), ("\u{2215}", "/"),
            ("\u{2212}", "-"), ("\u{2013}", "-"), ("\u{2010}", "-"),
            ("\u{00A0}", " ")
        ]
        for (from, to) in replacements {
            result = result.replacingOccurrences(of: from, with: to)
        }
        return result
    }

    private static func tokenize(_ text: String) -> [Token]? {
        let digits: ClosedRange<Character> = "0"..."9"
        let chars = Array(text)
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                i += 1
            } else if digits.contains(c) || c == "." {
                var number = ""
                while i < chars.count, digits.contains(chars[i]) || chars[i] == "." {
                    number.append(chars[i])
                    i += 1
                }
                guard let value = Double(number), value.isFinite else { return nil }
                tokens.append(.number(value))
            } else if c.isLetter {
                var word = ""
                while i < chars.count, chars[i].isLetter {
                    word.append(chars[i])
                    i += 1
                }
                // Abbreviation dot: "ft." but not "m.5"
                if i < chars.count, chars[i] == ".", !(i + 1 < chars.count && digits.contains(chars[i + 1])) {
                    i += 1
                }
                tokens.append(.word(word))
            } else if c == "'" || c == "\"" {
                tokens.append(.word(String(c)))
                i += 1
            } else if c == "/" {
                tokens.append(.slash)
                i += 1
            } else if c == "-" {
                tokens.append(.minus)
                i += 1
            } else if c == "+" {
                tokens.append(.plus)
                i += 1
            } else {
                return nil
            }
        }
        return tokens
    }

    /// n, n/d, or w n/d starting at `index`; advances past it.
    private static func readQuantity(_ tokens: [Token], _ index: inout Int) -> (value: Double, hasFraction: Bool)? {
        guard index < tokens.count, case .number(let first) = tokens[index] else { return nil }
        index += 1
        if index + 1 < tokens.count, case .slash = tokens[index], case .number(let den) = tokens[index + 1] {
            guard den != 0 else { return nil }
            index += 2
            return (first / den, true)
        }
        if index + 2 < tokens.count, case .number(let num) = tokens[index],
           case .slash = tokens[index + 1], case .number(let den) = tokens[index + 2] {
            guard den != 0 else { return nil }
            index += 3
            return (first + num / den, true)
        }
        return (first, false)
    }
}
