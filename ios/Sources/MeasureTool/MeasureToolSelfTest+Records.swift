import Foundation
import simd

/// Values, records, texts and the saved file (the second half of `MeasureToolSelfTest`).
extension MeasureToolSelfTest {
    /// Imperial with both systems shown, and metric.
    static let imperial = UnitPreferences.standard
    static let metric = UnitPreferences(system: .metric, fraction: .eighth, showBoth: true)

    /// A distance draft from (1, 1, -1) to (3, 1, -1): 2.0 m of free scan points in the room.
    static func distanceDraft() -> MeasureToolDraft {
        MeasureToolDraft(kind: .distance, points: [F.free(1, 1, -1), F.free(3, 1, -1)], value: nil)
    }

    /// A 0.3 x 0.3 m square on the room's floor, every corner snapped to the floor plane.
    static func smallFloorArea() -> MeasureToolDraft {
        let corners: [SIMD3<Float>] = [SIMD3<Float>(1, 0, -1), SIMD3<Float>(1.3, 0, -1), SIMD3<Float>(1.3, 0, -1.3),
                                       SIMD3<Float>(1, 0, -1.3)]
        let points = corners.map { MeasureToolPoint(position: $0, snap: .plane, feature: .floor, element: F.roomID) }
        return MeasureToolDraft(kind: .area, points: points, value: nil)
    }

    // MARK: - Values (7 checks)

    /// Distance, height, area and angle values and their flags.
    static func valueChecks(_ log: MeasureToolSelfTestLog) {
        let good = F.context()
        let shaky = F.context(tracking: 0.3)
        let distance = MeasureToolSnaps.value(distanceDraft(), context: good)
        let distanceOK: Bool = distance.map { value -> Bool in
            let sigma: Double = value.sigma ?? 0
            return near(Float(value.value), 2) && sigma > 0
        } ?? false
        let distanceLow = distance.map { MeasureDisplay.isLowConfidence($0, kind: .distance) } ?? true
        log.check("value.distanceGoodEvidence", distanceOK && !distanceLow, "\(String(describing: distance))")
        let shakyDistance = MeasureToolSnaps.value(distanceDraft(), context: shaky)
        let shakyLow = shakyDistance.map { MeasureDisplay.isLowConfidence($0, kind: .distance) } ?? false
        log.check("value.distanceWeakTracking", shakyLow, "\(String(describing: shakyDistance))")

        let heightPoints = [F.free(1, 0.1, -1), F.free(1.5, 2.6, -2)]
        let height = MeasureToolSnaps.value(MeasureToolDraft(kind: .height, points: heightPoints, value: nil), context: good)
        let vertical = MeasureMath.verticalDistance(heightPoints[0].position, heightPoints[1].position)
        log.check("value.heightIsVertical", height.map { near(Float($0.value), vertical) } ?? false,
                  "\(String(describing: height)) vs \(vertical)")

        var area = MeasureToolDraft(kind: .area, points: [F.free(1, 0, -1), F.free(2, 0, -1)], value: nil)
        let twoPoints = MeasureToolSnaps.value(area, context: good)
        area.points.append(F.free(2, 0, -2))
        let threePoints = MeasureToolSnaps.value(area, context: good)
        let wallDraft = MeasureToolSnaps.value(MeasureToolDraft(kind: .wall, points: [F.free(2, 1, 0)], value: nil),
                                               context: good)
        let threeOK: Bool = threePoints.map { near(Float($0.value), 0.5) } ?? false
        let noneOK: Bool = twoPoints == nil && wallDraft == nil
        log.check("value.areaFromThreePoints", noneOK && threeOK, "\(String(describing: threePoints))")

        let weakCorner = F.context(wall1Observations: 0)
        let corner = MeasureToolPoint(position: SIMD3<Float>(2, 1, 0), snap: .plane, feature: .wall, element: F.wall1)
        let angleDraft = MeasureToolDraft(kind: .angle, points: [F.free(1, 1, -1), corner, F.free(3, 1, -1)], value: nil)
        let angle = MeasureToolSnaps.value(angleDraft, context: weakCorner)
        let angleOK: Bool = angle.map { value -> Bool in
            let right: Bool = near(Float(value.value), Float.pi / 2, 1e-4)
            return right && value.isLowConfidence(kind: MeasurementKind.angle)
        } ?? false
        log.check("value.angleWeakCornerLow", angleOK, "\(String(describing: angle))")

        var small = smallFloorArea()
        small.value = MeasureToolSnaps.value(small, context: good)
        let smallRecord = MeasureToolSnaps.record(for: small, context: good, id: F.uuid(90), now: F.date(0))
        let recordLow: Bool = smallRecord.map { MeasureToolSnaps.isLowConfidence(record: $0, context: good) } ?? true
        let draftLow: Bool = MeasureToolSnaps.isLowConfidence(draft: small, context: good)
        log.check("value.smallAreaFlagFromSides", !draftLow && !recordLow, "\(String(describing: small.value))")

        var weak = smallFloorArea()
        weak.value = MeasureToolSnaps.value(weak, context: shaky)
        let weakStored: Bool = weak.value.map { $0.isLowConfidence(kind: MeasurementKind.area) } ?? false
        let weakDraft: Bool = MeasureToolSnaps.isLowConfidence(draft: weak, context: shaky)
        log.check("value.weakAreaFlagged", weakDraft && weakStored, "\(String(describing: weak.value))")
    }

