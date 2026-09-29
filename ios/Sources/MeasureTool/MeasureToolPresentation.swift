import Foundation

/// Pure texts and rows of the tools: every word from Copy, every number through MeasureDisplay
/// (and so Units). Nonisolated, any queue.
enum MeasureToolPresentation {
    /// Picker titles: Copy.Measure.distance, Copy.Viewer.height, Copy.WallMenu.title, Copy.MeasureTool.area,
    /// Copy.Measure.angle.
    static func title(of tool: MeasureToolKind) -> String {
        switch tool {
        case .distance: return Copy.Measure.distance
        case .height: return Copy.Viewer.height
        case .wall: return Copy.WallMenu.title
        case .area: return Copy.MeasureTool.area
        case .angle: return Copy.Measure.angle
        }
    }

    /// Row titles by Core kind: distance Copy.Measure.distance, wallLength Copy.Measure.wallLength,
    /// height Copy.Viewer.height, area Copy.Measure.surfaceArea, perimeter Copy.Measure.perimeter,
    /// angle Copy.Measure.angle, volume Copy.Measure.volume (exhaustive switch).
    static func kindTitle(_ kind: MeasurementKind) -> String {
        switch kind {
        case .distance: return Copy.Measure.distance
        case .wallLength: return Copy.Measure.wallLength
        case .height: return Copy.Viewer.height
        case .area: return Copy.Measure.surfaceArea
        case .perimeter: return Copy.Measure.perimeter
        case .angle: return Copy.Measure.angle
        case .volume: return Copy.Measure.volume
        }
    }

    /// Rows in createdAt order (ties keep the list order) with the CR-2 rule on each stored value
    /// as the flag; use `rows(_:prefs:lowConfidence:)` to give areas their side-based flag (E3).
    static func rows(_ records: [MeasurementRecord], prefs: UnitPreferences) -> [MeasureToolRow] {
        rows(records, prefs: prefs) { record in
            MeasureDisplay.isLowConfidence(record.result, kind: record.kind)
        }
    }

    /// Rows with the given flag per record. Titles: the trimmed name, else the kind title numbered
    /// per kind over every record of that kind in createdAt order ("Distance 2"), so naming one
    /// record does not renumber the others. Value, accuracy and VoiceOver text from MeasureDisplay
    /// with the row's flag.
    static func rows(_ records: [MeasurementRecord], prefs: UnitPreferences,
                     lowConfidence: (MeasurementRecord) -> Bool) -> [MeasureToolRow] {
        let ordered = createdOrder(records)
        var counts: [MeasurementKind: Int] = [:]
        var result: [MeasureToolRow] = []
        result.reserveCapacity(ordered.count)
        for record in ordered {
            let n = (counts[record.kind] ?? 0) + 1
            counts[record.kind] = n
            let name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = name.isEmpty ? Copy.MeasureTool.numbered(kindTitle(record.kind), n) : name
            let flag = lowConfidence(record)
            let value = record.result
            let valueText = MeasureDisplay.valueText(value, kind: record.kind, prefs: prefs)
            let accuracy = MeasureDisplay.accuracyText(value, kind: record.kind, prefs: prefs, lowConfidence: flag)
            let spoken = MeasureDisplay.accessibilityText(label: title, value: value, kind: record.kind, prefs: prefs,
                                                          lowConfidence: flag)
            let notMeasured = value.provenance == .estimated || value.provenance == .inferred
            result.append(MeasureToolRow(id: record.id, title: title, valueText: valueText, accuracyText: accuracy,
                                         isLowConfidence: flag, accessibility: spoken, isNotMeasured: notMeasured))
        }
        return result
    }

    /// Records sorted by createdAt; records made at the same time keep their list order.
    static func createdOrder(_ records: [MeasurementRecord]) -> [MeasurementRecord] {
        let indexed = records.enumerated().map { (offset: $0.offset, record: $0.element) }
        let sorted = indexed.sorted { lhs, rhs in
            if lhs.record.createdAt != rhs.record.createdAt {
                return lhs.record.createdAt < rhs.record.createdAt
            }
            return lhs.offset < rhs.offset
        }
        return sorted.map { $0.record }
    }

    /// The hint for the next tap (Copy.MeasureTool tapFirst, tapSecond, tapWall, areaFirst, areaNext,
    /// areaClose, angleFirst, angleCorner, angleSecond).
    static func hint(_ tool: MeasureToolKind, placed: Int) -> String {
        switch tool {
        case .distance, .height:
            return placed == 1 ? Copy.MeasureTool.tapSecond : Copy.MeasureTool.tapFirst
        case .wall:
            return Copy.MeasureTool.tapWall
        case .area:
            if placed <= 0 { return Copy.MeasureTool.areaFirst }
            return placed < 3 ? Copy.MeasureTool.areaNext : Copy.MeasureTool.areaClose
        case .angle:
            switch placed {
            case 1: return Copy.MeasureTool.angleCorner
            case 2: return Copy.MeasureTool.angleSecond
            default: return Copy.MeasureTool.angleFirst
            }
        }
    }

    /// `SnapSetFeature.snappedText` of the point's feature; nil without a feature.
    static func snapText(_ point: MeasureToolPoint) -> String? {
        point.feature?.snappedText
    }

    /// On-model label lines: `MeasureDisplay.valueText` and `accuracyText` (the value's own CR-2 flag).
    static func label(_ value: MeasuredValue, kind: MeasurementKind, prefs: UnitPreferences) -> (value: String, accuracy: String?) {
        label(value, kind: kind, prefs: prefs, lowConfidence: MeasureDisplay.isLowConfidence(value, kind: kind))
    }

    /// On-model label lines with the flag given (an area's side-based flag, E3).
    static func label(_ value: MeasuredValue, kind: MeasurementKind, prefs: UnitPreferences,
                      lowConfidence: Bool) -> (value: String, accuracy: String?) {
        let text = MeasureDisplay.valueText(value, kind: kind, prefs: prefs)
        let accuracy = MeasureDisplay.accuracyText(value, kind: kind, prefs: prefs, lowConfidence: lowConfidence)
        return (text, accuracy)
    }

    /// Log line (category "measure"): event, id, kind, every point in whole millimeters, snaps, value
    /// and sigma, source (MEAS-01, MEAS-08, MEAS-10). No user text (the name is left out).
    static func logLine(_ record: MeasurementRecord, event: String) -> String {
        let points = record.points.map { p -> String in
            "(\(millimeters(p.x)), \(millimeters(p.y)), \(millimeters(p.z)))"
        }
        let snaps = record.snaps.map { $0.rawValue }.joined(separator: ",")
        let sigma = record.result.sigma.map { String(format: "%.5f", $0) } ?? "none"
        let value = String(format: "%.5f", record.result.value)
        let room = record.roomID?.uuid.uuidString ?? "none"
        return "measurement \(event) id=\(record.id.uuidString) kind=\(record.kind.rawValue) "
            + "points_mm=[\(points.joined(separator: " "))] snaps=[\(snaps)] value=\(value) sigma=\(sigma) "
            + "provenance=\(record.result.provenance.rawValue) source=\(record.source.rawValue) room=\(room)"
    }

    /// Meters to whole millimeters for logs ("?" for values that are not finite).
    static func millimeters(_ meters: Float) -> String {
        let mm = (Double(meters) * 1000).rounded()
        guard mm.isFinite, abs(mm) < 1e12 else { return "?" }
        return String(Int64(mm))
    }
}
