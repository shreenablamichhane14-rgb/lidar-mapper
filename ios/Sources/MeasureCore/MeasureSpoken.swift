import Foundation

/// Rewrites text produced by `ios/Sources/Units/` so VoiceOver speaks the units in full
/// (docs/UX_COPY.md): `12' 7 3/8"` becomes "12 feet 7 and 3 eighths inches", `3.845 m` becomes
/// "3.845 meters", `0.6"` becomes "0.6 inches", `107.6 sq ft` becomes "107.6 square feet".
/// The numbers are exactly the ones Units produced; only unit symbols become words from
/// `Copy.MeasureCore.Spoken`. Text it does not recognize passes through unchanged.
enum MeasureSpoken {
    /// Spoken form of a Units string (value, both-systems value or tolerance without its sign).
    static func text(_ formatted: String) -> String {
        let tokens = formatted.split(separator: " ", omittingEmptySubsequences: true).map { String($0) }
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            let current = parts(tokens[i])
            if i + 1 < tokens.count {
                let next = parts(tokens[i + 1])
                if let merged = mergedPair(current, next) {
                    out.append(merged)
                    i += 2
                    continue
                }
            }
            out.append(current.leading + word(current.core) + current.trailing)
            i += 1
        }
        return out.joined(separator: " ")
    }

    // MARK: - Tokens

    /// A token split into leading "(", core text and trailing ")".
    private struct Token {
        /// Leading parentheses.
        var leading: String
        /// The token without parentheses.
        var core: String
        /// Trailing parentheses.
        var trailing: String
    }

    /// Splits the parentheses off a token.
    private static func parts(_ token: String) -> Token {
        var core = Substring(token)
        var leading = ""
        var trailing = ""
        while core.first == "(" {
            leading.append("(")
            core = core.dropFirst()
        }
        while core.last == ")" {
            trailing.append(")")
            core = core.dropLast()
        }
        return Token(leading: leading, core: String(core), trailing: trailing)
    }

    /// Two-token forms: "sq ft", "cu ft", and whole inches followed by a fraction ("7 3/8\"").
    private static func mergedPair(_ first: Token, _ second: Token) -> String? {
        guard first.trailing.isEmpty, second.leading.isEmpty else { return nil }
        if second.core == "ft" {
            if first.core == "sq" { return first.leading + Copy.MeasureCore.Spoken.squareFeet + second.trailing }
            if first.core == "cu" { return first.leading + Copy.MeasureCore.Spoken.cubicFeet + second.trailing }
            return nil
        }
        guard isInteger(first.core), second.core.hasSuffix("\"") else { return nil }
        guard let fraction = fractionParts(String(second.core.dropLast())), !fraction.negative else { return nil }
        let words = [number(first.core), Copy.MeasureCore.Spoken.and,
                     Copy.MeasureCore.Spoken.fraction(fraction.numerator, fraction.denominator),
                     Copy.MeasureCore.Spoken.inches]
        return first.leading + words.joined(separator: " ") + second.trailing
    }

    /// Spoken form of one token without parentheses.
    private static func word(_ core: String) -> String {
        switch core {
        case "mm": return Copy.MeasureCore.Spoken.millimeters
        case "m": return Copy.MeasureCore.Spoken.meters
        case "m\u{00B2}": return Copy.MeasureCore.Spoken.squareMeters
        case "m\u{00B3}": return Copy.MeasureCore.Spoken.cubicMeters
        default: break
        }
        if core.count > 1, core.hasSuffix("'") {
            let body = String(core.dropLast())
            guard isNumber(body) else { return core }
            let unit = isOne(body) ? Copy.MeasureCore.Spoken.foot : Copy.MeasureCore.Spoken.feet
            return number(body) + " " + unit
        }
        if core.count > 1, core.hasSuffix("\"") {
            let body = String(core.dropLast())
            if let fraction = fractionParts(body) {
                let spoken = Copy.MeasureCore.Spoken.fraction(fraction.numerator, fraction.denominator)
                    + " " + Copy.MeasureCore.Spoken.ofAnInch
                return fraction.negative ? Copy.MeasureCore.Spoken.minus + " " + spoken : spoken
            }
            guard isNumber(body) else { return core }
            let unit = isOne(body) ? Copy.MeasureCore.Spoken.inch : Copy.MeasureCore.Spoken.inches
            return number(body) + " " + unit
        }
        if core.count > 1, core.hasSuffix("\u{00B0}") {
            let body = String(core.dropLast())
            guard isNumber(body) else { return core }
            return number(body) + " " + Copy.MeasureCore.Spoken.degrees
        }
        return isNumber(core) ? number(core) : core
    }

    // MARK: - Numbers

    /// "a/b" or "-a/b" with positive integers, or nil.
    private static func fractionParts(_ text: String) -> (numerator: Int, denominator: Int, negative: Bool)? {
        let negative = text.hasPrefix("-")
        let body = negative ? String(text.dropFirst()) : text
        let pieces = body.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let numerator = Int(pieces[0]), let denominator = Int(pieces[1]),
              numerator > 0, denominator > 0 else { return nil }
        return (numerator, denominator, negative)
    }

    /// A number with a leading minus sign spoken as a word.
    private static func number(_ text: String) -> String {
        guard text.hasPrefix("-"), text.count > 1 else { return text }
        return Copy.MeasureCore.Spoken.minus + " " + String(text.dropFirst())
    }

    /// True for an optionally negative run of digits.
    private static func isInteger(_ text: String) -> Bool {
        let body = text.hasPrefix("-") ? String(text.dropFirst()) : text
        return !body.isEmpty && body.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// True for an optionally negative decimal number ("12", "3.845", "-0.6").
    private static func isNumber(_ text: String) -> Bool {
        let body = text.hasPrefix("-") ? String(text.dropFirst()) : text
        guard !body.isEmpty else { return false }
        var dots = 0
        for c in body {
            if c == "." {
                dots += 1
            } else if !(c.isASCII && c.isNumber) {
                return false
            }
        }
        return dots <= 1 && body != "."
    }

    /// True when the number is exactly one (singular unit word).
    private static func isOne(_ text: String) -> Bool {
        text == "1"
    }
}