    // MARK: - Records (7 checks)

    /// Wall records, draft records, moving and pairing.
    static func recordChecks(_ log: MeasureToolSelfTestLog) {
        let context = F.context()
        let walls = MeasureToolSnaps.wallRecords(F.walls()[0], context: context, now: F.date(0))
        let floorSigma: Double = 0.015 - 1e-9
        var lengthOK = false
        var heightOK = false
        if walls.count == 2 {
            let length = walls[0]
            let height = walls[1]
            let lengthSigma: Double = length.result.sigma ?? 0
            let heightSigma: Double = height.result.sigma ?? 0
            let lengthValueOK: Bool = near(Float(length.result.value), 4)
            let heightValueOK: Bool = near(Float(height.result.value), 2.5)
            let lengthKindOK: Bool = length.kind == MeasurementKind.wallLength
            let heightKindOK: Bool = height.kind == MeasurementKind.height
            lengthOK = lengthKindOK && lengthValueOK && lengthSigma >= floorSigma
            heightOK = heightKindOK && heightValueOK && heightSigma >= floorSigma
        }
        let edgeSnaps: [SnapKind] = [.edge, .edge]
        let tagsOK: Bool = walls.allSatisfy { record -> Bool in
            let tagged: Bool = record.snaps == edgeSnaps && record.source == MeasurementSource.viewer
            return tagged && record.roomID == F.roomID
        }
        log.check("wallRecords.lengthAndHeight", lengthOK && heightOK && tagsOK, "\(walls)")

        let curved = F.curvedWall()
        let curvedRecords = MeasureToolSnaps.wallRecords(curved, context: context, now: F.date(0))
        let arcLength = curvedRecords.first.map { Float($0.result.value) } ?? 0
        let chord: Float = curved.length
        let longerThanChord: Bool = arcLength > chord + 0.1
        let arcOK: Bool = near(arcLength, Float.pi, 1e-3)
        log.check("wallRecords.curvedUsesArc", longerThanChord && arcOK, "arc \(arcLength), chord \(chord)")

        var draft = distanceDraft()
        draft.value = MeasureToolSnaps.value(draft, context: context)
        let made = MeasureToolSnaps.record(for: draft, context: context, id: F.uuid(91), now: F.date(1))
        let madeOK: Bool = made.map { record -> Bool in
            let counts: Bool = record.points.count == 2 && record.snaps.count == 2
            let tags: Bool = record.source == MeasurementSource.viewer && record.kind == MeasurementKind.distance
            return counts && tags && record.roomID == F.roomID && record.name.isEmpty
        } ?? false
        log.check("record.distance", madeOK, "\(String(describing: made))")

        let single = MeasureToolDraft(kind: .distance, points: [F.free(1, 1, -1)], value: nil)
        let twoCorners = MeasureToolDraft(kind: .area, points: [F.free(1, 0, -1), F.free(2, 0, -1)], value: nil)
        let wallDraft = MeasureToolDraft(kind: .wall, points: [F.free(2, 1, 0)], value: nil)
        let singleNil: Bool = MeasureToolSnaps.record(for: single, context: context, id: F.uuid(92), now: F.date(2)) == nil
        let cornersNil: Bool = MeasureToolSnaps.record(for: twoCorners, context: context, id: F.uuid(93), now: F.date(2)) == nil
        let wallNil: Bool = MeasureToolSnaps.record(for: wallDraft, context: context, id: F.uuid(94), now: F.date(2)) == nil
        log.check("record.incompleteIsNil", singleNil && cornersNil && wallNil)

        if var named = made {
            named.name = "Hall"
            let moved = MeasureToolSnaps.moving(named, index: 1, to: F.free(3.5, 1, -1), context: context)
            let sameIdentity: Bool = moved.id == named.id && moved.name == "Hall" && moved.createdAt == named.createdAt
            let target = Vec3(x: 3.5, y: 1, z: -1)
            let movedPoint: Bool = moved.points.count == 2 && moved.points[1] == target
            let movedOK: Bool = sameIdentity && movedPoint && near(Float(moved.result.value), 2.5)
            log.check("moving.distanceRecomputed", movedOK, "\(moved)")
        } else {
            log.check("moving.distanceRecomputed", false, "no record")
        }
        let wallLength = walls.first
        let unchanged = wallLength.map { MeasureToolSnaps.moving($0, index: 0, to: F.free(9, 0, 9), context: context) == $0 }
        log.check("moving.wallLengthUnchanged", unchanged == true)

        let other = MeasurementRecord(id: F.uuid(95), kind: .height, points: walls.last?.points ?? [],
                                      snaps: [.edge, .edge], result: MeasuredValue(value: 2.5, sigma: 0.01, provenance: .measured),
                                      source: .viewer, name: "", roomID: nil, createdAt: F.date(5))
        let everything: [MeasurementRecord] = walls + [other]
        let pairsFound: Bool = walls.allSatisfy { MeasureToolSnaps.isWallRecord($0, among: everything) }
        let pairOK: Bool = pairsFound && !MeasureToolSnaps.isWallRecord(other, among: everything)
        let onWall = MeasurementRecord(id: F.uuid(96), kind: .distance, points: [Vec3(x: 2, y: 1.25, z: 0), Vec3(x: 3, y: 1, z: -1)],
                                       snaps: [.plane, .meshSurface], result: MeasuredValue(value: 1.5, sigma: 0.01, provenance: .measured),
                                       source: .viewer, name: "", roomID: nil, createdAt: F.date(6))
        let rebuilt = MeasureToolSnaps.point(of: onWall, at: 0, context: context)
        let freePoint = MeasureToolSnaps.point(of: onWall, at: 1, context: context)
        let rebuiltOK: Bool = rebuilt.element == F.wall1 && rebuilt.feature == SnapSetFeature.wall
        let freeOK: Bool = freePoint.element == nil && freePoint.snap == SnapKind.meshSurface
        log.check("records.wallPairingAndRebuild", pairOK && rebuiltOK && freeOK, "\(rebuilt)")
    }

