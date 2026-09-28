import Foundation
import simd

/// Plain-Swift checks for MeasureCore (no XCTest): confidence adapter, the one low-confidence
/// rule, display texts, the room dimension list and snapping. Deterministic, pure, no files.
/// `run()` returns one line per failing check ("name: detail"); empty means all passed.
enum MeasureCoreSelfTest {
    /// Number of checks `run()` performs.
    static let checkCount = 52

    /// Runs every check.
    static func run() -> [String] {
        let log = MeasureCoreSelfTestLog()
        confidenceChecks(log)
        displayChecks(log)
        dimensionChecks(log)
        snapChecks(log)
        var failures = log.failures
        if log.count != checkCount {
            failures.append("selfTest.count: expected \(checkCount) checks, ran \(log.count)")
        }
        return failures
    }

    /// Imperial with both systems shown, metric with both, metric only.
    static let imperial = UnitPreferences.standard
    static let metric = UnitPreferences(system: .metric, fraction: .eighth, showBoth: true)
    static let metricOnly = UnitPreferences(system: .metric, fraction: .eighth, showBoth: false)
    /// RESEARCH ruling 4 floor as a Double.
    static let floorSigma = Double(ConfidenceAdapter.roomPlanMinimumSigma)

    // MARK: - Confidence (15 checks)

    /// ConfidenceAdapter and the CR-2 rule.
    static func confidenceChecks(_ log: MeasureCoreSelfTestLog) {
        let unknown = RoomEvidence.unknown
        let w566 = ConfidenceAdapter.roomPlanLength(5.66, wall: nil, room: unknown, provenance: .measured)
        log.check("roomPlan.5_66m.floor", (w566.sigma ?? 0) >= floorSigma - 1e-12, "sigma \(String(describing: w566.sigma))")
        log.check("roomPlan.5_66m.metricText", MeasureDisplay.accuracyText(w566, kind: .wallLength, prefs: metric)
              == Copy.Measure.accuracy("30 mm"),
              "\(String(describing: MeasureDisplay.accuracyText(w566, kind: .wallLength, prefs: metric)))")
        let shownImperial = MeasureDisplay.shownLength(2 * (w566.sigma ?? 0), prefs: imperial)
        log.check("roomPlan.5_66m.imperialAtLeast3cm", shownImperial >= 0.03 - 1e-9, "shown \(shownImperial) m")

        let w2 = ConfidenceAdapter.roomPlanLength(2, wall: nil, room: unknown, provenance: .measured)
        let w8 = ConfidenceAdapter.roomPlanLength(8, wall: nil, room: unknown, provenance: .measured)
        log.check("roomPlan.sigmaGrowsWithLength", (w2.sigma ?? 1) < (w8.sigma ?? 0),
              "2 m \(String(describing: w2.sigma)), 8 m \(String(describing: w8.sigma))")

        let shaky = RoomEvidence(trackingNormalFraction: 0.5, relocalizations: 0, walls: [])
        let w3 = ConfidenceAdapter.roomPlanLength(3, wall: nil, room: shaky, provenance: .measured)
        log.check("tracking0_5.lowConfidence", MeasureDisplay.isLowConfidence(w3, length: 3), "sigma \(String(describing: w3.sigma))")
        log.check("tracking0_5.coreAgrees", w3.isLowConfidence(length: 3) == MeasureDisplay.isLowConfidence(w3, length: 3))
        log.check("tracking0_5.sigmaRaised", abs((w3.sigma ?? 0) - ConfidenceAdapter.lowConfidenceSigma(length: 3)) < 1e-12,
              "sigma \(String(describing: w3.sigma))")

        let good = WallEvidence(wallID: MeasureCoreSelfTestFixtures.id(1), medianDistance: 1.5, observations: 9)
        let w10 = ConfidenceAdapter.roomPlanLength(10, wall: good, room: unknown, provenance: .measured)
        log.check("wall10m.goodEvidence.notLow", !MeasureDisplay.isLowConfidence(w10, length: 10), "sigma \(String(describing: w10.sigma))")
        let short = MeasuredValue(value: 0.5, sigma: 0.025, provenance: .measured)
        log.check("distance0_5m.sigma25mm.low", MeasureDisplay.isLowConfidence(short, length: 0.5))

        let cases: [(value: Double, sigma: Double, low: Bool)] = [(0.5, 0.025, true), (0.5, 0.019, false),
                                                                   (10, 0.0208, false), (10, 0.16, true)]
        var agrees = true
        for c in cases {
            let v = MeasuredValue(value: c.value, sigma: c.sigma, provenance: .measured)
            let display = MeasureDisplay.isLowConfidence(v, length: c.value)
            if display != v.isLowConfidence(length: c.value) || display != c.low { agrees = false }
        }
        log.check("rule.agreesWithCore", agrees)

        let side5 = ConfidenceAdapter.roomPlanLength(5, wall: nil, room: unknown, provenance: .measured)
        let side4 = ConfidenceAdapter.roomPlanLength(4, wall: nil, room: unknown, provenance: .measured)
        let area = ConfidenceAdapter.area(20, sideA: side5, sideB: side4)
        let s5 = side5.sigma ?? 0
        let s4 = side4.sigma ?? 0
        let termA: Double = 4 * s5
        let termB: Double = 5 * s4
        let expectedArea: Double = (termA * termA + termB * termB).squareRoot()
        let areaSigma: Double = area.sigma ?? -1
        log.check("area.4x5.formula", abs(areaSigma - expectedArea) < 1e-12,
              "expected \(expectedArea), got \(String(describing: area.sigma))")

        let sides = [side4, side5, side4, side5]
        let total = ConfidenceAdapter.sum(sides)
        let squares: Double = 2 * s4 * s4 + 2 * s5 * s5
        let expectedSum: Double = squares.squareRoot()
        let totalSigma: Double = total.sigma ?? -1
        let sumSigmaOK: Bool = abs(totalSigma - expectedSum) < 1e-12
        let sumValueOK: Bool = abs(total.value - 18) < 1e-5
        log.check("sum.4walls", sumSigmaOK && sumValueOK,
              "value \(total.value), sigma \(String(describing: total.sigma))")
        let inferred = MeasuredValue(value: 2.5, sigma: nil, provenance: .inferred)
        let mixed = ConfidenceAdapter.sum([side4, inferred])
        log.check("sum.inferredHasNoSigma", mixed.sigma == nil && mixed.provenance == .inferred)

        let snapped = MeasurementEvidence(distance: 0.5, depthConfidence: 1, observations: 9,
                                          trackingNormalFraction: 1, snap: .roomSurface)
        let d = ConfidenceAdapter.distance(start: snapped, end: snapped, length: 1)
        log.check("distance.roomSurfaceFloor", (d.sigma ?? 0) >= floorSigma - 1e-12, "sigma \(String(describing: d.sigma))")
        let cornerKind = ConfidenceAdapter.measurementSnapKind(.corner)
        let vertexKind = ConfidenceAdapter.measurementSnapKind(.meshVertex)
        let freeKind = ConfidenceAdapter.measurementSnapKind(SnapKind.none)
        log.check("snapKind.mapping", cornerKind == .roomSurface && vertexKind == .vertex
                  && freeKind == MeasurementSnapKind.none)
    }

