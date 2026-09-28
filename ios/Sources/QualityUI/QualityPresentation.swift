import Foundation

// Pure presentation rules of the scan quality sheet (docs/MODULES.md 3.25, ARCHITECTURE 10.5):
// scores to percent rows, tints, the summary line, the Finish title, the degraded-mode and
// light notes, and the missing area count. No computation beyond presentation (Quality owns
// the scores); everything here is nonisolated and safe on any queue, so the self-test runs it
// off the main actor.

/// Color class of one quality row: good at 0.9 and above, okay at 0.7 and above, poor below
/// (the `QualityVerdict` thresholds, so a row's color agrees with the verdict rule).
enum QualityTint: Equatable, Sendable {
    /// Green (0.9 and above), orange (0.7 and above) and red (below 0.7).
    case good, okay, poor

    /// The tint of a 0...1 score. NaN and infinities count as 0 (poor), as in `QualityVerdict.from`.
    init(score: Double) {
        let value = QualityPresentation.fraction(score)
        if value >= QualityVerdict.goodThreshold {
            self = .good
        } else if value >= QualityVerdict.okayThreshold {
            self = .okay
        } else {
            self = .poor
        }
    }

    /// The tint of a verdict (good, okay and poor map one to one), for the summary line.
    init(verdict: QualityVerdict) {
        switch verdict {
        case .good: self = .good
        case .okay: self = .okay
        case .poor: self = .poor
        }
    }

    /// The tint of the missing areas row: good when nothing is missing, okay otherwise (a count
    /// is not a score, so it never reads as poor on its own).
    init(missingAreas count: Int) {
        self = count > 0 ? .okay : .good
    }
}

/// One row of the quality sheet (Shape, Walls, Floor, Ceiling, Color and texture): the title,
/// the percent text, the bar fraction, the tint and the VoiceOver label ("Walls, 100 percent").
struct QualityRowModel: Identifiable, Equatable, Sendable {
    /// Stable row id: "shape", "walls", "floor", "ceiling" or "texture".
    var id: String
    /// Row title from `Copy.Quality` ("Walls").
    var title: String
    /// Percent text from `Copy.Quality.percent` ("94%").
    var percentText: String
    /// Bar length, 0...1 (the score clamped; NaN becomes 0).
    var fraction: Double
    /// Color class of the score.
    var tint: QualityTint
    /// VoiceOver label from `Copy.A11y.metric` ("Walls, 94 percent").
    var accessibility: String
}

/// Turns a `QualityEvaluation` into what the quality sheet shows. Pure functions.
enum QualityPresentation {
    /// Row ids in display order.
    static let rowIDs = ["shape", "walls", "floor", "ceiling", "texture"]
    /// `lightNote` appears when more than this share of keyframes were dark (ARCHITECTURE 5.8).
    static let darkNoteThreshold: Float = 0.3
    /// Seconds the "Checking your scan..." state waits before it also offers Finish Anyway and
    /// Discard (the check at Done has a 5 second budget; this keeps a stuck check from trapping
    /// the user on a sheet that cannot be swiped away).
    static let checkingSlowAfterSeconds: Double = 8

    // MARK: Rows

    /// Shape, Walls, Floor, Ceiling, Color and texture, in that order.
    static func rows(for evaluation: QualityEvaluation) -> [QualityRowModel] {
        rows(for: evaluation.summary)
    }

    /// The five rows of a stored summary (also usable for `RoomRecord.quality`).
    static func rows(for summary: QualitySummary) -> [QualityRowModel] {
        [
            row(id: rowIDs[0], title: Copy.Quality.geometry, score: summary.shape),
            row(id: rowIDs[1], title: Copy.Quality.walls, score: summary.walls),
            row(id: rowIDs[2], title: Copy.Quality.floor, score: summary.floor),
            row(id: rowIDs[3], title: Copy.Quality.ceiling, score: summary.ceiling),
            row(id: rowIDs[4], title: Copy.Quality.textures, score: summary.texture),
        ]
    }

    /// One row for a 0...1 score.
    static func row(id: String, title: String, score: Double) -> QualityRowModel {
        let shown = percent(score)
        return QualityRowModel(id: id, title: title, percentText: Copy.Quality.percent(shown),
                               fraction: fraction(score), tint: QualityTint(score: score),
                               accessibility: Copy.A11y.metric(title, percent: shown))
    }

    /// The score clamped to 0...1; NaN and infinities become 0.
    static func fraction(_ score: Double) -> Double {
        guard score.isFinite else { return 0 }
        return Swift.min(Swift.max(score, 0), 1)
    }

    /// Whole percent shown for a score, 0...100, rounded down so the sheet never overstates a
    /// scan (0.996 shows 99, never 100 while something is unobserved). A tiny epsilon keeps
    /// binary fractions such as 0.29 (28.999... times 100) on their intended value.
    static func percent(_ score: Double) -> Int {
        let scaled: Double = fraction(score) * 100 + 1e-9
        let whole: Double = scaled.rounded(.down)
        return Swift.min(Swift.max(Int(whole), 0), 100)
    }

