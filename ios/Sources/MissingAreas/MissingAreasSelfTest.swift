import Foundation
import simd

// Self-test of MissingAreas (docs/MODULES.md 3.40): the walking order, the D19 filter, the
// watched sample points, the arrow and its directions, the tour's fill, advance, pass and
// unscannable rules, the presentation texts, the VoiceOver throttle, the tour guidance rule,
// and (in MissingAreasSelfTest+Files.swift) the seed and the evaluation after the tour in a
// temporary package. Deterministic, no ARKit, no camera, no network.

/// `MissingAreasSelfTest.run()` returns one line per failing check, empty when all pass.
enum MissingAreasSelfTest {
    /// Collects failing checks.
    struct Checker {
        /// "name: detail" per failing check.
        private(set) var failures: [String] = []
        /// Number of checks run.
        private(set) var count = 0

        /// Records a failure when `ok` is false.
        mutating func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            count += 1
            guard !ok else { return }
            let text = detail()
            failures.append(name + ": " + (text.isEmpty ? "failed" : text))
        }

        /// Records a failure when `value` is farther than `tolerance` from `expected`.
        mutating func near(_ name: String, _ value: Float, _ expected: Float, _ tolerance: Float) {
            check(name, value.isFinite && abs(value - expected) <= tolerance, "\(value) vs \(expected)")
        }
    }

    /// Runs every check.
    static func run() -> [String] {
        var c = Checker()
        checkOrderAndFilter(&c)
        checkSamples(&c)
        checkArrows(&c)
        checkUpdates(&c)
        checkUnscannable(&c)
        checkFinish(&c)
        checkPresentation(&c)
        checkFiles(&c)
        return c.failures
    }

    // MARK: - Fixtures

    /// Eye height of the fixture viewpoints, meters.
    static let eye: Float = 1.4

    /// A missing area record.
    static func record(_ id: Int, centroid: SIMD3<Float>, normal: SIMD3<Float> = SIMD3<Float>(0, 0, 1), area: Float = 0.5,
                       surface: SurfaceClass = .wall, viewpoint: SIMD3<Float>) -> MissingAreaRecord {
        MissingAreaRecord(id: id, centroid: Vec3(centroid), normal: Vec3(normal), area: area, surface: surface.rawValue,
                          suggestedViewpoint: Vec3(viewpoint))
    }

    /// A wall area 1.5 m in front (-z) of a viewpoint at eye height at (x, z).
    static func wallAhead(_ id: Int, x: Float, z: Float = 0) -> MissingAreaRecord {
        record(id, centroid: SIMD3<Float>(x, eye, z - 1.5), viewpoint: SIMD3<Float>(x, eye, z))
    }

    /// Camera to world with the identity rotation (looking along -z) at `p`.
    static func camera(at p: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(p.x, p.y, p.z, 1)
        return m
    }

    /// A camera at `p` looking straight down with its top edge (-X column) toward -z.
    static func cameraLookingDown(at p: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 1, 0, 0),
                                SIMD4<Float>(p.x, p.y, p.z, 1)))
    }

    /// The three-stop fixture: viewpoints at x = 0, 2 and 5 (ids 10, 11, 12), ordered from the origin.
    static func threeStops() -> MissingAreaTour {
        MissingAreaTour(records: [wallAhead(10, x: 0), wallAhead(11, x: 2), wallAhead(12, x: 5)],
                        start: SIMD3<Float>(0, eye, 0))
    }

    /// A point far from every fixture viewpoint (nothing is faced from there).
    static let farAway = SIMD3<Float>(40, 1.4, 40)

    // MARK: - Order and filter

    /// Checks 1 and 2 plus duplicate ids.
    static func checkOrderAndFilter(_ c: inout Checker) {
        let records = [wallAhead(0, x: 1), wallAhead(1, x: 5), wallAhead(2, x: 3)]
        let order = MissingAreaTour.order(records, from: SIMD3<Float>(0, eye, 0))
        let xs = order.map { records[$0].suggestedViewpoint.x }
        c.check("order.nearestViewpointFirst", order == [0, 2, 1] && xs == [1, 3, 5], "\(order)")
        c.check("order.empty", MissingAreaTour.order([], from: .zero).isEmpty)

        let mixed = [
            record(1, centroid: SIMD3<Float>(0, 1, -2), surface: .wall, viewpoint: SIMD3<Float>(0, eye, 0)),
            record(2, centroid: SIMD3<Float>(1, 0, -1), normal: SIMD3<Float>(0, 1, 0), surface: .floor,
                   viewpoint: SIMD3<Float>(1, eye, -1)),
            record(3, centroid: SIMD3<Float>(2, 2.5, -1), normal: SIMD3<Float>(0, -1, 0), surface: .ceiling,
                   viewpoint: SIMD3<Float>(2, eye, -1)),
            record(4, centroid: SIMD3<Float>(3, 1.2, -2), surface: .window, viewpoint: SIMD3<Float>(3, eye, 0)),
            record(5, centroid: SIMD3<Float>(4, 1.0, -2), surface: .door, viewpoint: SIMD3<Float>(4, eye, 0)),
        ]
        let tour = MissingAreaTour(records: mixed, start: .zero)
        let kept = Set(tour.stops.map { $0.id })
        c.check("init.dropsWindowsAndDoors", kept == [1, 2, 3], "\(kept.sorted())")
        let surfaces = Set(tour.stops.map { $0.record.surface })
        c.check("init.keepsWallFloorCeiling", surfaces == [1, 2, 3], "\(surfaces.sorted())")
        let fresh: Bool = tour.stops.allSatisfy { $0.status == .pending && $0.fraction == 0 && $0.facingSeconds == 0 }
        let sampled: Bool = tour.stops.allSatisfy { !$0.samplePoints.isEmpty }
        c.check("init.stopsPendingWithSamples", fresh && sampled && tour.currentIndex == 0)
        let repeated = MissingAreaTour(records: [wallAhead(7, x: 1), wallAhead(7, x: 4)], start: .zero)
        c.check("init.repeatedIdKeepsFirst", repeated.stops.count == 1 && repeated.stops.first?.record.suggestedViewpoint.x == 1)
        c.check("offer.onlyWithVisitableAreas", offerChecks())
    }

    /// `MissingAreasModel.isOffered`: false after a system stop, without areas, or with windows only.
    private static func offerChecks() -> Bool {
        let base = QualityEvaluation(roomID: fixedID(2),
                                     summary: QualitySummary(shape: 0.5, walls: 0.5, floor: 0.5, ceiling: 0.5, texture: 0.5,
                                                             missingAreas: 1),
                                     missingAreas: [wallAhead(1, x: 0)], degraded: .allGood,
                                     evidence: RoomEvidence.unknown,
                                     darkKeyframeFraction: 0, inputHash: "test",
                                     evaluatedAt: Date(timeIntervalSince1970: 1_790_000_000))
        var windowsOnly = base
        windowsOnly.missingAreas = [record(2, centroid: SIMD3<Float>(0, 1, -2), surface: .window, viewpoint: .zero)]
        var none = base
        none.missingAreas = []
        let yes = MissingAreasModel.isOffered(evaluation: base, stoppedBySystem: false)
        let stopped = MissingAreasModel.isOffered(evaluation: base, stoppedBySystem: true)
        let windows = MissingAreasModel.isOffered(evaluation: windowsOnly, stoppedBySystem: false)
        let empty = MissingAreasModel.isOffered(evaluation: none, stoppedBySystem: false)
        let missing = MissingAreasModel.isOffered(evaluation: nil, stoppedBySystem: false)
        return yes && !stopped && !windows && !empty && !missing
    }

    // MARK: - Samples

    /// Check 3: sample points in the plane, within the radius, centroid included, tiny areas.
    static func checkSamples(_ c: inout Checker) {
        let center = SIMD3<Float>(1, 1.2, -3)
        let wall = record(1, centroid: center, normal: SIMD3<Float>(0, 0, 1), area: 0.5, viewpoint: .zero)
        let points = MissingAreaTour.samplePoints(for: wall, spacing: MissingAreaTour.sampleSpacing)
        let normal = SIMD3<Float>(0, 0, 1)
        let offPlane = points.map { abs(simd_dot($0 - center, normal)) }.max() ?? 1
        c.check("samples.inPlane", offPlane <= 1e-5, "\(offPlane)")
        let reach = points.map { simd_distance($0, center) }.max() ?? 1
        c.check("samples.withinRadius", reach <= 0.4 && points.count > 1, "reach \(reach), \(points.count) points")
        c.check("samples.centroidIncluded", points.contains(center))
        let tiny = record(2, centroid: center, area: 0.01, viewpoint: .zero)
        c.check("samples.tinyAreaHasOne", MissingAreaTour.samplePoints(for: tiny, spacing: 0.2).count >= 1)
        let slanted = SIMD3<Float>(1, 1, 0) / Float(2).squareRoot()
        let tilted = record(3, centroid: center, normal: SIMD3<Float>(1, 1, 0), area: 1.2, viewpoint: .zero)
        let tiltedPoints = MissingAreaTour.samplePoints(for: tilted, spacing: 0.2)
        let tiltedOff = tiltedPoints.map { abs(simd_dot($0 - center, slanted)) }.max() ?? 1
        c.check("samples.slantedPlane", tiltedOff <= 1e-5 && tiltedPoints.count > 9, "\(tiltedOff), \(tiltedPoints.count)")
    }

    // MARK: - Arrows

    /// Checks 4, 5, 6 and 15.
    static func checkArrows(_ c: inout Checker) {
        let origin = camera(at: .zero)
        let halfPi = Float.pi / 2
        let targets: [(String, SIMD3<Float>, Float, MissingAreaDirection)] = [
            ("ahead", SIMD3<Float>(0, 0, -2), 0, .ahead), ("right", SIMD3<Float>(2, 0, 0), halfPi, .right),
            ("left", SIMD3<Float>(-2, 0, 0), -halfPi, .left), ("behind", SIMD3<Float>(0, 0, 2), Float.pi, .behind),
        ]
        for (name, viewpoint, bearing, direction) in targets {
            let area = record(1, centroid: viewpoint + SIMD3<Float>(0, 0, -1), viewpoint: viewpoint)
            let arrow = MissingAreaTour.arrow(cameraToWorld: origin, record: area)
            let isBehind: Bool = name == "behind"
            let behindError: Float = abs(abs(arrow.bearing) - Float.pi)
            let bearingError: Float = abs(arrow.bearing - bearing)
            let bearingOK: Bool = isBehind ? behindError <= 1e-4 : bearingError <= 1e-4
            let found = MissingAreaTour.direction(arrow)
            let directionOK: Bool = found == direction
            c.check("arrow.\(name)", bearingOK && directionOK && !arrow.atViewpoint,
                    "bearing \(arrow.bearing), \(found)")
        }
        let aheadArrow = MissingAreaTour.arrow(cameraToWorld: origin, record: record(1, centroid: SIMD3<Float>(0, 0, -3),
                                                                                      viewpoint: SIMD3<Float>(0, 0, -2)))
        c.near("arrow.distanceToViewpoint", aheadArrow.horizontalDistance, 2, 1e-5)

        let standing = SIMD3<Float>(0, eye, -1)
        let ceiling = record(2, centroid: SIMD3<Float>(0, 2.5, -1), normal: SIMD3<Float>(0, -1, 0), surface: .ceiling,
                             viewpoint: standing)
        let up = MissingAreaTour.arrow(cameraToWorld: camera(at: standing), record: ceiling)
        let steep: Float = 35 * Float.pi / 180
        c.check("arrow.ceilingUp", up.atViewpoint && up.pitch > steep && MissingAreaTour.direction(up) == .up,
                "pitch \(up.pitch)")
        let floor = record(3, centroid: SIMD3<Float>(0, 0, -1), normal: SIMD3<Float>(0, 1, 0), surface: .floor,
                           viewpoint: standing)
        let down = MissingAreaTour.arrow(cameraToWorld: camera(at: standing), record: floor)
        c.check("arrow.floorDown", down.atViewpoint && down.pitch < -steep && MissingAreaTour.direction(down) == .down,
                "pitch \(down.pitch)")

        let looking = cameraLookingDown(at: .zero)
        let downAhead = MissingAreaTour.arrow(cameraToWorld: looking, record: record(4, centroid: SIMD3<Float>(0, 0, -3),
                                                                                     viewpoint: SIMD3<Float>(0, 0, -2)))
        let downRight = MissingAreaTour.arrow(cameraToWorld: looking, record: record(5, centroid: SIMD3<Float>(3, 0, 0),
                                                                                     viewpoint: SIMD3<Float>(2, 0, 0)))
        let topAhead: Bool = abs(downAhead.bearing) <= 1e-4
        let topRight: Bool = abs(downRight.bearing - halfPi) <= 1e-4
        c.check("arrow.lookingDownUsesTopEdge", topAhead && topRight, "\(downAhead.bearing) \(downRight.bearing)")

        let degree = Float.pi / 180
        let cases: [(Float, MissingAreaDirection)] = [(44, .ahead), (46, .right), (-46, .left), (134, .right),
                                                      (136, .behind), (-136, .behind), (-44, .ahead)]
        var wrong: [String] = []
        for (degrees, expected) in cases {
            let arrow = MissingAreaArrow(bearing: degrees * degree, pitch: 0, horizontalDistance: 2, atViewpoint: false)
            if MissingAreaTour.direction(arrow) != expected { wrong.append("\(degrees)") }
        }
        c.check("direction.boundaries", wrong.isEmpty, wrong.joined(separator: " "))
        let steepAway = MissingAreaArrow(bearing: 0, pitch: 60 * degree, horizontalDistance: 2, atViewpoint: false)
        c.check("direction.pitchOnlyAtViewpoint", MissingAreaTour.direction(steepAway) == .ahead)
    }

    // MARK: - Updates

    /// Checks 7 to 10.
    static func checkUpdates(_ c: inout Checker) {
        let far = camera(at: farAway)
        var single = MissingAreaTour(records: [wallAhead(3, x: 0)], start: .zero)
        let below = single.update(fractions: [3: 0.79], cameraToWorld: far, seconds: 0.1, trackingNormal: true)
        let stillPending: Bool = single.stops.first?.status == .pending
        let keptFraction: Bool = single.stops.first?.fraction == Float(0.79)
        c.check("update.belowFilledStaysPending", below.isEmpty && stillPending && keptFraction)
        let filled = single.update(fractions: [3: 0.8], cameraToWorld: far, seconds: 0.1, trackingNormal: true)
        let nowFilled: Bool = single.stops.first?.status == .filled
        c.check("update.fillsAtThreshold", filled.contains(.filled(3)) && nowFilled, "\(filled)")

        var tour = threeStops()
        let walkingIDs: [Int] = tour.stops.map { $0.id }
        let firstCurrent: Bool = tour.currentStop?.id == 10
        c.check("update.walkingOrder", walkingIDs == [10, 11, 12] && firstCurrent)
        let advanced = tour.update(fractions: [10: 0.95], cameraToWorld: camera(at: SIMD3<Float>(5, eye, 0)), seconds: 0.1,
                                   trackingNormal: true)
        let advancedEvents: [MissingAreaTourEvent] = [.filled(10), .advanced(12)]
        let nearestCurrent: Bool = tour.currentStop?.id == 12
        c.check("update.advancesToNearestPending", advanced == advancedEvents && nearestCurrent, "\(advanced)")

        var other = threeStops()
        let side = other.update(fractions: [11: 0.9], cameraToWorld: far, seconds: 0.1, trackingNormal: true)
        let sideEvents: [MissingAreaTourEvent] = [.filled(11)]
        let sameCurrent: Bool = other.currentStop?.id == 10
        let sideFilled: Bool = other.stops[1].status == .filled
        c.check("update.fillsNonCurrent", side == sideEvents && sameCurrent && sideFilled, "\(side)")

        var skipping = threeStops()
        let passed = skipping.next()
        let passedEvents: [MissingAreaTourEvent] = [.advanced(11)]
        let firstPassed: Bool = skipping.stops[0].status == .passed
        let nextCurrent: Bool = skipping.currentStop?.id == 11
        c.check("next.passesAndAdvances", passed == passedEvents && firstPassed && nextCurrent, "\(passed)")
        let clamped = skipping.update(fractions: [11: 7, 12: -3], cameraToWorld: far, seconds: 0.1, trackingNormal: true)
        let clampedLow: Bool = skipping.stops[2].fraction == 0
        c.check("update.clampsFractions", clamped.contains(.filled(11)) && clampedLow)
        var broken = threeStops()
        var nan = matrix_identity_float4x4
        nan.columns.3 = SIMD4<Float>(Float.nan, 0, 0, 1)
        let nothing = broken.update(fractions: [:], cameraToWorld: nan, seconds: 0.1, trackingNormal: true)
        let unchangedCurrent: Bool = broken.currentStop?.id == 10
        let noFacing: Bool = broken.stops[0].facingSeconds == 0
        c.check("update.nonFiniteCameraIgnored", nothing.isEmpty && unchangedCurrent && noFacing)
    }

    // MARK: - Unscannable

    /// Checks 11 and 12 plus the progress rule.
    static func checkUnscannable(_ c: inout Checker) {
        let area = wallAhead(4, x: 0)
        let standing = camera(at: SIMD3<Float>(0, eye, 0))
        c.check("facing.fromViewpoint", MissingAreaTour.isFacing(cameraToWorld: standing, record: area))

        var glass = MissingAreaTour(records: [area], start: .zero)
        var early: [MissingAreaTourEvent] = []
        for _ in 0..<7 {
            early += glass.update(fractions: [4: 0.2], cameraToWorld: standing, seconds: 1, trackingNormal: true)
        }
        let last = glass.update(fractions: [4: 0.2], cameraToWorld: standing, seconds: 1, trackingNormal: true)
        let gaveUp: Bool = last.contains(.unscannable(4)) && last.contains(.finished)
        let glassStatus: Bool = glass.stops[0].status == .unscannable
        c.check("unscannable.after8Seconds", early.isEmpty && gaveUp && glassStatus && glass.isFinished, "\(early) \(last)")

        var partial = MissingAreaTour(records: [area], start: .zero)
        for _ in 0..<10 {
            _ = partial.update(fractions: [4: 0.35], cameraToWorld: standing, seconds: 1, trackingNormal: true)
        }
        c.check("unscannable.notAboveMaxFraction", partial.stops[0].status == .pending, "\(partial.stops[0].status)")

        var limited = MissingAreaTour(records: [area], start: .zero)
        for _ in 0..<10 {
            _ = limited.update(fractions: [4: 0.1], cameraToWorld: standing, seconds: 1, trackingNormal: false)
        }
        let limitedNoTime: Bool = limited.stops[0].facingSeconds == 0
        let limitedPending: Bool = limited.stops[0].status == .pending
        c.check("facing.needsNormalTracking", limitedNoTime && limitedPending)

        let back = camera(at: SIMD3<Float>(0, eye, 1.5))
        c.check("facing.notFrom1_5m", !MissingAreaTour.isFacing(cameraToWorld: back, record: area))
        var away = MissingAreaTour(records: [area], start: .zero)
        for _ in 0..<10 {
            _ = away.update(fractions: [4: 0.1], cameraToWorld: back, seconds: 1, trackingNormal: true)
        }
        c.check("facing.noTimeAwayFromViewpoint", away.stops[0].facingSeconds == 0)

        var progressing = MissingAreaTour(records: [area], start: .zero)
        for step in 0..<10 {
            _ = progressing.update(fractions: [4: 0.06 * Float(step) / 2], cameraToWorld: standing, seconds: 1,
                                   trackingNormal: true)
        }
        c.check("unscannable.progressRestartsFacing", progressing.stops[0].status == .pending
                && progressing.stops[0].facingSeconds < MissingAreaTour.unscannableSeconds,
                "\(progressing.stops[0].facingSeconds)")

        var burst = MissingAreaTour(records: [area], start: .zero)
        _ = burst.update(fractions: [4: 0.1], cameraToWorld: standing, seconds: 30, trackingNormal: true)
        c.check("facing.longGapClamped", burst.stops[0].facingSeconds == MissingAreaTour.maxUpdateSeconds)
    }

    // MARK: - Finish

    /// Checks 13 and 14.
    static func checkFinish(_ c: inout Checker) {
        let far = camera(at: farAway)
        var tour = threeStops()
        _ = tour.update(fractions: [10: 0.9], cameraToWorld: far, seconds: 0.1, trackingNormal: true)
        let afterFill = tour.remainingCount
        _ = tour.next()
        let afterPass = tour.remainingCount
        let lastEvents = tour.next()
        let statuses = tour.stops.map { $0.status }
        let remaining: [Int] = [afterFill, afterPass, tour.remainingCount]
        c.check("finish.remainingCountsPending", remaining == [2, 1, 0], "\(remaining)")
        let noCurrent: Bool = tour.currentIndex == nil
        let finishedEvent: Bool = lastEvents.contains(.finished)
        let nonePending: Bool = !statuses.contains(.pending)
        c.check("finish.whenAllResolved", tour.isFinished && noCurrent && finishedEvent && nonePending, "\(lastEvents)")
        let nextAfter = tour.next()
        let updateAfter = tour.update(fractions: [:], cameraToWorld: far, seconds: 0.1, trackingNormal: true)
        c.check("finish.nextAfterFinishIsEmpty", nextAfter.isEmpty && updateAfter.isEmpty)

        var empty = MissingAreaTour(records: [], start: .zero)
        let emptyEvents = empty.update(fractions: [:], cameraToWorld: far, seconds: 0.1, trackingNormal: true)
        let emptyCount: Bool = empty.remainingCount == 0
        let emptyCurrent: Bool = empty.currentIndex == nil
        c.check("finish.emptyAtOnce", empty.isFinished && emptyCount && emptyCurrent && emptyEvents.isEmpty)
        let doorsOnly = MissingAreaTour(records: [record(1, centroid: .zero, surface: .door, viewpoint: .zero)], start: .zero)
        c.check("finish.doorsOnlyIsEmpty", doorsOnly.isFinished && doorsOnly.stops.isEmpty)
    }

    // MARK: - Presentation, VoiceOver, guidance

    /// Checks 19 and 20 plus the HUD texts and the announcement throttle.
    static func checkPresentation(_ c: inout Checker) {
        let prefs = UnitPreferences.standard
        let length = LengthFormat.display(1.5, prefs: prefs)
        let line = Copy.MissingAreas.distanceAway(length)
        c.check("copy.distanceAwayContainsLength", !length.isEmpty && line.contains(length), line)
        var metric = prefs
        metric.system = .metric
        metric.showBoth = false
        let walking = MissingAreaArrow(bearing: 0, pitch: 0, horizontalDistance: 2, atViewpoint: false)
        let shown = MissingAreasPresentation.distanceText(walking, units: metric)
        c.check("hud.distanceWhileWalking", shown == Copy.MissingAreas.distanceAway(LengthFormat.display(2, prefs: metric)))
        let arrived = MissingAreaArrow(bearing: 0, pitch: 1.2, horizontalDistance: 0, atViewpoint: true)
        c.check("hud.noDistanceAtViewpoint", MissingAreasPresentation.distanceText(arrived, units: metric) == nil)
        let lowered = MissingAreaArrow(bearing: 0, pitch: -1.2, horizontalDistance: 0, atViewpoint: true)
        let hints: [String] = [MissingAreasPresentation.hintText(arrived), MissingAreasPresentation.hintText(lowered),
                               MissingAreasPresentation.hintText(walking), MissingAreasPresentation.hintText(nil)]
        let expectedHints: [String] = [GuidanceKind.scanCeiling.message.text, GuidanceKind.pointAtFloor.message.text,
                                       Copy.Quality.missingAreaHint, Copy.Quality.missingAreaHint]
        c.check("hud.upAndDownHints", hints == expectedHints)
        var tour = threeStops()
        let firstStep = MissingAreasPresentation.stepText(tour)
        _ = tour.next()
        let secondStep = MissingAreasPresentation.stepText(tour)
        let firstOK: Bool = firstStep == Copy.Quality.missingAreaStep(1, of: 3)
        let secondOK: Bool = secondStep == Copy.Quality.missingAreaStep(2, of: 3)
        c.check("hud.stepLine", firstOK && secondOK)
        c.check("hud.noStepWhenEmpty", MissingAreasPresentation.stepText(MissingAreaTour(records: [], start: .zero)) == nil)
        let directions: [MissingAreaDirection] = [.ahead, .left, .right, .behind, .up, .down]
        let spoken = Set(directions.map { MissingAreasPresentation.spokenText($0) })
        c.check("hud.spokenTextsDistinct", spoken.count == 6 && !spoken.contains(""))
        let notRotated: Bool = MissingAreasPresentation.rotationRadians(arrived) == 0
        let downSymbol: Bool = MissingAreasPresentation.symbolName(lowered) == "arrow.down.circle.fill"
        c.check("hud.upDownNotRotated", notRotated && downSymbol)

        var announcer = MissingAreasAnnouncer()
        let first = announcer.shouldAnnounce(.left, now: 10)
        let same = announcer.shouldAnnounce(.left, now: 20)
        let soon = announcer.shouldAnnounce(.right, now: 11)
        let later = announcer.shouldAnnounce(.right, now: 13.1)
        announcer.reset()
        let again = announcer.shouldAnnounce(.right, now: 16.2)
        announcer.noteSpoken(now: 20)
        let afterNotice = announcer.shouldAnnounce(.ahead, now: 21)
        c.check("voiceOver.throttle", first && !same && !soon && later && again && !afterNotice,
                "\(first) \(same) \(soon) \(later) \(again) \(afterNotice)")

        var input = GuidanceInput(time: 5)
        input.tracking = .excessiveMotion
        input.angularSpeed = 2
        input.linearSpeed = 1.5
        input.centerDistance = 0.2
        input.ambientIntensity = 100
        input.deviceHot = true
        input.viewCoverage = 0.3
        input.nearbyMissing = [MissingArea(centroid: .zero, normal: SIMD3<Float>(0, 0, 1), area: 1, surface: .wall,
                                           suggestedViewpoint: .zero)]
        input.overallComplete = true
        MissingAreasModel.tourGuidance(&input)
        let coverageCleared: Bool = input.viewCoverage == nil
        let cleared: Bool = coverageCleared && input.nearbyMissing.isEmpty && !input.overallComplete
        let trackingKept: Bool = input.tracking == .excessiveMotion
        let angularKept: Bool = input.angularSpeed == Float(2)
        let linearKept: Bool = input.linearSpeed == Float(1.5)
        let distanceKept: Bool = input.centerDistance == Float(0.2)
        let lightKept: Bool = input.ambientIntensity == Float(100)
        let speedsKept: Bool = trackingKept && angularKept && linearKept
        let kept: Bool = speedsKept && distanceKept && lightKept && input.deviceHot
        c.check("guidance.tourClearsCoverageKeepsSafety", cleared && kept)
    }
}