    // MARK: - Display (12 checks)

    /// MeasureDisplay texts and the spoken forms.
    static func displayChecks(_ log: MeasureCoreSelfTestLog) {
        let wall = MeasuredValue(value: 3.845, sigma: floorSigma, provenance: .measured)
        let plusMinus: Character = "\u{00B1}"
        let imperialAccuracy = MeasureDisplay.accuracyText(wall, kind: .wallLength, prefs: imperial) ?? ""
        let metricAccuracy = MeasureDisplay.accuracyText(wall, kind: .wallLength, prefs: metricOnly) ?? ""
        log.check("accuracy.imperial.onePlusMinus", imperialAccuracy.filter { $0 == plusMinus }.count == 1, imperialAccuracy)
        log.check("accuracy.metric.onePlusMinus", metricAccuracy.filter { $0 == plusMinus }.count == 1, metricAccuracy)
        log.check("accuracy.imperial.roundedUp", imperialAccuracy == Copy.Measure.accuracy("1 1/4\""), imperialAccuracy)

        let imperialText = MeasureDisplay.valueText(wall, kind: .wallLength, prefs: imperial)
        let metricText = MeasureDisplay.valueText(wall, kind: .wallLength, prefs: metricOnly)
        log.check("value.imperial.3_845", imperialText == LengthFormat.display(3.845, prefs: imperial), imperialText)
        log.check("value.metric.3_845", metricText == LengthFormat.display(3.845, prefs: metricOnly), metricText)

        let volume = MeasuredValue(value: 50, sigma: nil, provenance: .inferred)
        let volumeAccuracy = MeasureDisplay.accuracyText(volume, kind: .volume, prefs: imperial)
        let volumeText = MeasureDisplay.valueText(volume, kind: .volume, prefs: imperial)
        let volumeUsesNotMeasured: Bool = volumeAccuracy == Copy.Measure.notMeasured
        let volumeHasNoSign: Bool = !volumeText.contains(plusMinus) && !(volumeAccuracy ?? "").contains(plusMinus)
        log.check("volume.inferred.notMeasured", volumeUsesNotMeasured && volumeHasNoSign,
                  "\(volumeText) / \(String(describing: volumeAccuracy))")
        let user = MeasuredValue(value: 2, sigma: 0.01, provenance: .user)
        log.check("user.noAccuracy", MeasureDisplay.accuracyText(user, kind: .distance, prefs: imperial) == nil)
        let flagged = MeasuredValue(value: 3, sigma: ConfidenceAdapter.lowConfidenceSigma(length: 3), provenance: .measured)
        log.check("accuracy.lowConfidenceText",
              MeasureDisplay.accuracyText(flagged, kind: .wallLength, prefs: imperial) == Copy.Measure.lowConfidence)

        let spokenLength = MeasureSpoken.text("12' 7 3/8\" (3.845 m)")
        log.check("spoken.feetInches", spokenLength == "12 feet 7 and 3 eighths inches (3.845 meters)", spokenLength)
        let spokenArea = MeasureSpoken.text("107.6 sq ft (10.00 m\u{00B2})")
        let spokenTolerance = MeasureSpoken.text("0.6\"")
        let areaOK: Bool = spokenArea == "107.6 square feet (10.00 square meters)"
        let toleranceOK: Bool = spokenTolerance == "0.6 inches"
        log.check("spoken.areaAndTolerance", areaOK && toleranceOK, "\(spokenArea) / \(spokenTolerance)")
        let spoken = MeasureDisplay.accessibilityText(label: Copy.Measure.wallLength, value: wall, kind: .wallLength,
                                                      prefs: imperial)
        let expected = Copy.MeasureCore.spokenWithAccuracy(
            Copy.A11y.measurement(Copy.Measure.wallLength, value: "12 feet 7 and 3 eighths inches (3.845 meters)"),
            accuracy: Copy.Measure.accuracySpoken("1 and 1 quarter inches"))
        log.check("accessibility.wall", spoken == expected, spoken)
        let onStep: Double = MeasureDisplay.roundedUp(0.03, step: 0.005)
        let aboveStep: Double = MeasureDisplay.roundedUp(0.0301, step: 0.005)
        let onStepOK: Bool = abs(onStep - 0.03) < 1e-12
        let aboveStepOK: Bool = abs(aboveStep - 0.035) < 1e-12
        log.check("roundUp.keepsExactStep", onStepOK && aboveStepOK, "\(onStep), \(aboveStep)")
    }