    // MARK: - Presentation (7 checks)

    /// Rows, hints, snap text, titles and the log line.
    static func presentationChecks(_ log: MeasureToolSelfTestLog) {
        let context = F.context()
        let records = sampleRecords(context)
        let rows = MeasureToolPresentation.rows(records, prefs: imperial)
        let distance = MeasureToolPresentation.kindTitle(.distance)
        let area = MeasureToolPresentation.kindTitle(.area)
        let expected = [Copy.MeasureTool.numbered(distance, 1), Copy.MeasureTool.numbered(distance, 2),
                        Copy.MeasureTool.numbered(area, 1), "Hall width"]
        let titles = rows.map { $0.title }
        let literalOK: Bool = expected[0] == "Distance 1" && expected[2] == "Surface area 1"
        log.check("rows.titles", titles == expected && literalOK, "\(titles)")

        var accuracyOK = true
        for prefs in [imperial, metric] {
            let flagged = MeasureToolPresentation.rows(records, prefs: prefs) { record in
                MeasureToolSnaps.isLowConfidence(record: record, context: context)
            }
            for row in rows + flagged {
                guard let text = row.accuracyText else { accuracyOK = false; continue }
                let signs = text.filter { $0 == "\u{00B1}" }.count
                if text != Copy.Measure.lowConfidence && signs != 1 { accuracyOK = false }
                if row.accessibility.isEmpty || row.valueText.isEmpty { accuracyOK = false }
            }
        }
        log.check("rows.accuracyText", accuracyOK)

        let sequences: [(MeasureToolKind, [String])] = [
            (.distance, [Copy.MeasureTool.tapFirst, Copy.MeasureTool.tapSecond]),
            (.height, [Copy.MeasureTool.tapFirst, Copy.MeasureTool.tapSecond]),
            (.wall, [Copy.MeasureTool.tapWall]),
            (.area, [Copy.MeasureTool.areaFirst, Copy.MeasureTool.areaNext, Copy.MeasureTool.areaNext,
                     Copy.MeasureTool.areaClose, Copy.MeasureTool.areaClose]),
            (.angle, [Copy.MeasureTool.angleFirst, Copy.MeasureTool.angleCorner, Copy.MeasureTool.angleSecond]),
        ]
        var hintsOK = true
        for (tool, texts) in sequences {
            for (placed, text) in texts.enumerated() where MeasureToolPresentation.hint(tool, placed: placed) != text {
                hintsOK = false
            }
        }
        let all = [Copy.MeasureTool.tapFirst, Copy.MeasureTool.tapSecond, Copy.MeasureTool.tapWall, Copy.MeasureTool.noWall,
                   Copy.MeasureTool.areaFirst, Copy.MeasureTool.areaNext, Copy.MeasureTool.areaClose,
                   Copy.MeasureTool.angleFirst, Copy.MeasureTool.angleCorner, Copy.MeasureTool.angleSecond,
                   Copy.MeasureTool.noSurface]
        let distinct: Bool = Set(all).count == all.count
        let filled: Bool = all.allSatisfy { !$0.isEmpty }
        log.check("hint.texts", hintsOK && distinct && filled)

        let door = MeasureToolPoint(position: .zero, snap: .corner, feature: .door, element: F.door)
        let mesh = MeasureToolPoint(position: .zero, snap: .meshVertex)
        let doorText: Bool = MeasureToolPresentation.snapText(door) == Copy.Measure.snapped(to: "door")
        let meshText: Bool = MeasureToolPresentation.snapText(mesh) == nil
        log.check("snapText.doorAndMesh", doorText && meshText)

        let kindsOK = MeasurementKind.allCases.allSatisfy { !MeasureToolPresentation.kindTitle($0).isEmpty }
        let tools = MeasureToolKind.allCases
        let minimums: [Int] = tools.map { $0.minimumPoints }
        let kinds: [MeasurementKind] = tools.map { $0.measurementKind }
        let expectedKinds: [MeasurementKind] = [.distance, .height, .wallLength, .area, .angle]
        let tableOK: Bool = minimums == [2, 2, 1, 3, 3] && kinds == expectedKinds
        log.check("kinds.titlesAndTable", kindsOK && tableOK)

        let pickerTitles = tools.map { MeasureToolPresentation.title(of: $0) }
        guard let first = records.first(where: { $0.id == F.uuid(101) }) else {
            log.check("titles.pickerAndLabel", false, "no sample record")
            log.check("logLine.kindAndMillimeters", false, "no sample record")
            return
        }
        let label = MeasureToolPresentation.label(first.result, kind: first.kind, prefs: metric)
        let valueText: String = MeasureDisplay.valueText(first.result, kind: first.kind, prefs: metric)
        let accuracyText: String? = MeasureDisplay.accuracyText(first.result, kind: first.kind, prefs: metric)
        let labelOK: Bool = label.value == valueText && label.accuracy == accuracyText
        let titlesOK: Bool = Set(pickerTitles).count == 5 && pickerTitles.allSatisfy { !$0.isEmpty }
        log.check("titles.pickerAndLabel", titlesOK && labelOK, "\(pickerTitles)")

        let line = MeasureToolPresentation.logLine(first, event: "created")
        let kindOK: Bool = line.contains("kind=distance") && line.contains("created")
        let pointsOK: Bool = line.contains("(1000, 1000, -1000)") && line.contains("(3000, 1000, -1000)")
        let lineOK: Bool = kindOK && pointsOK
        log.check("logLine.kindAndMillimeters", lineOK, line)
    }