    // MARK: Summary and Finish

    /// The summary line for a verdict (`Copy.Quality.summaryGood`, `summaryOkay`, `summaryPoor`).
    static func summaryText(_ verdict: QualityVerdict) -> String {
        switch verdict {
        case .good: return Copy.Quality.summaryGood
        case .okay: return Copy.Quality.summaryOkay
        case .poor: return Copy.Quality.summaryPoor
        }
    }

    /// The verdict the sheet shows: the stored verdict, except that a good verdict with missing
    /// areas reads as okay, so "Great scan. You're ready to finish." never sits next to a
    /// missing area count and a Finish Anyway button.
    static func displayVerdict(_ evaluation: QualityEvaluation) -> QualityVerdict {
        let verdict = evaluation.summary.verdict
        if verdict == .good && missingCount(evaluation) > 0 { return .okay }
        return verdict
    }

    /// The summary line of an evaluation (`summaryText` of `displayVerdict`).
    static func summaryText(for evaluation: QualityEvaluation) -> String {
        summaryText(displayVerdict(evaluation))
    }

    /// "Finish" when nothing is missing, else "Finish Anyway" (UX_COPY section 6).
    static func finishTitle(missingAreas: Int) -> String {
        missingAreas > 0 ? Copy.Quality.finishAnyway : Copy.Quality.finish
    }

    /// The Finish button title the sheet shows: Finish Anyway while the check has no result,
    /// when areas are missing, or when the verdict is poor (a scan with no walls reports no
    /// missing areas but is not complete); Finish otherwise. Never hides the finish path.
    static func finishTitle(for evaluation: QualityEvaluation?) -> String {
        guard let evaluation = evaluation else { return Copy.Quality.finishAnyway }
        if displayVerdict(evaluation) == .poor { return Copy.Quality.finishAnyway }
        return finishTitle(missingAreas: missingCount(evaluation))
    }

    // MARK: Missing areas

    /// The missing area count of an evaluation (`QualitySummary.missingAreas`, never negative).
    static func missingCount(_ evaluation: QualityEvaluation) -> Int {
        Swift.max(0, evaluation.summary.missingAreas)
    }

    /// The count shown next to "Missing areas" ("0", "3").
    static func missingText(count: Int) -> String {
        String(Swift.max(0, count))
    }

    /// VoiceOver label of the missing areas row ("Missing areas, 3").
    static func missingAccessibility(count: Int) -> String {
        Copy.A11y.measurement(Copy.Quality.missingAreas, value: missingText(count: count))
    }

    /// True when the sheet offers Show Missing Areas: the caller passed the action (build 5,
    /// running session only, D19) and there is at least one area to visit.
    static func showsMissingAreasButton(evaluation: QualityEvaluation?, actionAvailable: Bool) -> Bool {
        guard actionAvailable, let evaluation = evaluation else { return false }
        return missingCount(evaluation) > 0
    }

    // MARK: Notes

    /// One line about a degraded capture (D16); nil for `.allGood`.
    static func degradedNote(_ mode: DegradedMode) -> String? {
        switch mode {
        case .allGood: return nil
        case .depthStripped: return Copy.Quality.noteDepthStripped
        case .meshStripped: return Copy.Quality.noteMeshStripped
        case .roomPlanFailed: return Copy.Quality.noteRoomPlanFailed
        }
    }

    /// `Copy.Quality.noteDark` when more than 30 percent of keyframes were dark, else nil.
    static func lightNote(darkKeyframeFraction: Float) -> String? {
        guard darkKeyframeFraction.isFinite, darkKeyframeFraction > darkNoteThreshold else { return nil }
        return Copy.Quality.noteDark
    }

    /// The notes under the rows, degraded mode first, then light.
    static func notes(for evaluation: QualityEvaluation) -> [String] {
        let candidates: [String?] = [
            degradedNote(evaluation.degraded),
            lightNote(darkKeyframeFraction: evaluation.darkKeyframeFraction),
        ]
        return candidates.compactMap { $0 }
    }

    // MARK: Log

    /// The numbers the sheet shows, for the app log (TEST_PLAN QUAL-01: "the same numbers in
    /// the log"). Not user-facing.
    static func logLine(_ evaluation: QualityEvaluation) -> String {
        let s = evaluation.summary
        let scores = "shape \(percent(s.shape))%, walls \(percent(s.walls))%, floor \(percent(s.floor))%"
        let more = "ceiling \(percent(s.ceiling))%, texture \(percent(s.texture))%"
        let verdict = "verdict \(s.verdict.rawValue) (shown \(displayVerdict(evaluation).rawValue))"
        let darkPercent = percent(Double(evaluation.darkKeyframeFraction))
        let tail = "missing \(missingCount(evaluation)), \(verdict), degraded \(evaluation.degraded.rawValue), dark \(darkPercent)%"
        return "room \(evaluation.roomID.uuidString.prefix(8)): \(scores), \(more), \(tail)"
    }
}