    // MARK: - Dimensions (15 checks)

    /// RoomDimensions rows and object rows.
    static func dimensionChecks(_ log: MeasureCoreSelfTestLog) {
        let fixtures = MeasureCoreSelfTestFixtures.self
        let room = fixtures.room()
        let evidence = fixtures.goodEvidence()
        let rows = RoomDimensions.rows(for: room, evidence: evidence)
        log.check("rows.count", rows.count == 7 + 12 + 2 + 2, "\(rows.count) rows")
        log.check("rows.order", rows.map { $0.id } == fixtures.expectedRowIDs(), rows.map { $0.id }.joined(separator: ","))
        log.check("rows.deterministic", rows == RoomDimensions.rows(for: room, evidence: evidence))
        var groupCounts: [DimensionGroup: Int] = [:]
        for row in rows { groupCounts[row.group, default: 0] += 1 }
        let expectedGroups: [DimensionGroup: Int] = [.room: 7, .walls: 12, .doors: 2, .windows: 2]
        log.check("rows.groups", groupCounts == expectedGroups, "\(groupCounts)")

        let doorWall = fixtures.id(2)
        let doorArea = rows.first { $0.id == "wall.\(doorWall.uuid.uuidString).area" }
        let expectedDoorWall = Double(5 * fixtures.height - fixtures.doorWidth * fixtures.doorHead)
        log.check("rows.doorWallArea", abs((doorArea?.value.value ?? -1) - expectedDoorWall) < 1e-4,
              "\(String(describing: doorArea?.value.value)) vs \(expectedDoorWall)")
        log.check("rows.filterByWall", rows.filter { $0.element == doorWall }.count == 3)
        let wallsNote: Bool = DimensionGroup.walls.note == Copy.MeasureCore.wallAreaNote
        let roomNote: Bool = DimensionGroup.room.note == nil
        log.check("rows.wallAreaNote", wallsNote && roomNote)
        log.check("rows.goodEvidenceNotLow", rows.allSatisfy { !$0.isLowConfidence },
              rows.filter { $0.isLowConfidence }.map { $0.id }.joined(separator: ","))
        let length = rows.first { $0.id == "room.length" }?.value.value ?? 0
        let width = rows.first { $0.id == "room.width" }?.value.value ?? 1
        var swapped = fixtures.metrics()
        swapped.length = 4
        swapped.width = 5
        let swappedRows = RoomDimensions.rows(for: fixtures.room(metrics: swapped), evidence: evidence)
        let swappedLength = swappedRows.first { $0.id == "room.length" }?.value.value ?? 0
        let swappedWidth = swappedRows.first { $0.id == "room.width" }?.value.value ?? 1
        let ordered: Bool = length >= width && swappedLength >= swappedWidth
        log.check("rows.lengthAtLeastWidth", ordered && abs(swappedLength - 5) < 1e-6,
                  "\(length) x \(width), swapped \(swappedLength) x \(swappedWidth)")

        let shaky = RoomEvidence(trackingNormalFraction: 0.5, relocalizations: 0, walls: evidence.walls)
        let shakyRows = RoomDimensions.rows(for: room, evidence: shaky)
        log.check("rows.flagSurvivesArea", shakyRows.first { $0.id == "room.floorArea" }?.isLowConfidence == true)

        var inferredMetrics = fixtures.metrics(volumeProvenance: .inferred)
        inferredMetrics.ceilingProvenance = .inferred
        let inferredRows = RoomDimensions.rows(for: fixtures.room(metrics: inferredMetrics), evidence: evidence)
        let volumeRow = inferredRows.first { $0.id == "room.volume" }
        let volumeSigmaNil: Bool = volumeRow?.value.sigma == nil
        let volumeInferred: Bool = volumeRow?.value.provenance == Provenance.inferred
        let volumeText: String? = volumeRow.flatMap { MeasureDisplay.accuracyText($0.value, kind: $0.kind, prefs: imperial) }
        log.check("rows.inferredVolume", volumeSigmaNil && volumeInferred && volumeText == Copy.Measure.notMeasured,
                  "\(String(describing: volumeRow?.value))")

        let sizes = MeasureRoomSizes(room: fixtures.room(metrics: RoomMetrics.zero), wallAreas: [])
        let sidesOK: Bool = abs(sizes.length - 5) < 1e-3 && abs(sizes.width - 4) < 1e-3
        let areaOK: Bool = abs(sizes.floorArea - 20) < 1e-3 && abs(sizes.perimeter - 18) < 1e-3
        let ceilingOK: Bool = abs(sizes.ceilingHeight - 2.5) < 1e-6
        log.check("sizes.fallbackFromGeometry", sidesOK && areaOK && ceilingOK,
                  "\(sizes.length) x \(sizes.width), \(sizes.floorArea), \(sizes.perimeter), \(sizes.ceilingHeight)")
        log.check("rows.emptyRoom", RoomDimensions.rows(for: fixtures.emptyRoom(), evidence: .unknown).count == 7)

        let objectRows = RoomDimensions.objectRows(for: fixtures.table(), evidence: .unknown)
        let objectKey = "object.\(fixtures.id(20).uuid.uuidString)"
        let expectedIDs: [String] = ["\(objectKey).width", "\(objectKey).height", "\(objectKey).depth"]
        let expectedTitles: [String] = [Copy.Viewer.width, Copy.Viewer.height, Copy.Viewer.depth]
        let tableID = fixtures.id(20)
        let idsOK: Bool = objectRows.map { $0.id } == expectedIDs
        let titlesOK: Bool = objectRows.map { $0.title } == expectedTitles
        let groupOK: Bool = objectRows.allSatisfy { $0.group == .objects && $0.element == tableID }
        log.check("objectRows.shape", idsOK && titlesOK && groupOK)
        let floorOK: Bool = objectRows.allSatisfy { ($0.value.sigma ?? 0) >= floorSigma - 1e-12 }
        let noneLow: Bool = !objectRows.contains { $0.isLowConfidence }
        log.check("objectRows.floorAndNotLow", floorOK && noneLow,
                  objectRows.map { "\($0.id) \(String(describing: $0.value.sigma))" }.joined(separator: ", "))
    }