    /// Two distances, an area and a named distance, out of order (createdAt 1, 2, 3, 4).
    static func sampleRecords(_ context: MeasureToolContext) -> [MeasurementRecord] {
        var first = distanceDraft()
        first.value = MeasureToolSnaps.value(first, context: context)
        var second = MeasureToolDraft(kind: .distance, points: [F.free(1, 1, -2), F.free(1, 1, -4)], value: nil)
        second.value = MeasureToolSnaps.value(second, context: context)
        var area = smallFloorArea()
        area.value = MeasureToolSnaps.value(area, context: context)
        let made = [
            MeasureToolSnaps.record(for: first, context: context, id: F.uuid(101), now: F.date(1)),
            MeasureToolSnaps.record(for: second, context: context, id: F.uuid(102), now: F.date(2)),
            MeasureToolSnaps.record(for: area, context: context, id: F.uuid(103), now: F.date(3)),
            MeasureToolSnaps.record(for: second, context: context, id: F.uuid(104), now: F.date(4)),
        ].compactMap { $0 }
        guard made.count == 4 else { return made }
        var named = made[3]
        named.name = "  Hall width "
        return [made[0], made[2], made[1], named].sorted { $0.id.uuidString > $1.id.uuidString }
    }

    // MARK: - Saved file (1 check)

    /// `EditStore.saveMeasurements` then `loadMeasurements` of records made by this module, in a
    /// temporary package that is removed afterwards.
    static func storeChecks(_ log: MeasureToolSelfTestLog) {
        let context = F.context()
        var records = Array(sampleRecords(context).prefix(2))
        records.append(contentsOf: MeasureToolSnaps.wallRecords(F.walls()[0], context: context, now: F.date(7)).prefix(1))
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("measuretool-selftest-\(F.uuid(120).uuidString)", isDirectory: true)
        let root = folder.appendingPathComponent("\(F.uuid(121).uuidString).\(ProjectPackage.fileExtension)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let package = ProjectPackage(root: root)
            try EditStore.saveMeasurements(records, to: package)
            let loaded = EditStore.loadMeasurements(package)
            let same: Bool = loaded == records
            log.check("store.roundTrip", records.count == 3 && same, "saved \(records.count), loaded \(loaded.count)")
        } catch {
            log.check("store.roundTrip", false, "\(error)")
        }
    }
}
