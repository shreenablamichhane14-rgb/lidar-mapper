import Foundation

/// Plain-Swift checks for QualityUI (no XCTest), run from the Diagnostics suite list off the
/// main actor. Pure and deterministic: only `QualityPresentation`, `QualityTint` and the tint
/// symbols are exercised, on fixed evaluations; no views, files, clock, camera or ARKit.
enum QualityUISelfTest {
    /// Failing checks as "name: detail"; empty when all pass.
    static func run() -> [String] {
        var failures: [String] = []
        rowChecks(&failures)
        percentChecks(&failures)
        tintChecks(&failures)
        finishChecks(&failures)
        noteChecks(&failures)
        summaryChecks(&failures)
        missingChecks(&failures)
        copyChecks(&failures)
        return failures
    }

    /// Records a failure when `ok` is false.
    private static func check(_ failures: inout [String], _ name: String, _ ok: Bool, _ detail: @autoclosure () -> String) {
        if !ok { failures.append("\(name): \(detail())") }
    }

    // MARK: Fixtures

    /// Fixed room id (the log line prints its first 8 characters).
    private static let roomID = UUID(uuid: (0x51, 0x7A, 0x11, 0x7E, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 1))

    /// An evaluation with the given scores, `missing` placeholder areas, mode and dark share.
    private static func evaluation(shape: Double = 1, walls: Double = 1, floor: Double = 1, ceiling: Double = 1,
                                   texture: Double = 1, missing: Int = 0, degraded: DegradedMode = .allGood,
                                   dark: Float = 0) -> QualityEvaluation {
        let summary = QualitySummary(shape: shape, walls: walls, floor: floor, ceiling: ceiling, texture: texture,
                                     missingAreas: missing)
        let records = (0..<Swift.max(0, missing)).map { index in
            MissingAreaRecord(id: index, centroid: Vec3(x: Float(index), y: 1, z: 0), normal: Vec3(x: 0, y: 0, z: 1),
                              area: 0.5, surface: 1, suggestedViewpoint: Vec3(x: Float(index), y: 1.4, z: 1.5))
        }
        return QualityEvaluation(roomID: roomID, summary: summary, missingAreas: records, degraded: degraded,
                                 evidence: RoomEvidence.unknown, darkKeyframeFraction: dark, inputHash: "selftest",
                                 evaluatedAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    // MARK: Rows

    /// Order, ids, titles, percent text and VoiceOver labels of the five rows.
    private static func rowChecks(_ failures: inout [String]) {
        let rows = QualityPresentation.rows(for: evaluation(shape: 0.943, walls: 1, floor: 0.8, ceiling: 0.5, texture: 0.29))
        let titles = rows.map { $0.title }
        let wantTitles = [Copy.Quality.geometry, Copy.Quality.walls, Copy.Quality.floor, Copy.Quality.ceiling,
                          Copy.Quality.textures]
        check(&failures, "rows.titles", titles == wantTitles, "got \(titles)")
        check(&failures, "rows.ids", rows.map { $0.id } == QualityPresentation.rowIDs, "got \(rows.map { $0.id })")
        check(&failures, "rows.uniqueIDs", Set(rows.map { $0.id }).count == rows.count, "duplicate row id")
        let percents = rows.map { $0.percentText }
        check(&failures, "rows.percent", percents == ["94%", "100%", "80%", "50%", "29%"], "got \(percents)")
        let walls = rows.first { $0.id == "walls" }
        check(&failures, "rows.a11y.walls", walls?.accessibility == "Walls, 100 percent",
              "got \(walls?.accessibility ?? "nil")")
        let shape = rows.first { $0.id == "shape" }
        check(&failures, "rows.a11y.shape", shape?.accessibility == "Shape, 94 percent",
              "got \(shape?.accessibility ?? "nil")")
        let tints = rows.map { $0.tint }
        check(&failures, "rows.tints", tints == [.good, .good, .okay, .poor, .poor], "got \(tints)")
        let summaryRows = QualityPresentation.rows(for: QualitySummary(shape: 0.943, walls: 1, floor: 0.8, ceiling: 0.5,
                                                                       texture: 0.29, missingAreas: 0))
        check(&failures, "rows.summaryOverload", summaryRows == rows, "summary and evaluation rows differ")
    }

    /// Percent rounding, clamping and the bar fraction.
    private static func percentChecks(_ failures: inout [String]) {
        let cases: [(score: Double, text: String)] = [
            (0.943, "94%"), (1, "100%"), (0, "0%"), (0.29, "29%"), (0.57, "57%"), (0.996, "99%"),
            (0.7, "70%"), (0.9, "90%"), (1.7, "100%"), (-0.2, "0%"), (Double.nan, "0%"), (Double.infinity, "0%"),
        ]
        for item in cases {
            let row = QualityPresentation.row(id: "x", title: Copy.Quality.walls, score: item.score)
            check(&failures, "percent.\(item.score)", row.percentText == item.text, "got \(row.percentText)")
        }
        check(&failures, "fraction.clampHigh", QualityPresentation.fraction(1.7) == 1, "not clamped to 1")
        check(&failures, "fraction.clampLow", QualityPresentation.fraction(-0.2) == 0, "not clamped to 0")
        check(&failures, "fraction.nan", QualityPresentation.fraction(Double.nan) == 0, "NaN is not 0")
        check(&failures, "fraction.keep", QualityPresentation.fraction(0.943) == 0.943, "value changed")
        let nanRow = QualityPresentation.row(id: "x", title: Copy.Quality.floor, score: Double.nan)
        check(&failures, "percent.nanRow", nanRow.fraction == 0 && nanRow.tint == .poor, "NaN row \(nanRow)")
    }

    // MARK: Tints

    /// Score, verdict and missing-count tints, including the thresholds themselves.
    private static func tintChecks(_ failures: inout [String]) {
        let cases: [(score: Double, tint: QualityTint)] = [
            (0.95, .good), (0.8, .okay), (0.5, .poor), (0.9, .good), (0.7, .okay), (0.6999, .poor),
            (0.8999, .okay), (1, .good), (0, .poor), (Double.nan, .poor),
        ]
        for item in cases {
            let got = QualityTint(score: item.score)
            check(&failures, "tint.\(item.score)", got == item.tint, "expected \(item.tint), got \(got)")
        }
        let verdictTints: [QualityTint] = QualityVerdict.allCases.map { QualityTint(verdict: $0) }
        let wantVerdictTints: [QualityTint] = QualityVerdict.allCases.map { verdict -> QualityTint in
            switch verdict {
            case .good: return .good
            case .okay: return .okay
            case .poor: return .poor
            }
        }
        check(&failures, "tint.verdict", verdictTints == wantVerdictTints, "got \(verdictTints)")
        let missingNone: QualityTint = QualityTint(missingAreas: 0)
        let missingTwo: QualityTint = QualityTint(missingAreas: 2)
        check(&failures, "tint.missing", missingNone == .good && missingTwo == .okay, "got \(missingNone), \(missingTwo)")
        let symbols = [QualityTint.good, .okay, .poor].map { QualitySheetStyle.symbol(for: $0) }
        check(&failures, "tint.symbols", Set(symbols).count == 3, "tints share a symbol: \(symbols)")
    }

    // MARK: Finish

    /// Finish versus Finish Anyway, by count and for whole evaluations.
    private static func finishChecks(_ failures: inout [String]) {
        check(&failures, "finish.0", QualityPresentation.finishTitle(missingAreas: 0) == Copy.Quality.finish,
              "got \(QualityPresentation.finishTitle(missingAreas: 0))")
        check(&failures, "finish.3", QualityPresentation.finishTitle(missingAreas: 3) == Copy.Quality.finishAnyway,
              "got \(QualityPresentation.finishTitle(missingAreas: 3))")
        check(&failures, "finish.negative", QualityPresentation.finishTitle(missingAreas: -1) == Copy.Quality.finish,
              "negative count")
        check(&failures, "finish.nil", QualityPresentation.finishTitle(for: nil) == Copy.Quality.finishAnyway,
              "checking state must offer Finish Anyway")
        check(&failures, "finish.good", QualityPresentation.finishTitle(for: evaluation()) == Copy.Quality.finish,
              "complete scan")
        check(&failures, "finish.missing", QualityPresentation.finishTitle(for: evaluation(missing: 2)) == Copy.Quality.finishAnyway,
              "scan with missing areas")
        let noWalls = evaluation(walls: 0, floor: 0, ceiling: 0, missing: 0, degraded: .roomPlanFailed)
        check(&failures, "finish.poorNoMissing", QualityPresentation.finishTitle(for: noWalls) == Copy.Quality.finishAnyway,
              "a poor scan with no missing areas must read Finish Anyway")
    }

    // MARK: Notes

    /// Degraded notes per mode, the light note threshold and the note order.
    private static func noteChecks(_ failures: inout [String]) {
        for mode in DegradedMode.allCases {
            let note = QualityPresentation.degradedNote(mode)
            if mode == .allGood {
                check(&failures, "degraded.allGood", note == nil, "expected nil")
            } else {
                check(&failures, "degraded.\(mode.rawValue)", !(note ?? "").isEmpty, "expected a note")
            }
        }
        let notes = DegradedMode.allCases.compactMap { QualityPresentation.degradedNote($0) }
        check(&failures, "degraded.distinct", Set(notes).count == notes.count, "two modes share a note")
        check(&failures, "light.0.3", QualityPresentation.lightNote(darkKeyframeFraction: 0.3) == nil, "expected nil")
        check(&failures, "light.0.31", QualityPresentation.lightNote(darkKeyframeFraction: 0.31) == Copy.Quality.noteDark,
              "expected noteDark")
        check(&failures, "light.nan", QualityPresentation.lightNote(darkKeyframeFraction: Float.nan) == nil, "NaN")
        let both = QualityPresentation.notes(for: evaluation(degraded: .meshStripped, dark: 0.5))
        check(&failures, "notes.order", both == [Copy.Quality.noteMeshStripped, Copy.Quality.noteDark], "got \(both)")
        let none = QualityPresentation.notes(for: evaluation(dark: 0.1))
        check(&failures, "notes.none", none.isEmpty, "got \(none)")
    }

    // MARK: Summary

    /// Summary text per verdict and the good-with-missing-areas downgrade.
    private static func summaryChecks(_ failures: inout [String]) {
        let expected: [QualityVerdict: String] = [
            .good: Copy.Quality.summaryGood, .okay: Copy.Quality.summaryOkay, .poor: Copy.Quality.summaryPoor,
        ]
        for verdict in QualityVerdict.allCases {
            let got = QualityPresentation.summaryText(verdict)
            check(&failures, "summary.\(verdict.rawValue)", got == expected[verdict], "got \(got)")
        }
        let good = evaluation()
        check(&failures, "display.good", QualityPresentation.displayVerdict(good) == .good, "complete scan")
        let goodMissing = evaluation(missing: 1)
        check(&failures, "display.goodMissing", QualityPresentation.displayVerdict(goodMissing) == .okay,
              "good scores with a missing area must read okay")
        check(&failures, "display.summaryText", QualityPresentation.summaryText(for: goodMissing) == Copy.Quality.summaryOkay,
              "summary of good with missing")
        let poor = evaluation(ceiling: 0.4, missing: 3)
        check(&failures, "display.poor", QualityPresentation.displayVerdict(poor) == .poor, "poor stays poor")
        let line = QualityPresentation.logLine(poor)
        check(&failures, "log.line", line.contains("ceiling 40%") && line.contains("missing 3") && line.contains("verdict poor"),
              "got \(line)")
    }

    // MARK: Missing areas

    /// Count text, VoiceOver label and when Show Missing Areas is offered.
    private static func missingChecks(_ failures: inout [String]) {
        check(&failures, "missing.text3", QualityPresentation.missingText(count: 3) == "3", "got \(QualityPresentation.missingText(count: 3))")
        check(&failures, "missing.text0", QualityPresentation.missingText(count: 0) == "0", "zero")
        check(&failures, "missing.negative", QualityPresentation.missingText(count: -2) == "0", "negative count")
        check(&failures, "missing.a11y", QualityPresentation.missingAccessibility(count: 3) == "Missing areas, 3",
              "got \(QualityPresentation.missingAccessibility(count: 3))")
        check(&failures, "missing.count", QualityPresentation.missingCount(evaluation(missing: 2)) == 2, "count")
        let two = evaluation(missing: 2)
        check(&failures, "button.noAction", !QualityPresentation.showsMissingAreasButton(evaluation: two, actionAvailable: false),
              "nil action must hide the button")
        check(&failures, "button.shown", QualityPresentation.showsMissingAreasButton(evaluation: two, actionAvailable: true),
              "action and areas must show the button")
        check(&failures, "button.nothingMissing",
              !QualityPresentation.showsMissingAreasButton(evaluation: evaluation(), actionAvailable: true),
              "no areas must hide the button")
        check(&failures, "button.checking", !QualityPresentation.showsMissingAreasButton(evaluation: nil, actionAvailable: true),
              "checking state must hide the button")
    }

    // MARK: Copy

    /// Every string the sheet shows is non-empty and follows the voice rules (no em-dash).
    private static func copyChecks(_ failures: inout [String]) {
        let strings = [
            Copy.Quality.checking, Copy.Quality.checkingSlow, Copy.Quality.noteDepthStripped,
            Copy.Quality.noteMeshStripped, Copy.Quality.noteRoomPlanFailed, Copy.Quality.noteDark,
            Copy.Scanning.cancelConfirmDiscard, Copy.Quality.title, Copy.Quality.missingAreas,
            Copy.Quality.showMissingAreas,
        ]
        for (index, text) in strings.enumerated() {
            let clean = !text.isEmpty && !text.contains("\u{2014}")
            check(&failures, "copy.\(index)", clean, "empty or contains an em-dash: \(text)")
        }
        check(&failures, "copy.checking", Copy.Quality.checking == "Checking your scan...", "got \(Copy.Quality.checking)")
    }
}