    // MARK: - Snapping (10 checks)

    /// SnapSet of the 4 x 5 x 2.5 room.
    static func snapChecks(_ log: MeasureCoreSelfTestLog) {
        let fixtures = MeasureCoreSelfTestFixtures.self
        let bare = fixtures.room(includeOpenings: false)
        let snaps = SnapSet.build(from: bare, includeObjects: false)
        log.check("snap.eightCorners", snaps.corners.count == 8 && snaps.cornerElements.count == 8, "\(snaps.corners.count) corners")
        log.check("snap.deterministic", snaps == SnapSet.build(from: bare, includeObjects: false))

        let nearCorner = SIMD3<Float>(4, 0, -5) + SIMD3<Float>(-0.02, 0.02, 0.01)
        let corner = snaps.snap(nearCorner)
        log.check("snap.corner", corner.kind == .corner && simd_distance(corner.point, SIMD3<Float>(4, 0, -5)) < 1e-5,
              "\(corner.kind)")
        let topMiddle = SIMD3<Float>(4, fixtures.height, -2.5) + SIMD3<Float>(-0.03, 0, 0)
        let edge = snaps.snap(topMiddle)
        log.check("snap.edge", edge.kind == .edge && abs(edge.point.y - fixtures.height) < 1e-5, "\(edge.kind)")
        let nearWall = SIMD3<Float>(4 - 0.02, 1.25, -2.5)
        let plane = snaps.hit(nearWall)
        let wallTwo = fixtures.id(2)
        let planeKindOK: Bool = plane.kind == .plane && plane.feature == SnapSetFeature.wall
        let planeTargetOK: Bool = plane.element == wallTwo && abs(plane.point.x - 4) < 1e-5
        log.check("snap.plane", planeKindOK && planeTargetOK, "\(plane.kind)")
        let inside = SIMD3<Float>(1, 1.25, -1.5)
        let interior = snaps.snap(inside)
        log.check("snap.none", interior.kind == SnapKind.none && interior.point == inside, "\(interior.kind)")
        let beyondWall = snaps.snap(SIMD3<Float>(6, 1.25, -0.02))
        log.check("snap.planeLimitedToWall", beyondWall.kind == SnapKind.none, "\(beyondWall.kind)")
        let floorHit = snaps.hit(SIMD3<Float>(1, 0.03, -1.5))
        let floorKindOK: Bool = floorHit.kind == .plane && floorHit.feature == SnapSetFeature.floor
        log.check("snap.floor", floorKindOK && abs(floorHit.point.y) < 1e-5, "\(floorHit.kind)")

        let full = SnapSet.build(from: fixtures.room(), includeObjects: true)
        let expectedCorners = 8 + 4 + 4 + 8
        let expectedEdges = 12 + 4 + 4 + 12
        log.check("snap.openingsAndObjects", full.corners.count == expectedCorners && full.edges.count == expectedEdges,
                  "\(full.corners.count) corners, \(full.edges.count) edges")
        let doorEdge = full.hit(SIMD3<Float>(4 - 0.02, 1.0, -1.0 - 0.02))
        let doorFeatureOK: Bool = doorEdge.kind == .edge && doorEdge.feature == SnapSetFeature.door
        let doorText: String? = doorEdge.feature?.snappedText
        log.check("snap.doorFeature", doorFeatureOK && doorText == Copy.Measure.snapped(to: "door"),
                  "\(doorEdge.kind) \(String(describing: doorEdge.feature))")
    }
}

/// Collects the results of `MeasureCoreSelfTest` checks.
final class MeasureCoreSelfTestLog {
    /// One line per failing check.
    private(set) var failures: [String] = []
    /// Number of checks run.
    private(set) var count = 0

    /// Records one check; `detail` is evaluated only when it fails.
    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "failed") {
        count += 1
        if !ok { failures.append("\(name): \(detail())") }
    }
}
