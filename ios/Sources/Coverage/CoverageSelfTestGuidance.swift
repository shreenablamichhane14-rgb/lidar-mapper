import Foundation
import simd

// Guidance engine and measurement confidence checks for CoverageSelfTest. Guidance traces run
// a fresh engine on a 0.25 s tick (exact binary times), so every timing rule of
// GuidancePolicy lands on an exact tick: hold 0.75 s = 3 ticks, gap 3 s, cooldown 10 s.

/// Short alias for the fixtures.
private typealias CSTG = CoverageSelfTestFixtures

extension CoverageSelfTest {
    // MARK: - Guidance

    /// Priorities, hold, interruption, minimum time, gap, cooldowns, tier 3 rules, events,
    /// haptics and flicker resistance of `GuidanceEngine`.
    static func checkGuidance(_ c: inout CoverageSelfTestChecker) {
        // Main timeline: a wall event, then tracking lost (tier 1 interrupts tier 3), tier 3
        // quiet time, a door event, a tier 2 message held back by the gap, then its cooldown.
        let main = CSTG.GuidanceTrace(ticks: 109) { t in
            var g = GuidanceInput(time: t)
            if t == 0 { g.newWalls = 1 }
            if t >= 0.25 && t <= 2.0 { g.tracking = .relocalizing }
            if t == 8.0 || t == 9.25 { g.newDoors = 1 }
            if (t >= 11.0 && t < 15.0) || t >= 20.0 { g.centerDistance = 4.0 }
            return g
        }
        c.check("guidance.eventBypassesHold", main.message(at: 0) == .wallDetected && !main.at(0).fireHaptic)
        c.check("guidance.conditionHold", main.message(at: 0.75) == .wallDetected, "got \(String(describing: main.message(at: 0.75)))")
        c.check("guidance.tier1InterruptsTier3AtOnce", main.message(at: 1.0) == .trackingLost && main.at(1.0).fireHaptic)
        c.check("guidance.tier1MinimumTime", main.message(at: 3.75) == .trackingLost && main.message(at: 4.0) == nil)
        c.check("guidance.tier3QuietAfterTier1", main.message(at: 8.0) == nil && main.message(at: 9.0) == nil)
        c.check("guidance.eventAfterQuiet", main.message(at: 9.25) == .doorDetected)
        c.check("guidance.eventHidesAfterMinimum", main.message(at: 10.5) == .doorDetected && main.message(at: 10.75) == nil)
        c.check("guidance.minimumGap", main.message(at: 13.5) == nil && main.message(at: 13.75) == .moveCloser
                && !main.at(13.75).fireHaptic)
        c.check("guidance.tier2MinimumTime", main.message(at: 16.0) == .moveCloser && main.message(at: 16.25) == nil)
        c.check("guidance.repeatCooldown", main.message(at: 26.0) == nil && main.message(at: 26.25) == .moveCloser)

        // Haptics: first tier 1 buzzes; a second tier 1 within 5 s does not; later one does.
        let haptic = CSTG.GuidanceTrace(ticks: 33) { t in
            var g = GuidanceInput(time: t)
            if t <= 0.75 { g.tracking = .excessiveMotion } else if t <= 5.0 { g.tracking = .relocalizing }
            if t >= 7.0 { g.centerDistance = 0.1 }
            return g
        }
        c.check("guidance.holdBeforeShow", haptic.message(at: 0.5) == nil && haptic.message(at: 0.75) == .moveSlower
                && haptic.at(0.75).fireHaptic)
        c.check("guidance.equalTierNoInterrupt", haptic.message(at: 1.75) == .moveSlower)
        c.check("guidance.tier1IgnoresGap", haptic.message(at: 3.75) == .trackingLost)
        c.check("guidance.hapticCooldown", !haptic.at(3.75).fireHaptic)
        c.check("guidance.hapticAfterCooldown", haptic.message(at: 7.75) == .tooClose && haptic.at(7.75).fireHaptic)
        c.check("guidance.hapticCount", haptic.hapticCount == 2, "got \(haptic.hapticCount)")

        // Tier 2 replaces a tier 3 message once that had its minimum time, without the gap.
        let takeover = CSTG.GuidanceTrace(ticks: 12) { t in
            var g = GuidanceInput(time: t)
            if t == 0 { g.newWalls = 1 }
            g.centerDistance = 4.0
            return g
        }
        c.check("guidance.tier2ReplacesTier3AtMinimum", takeover.message(at: 1.25) == .wallDetected
                && takeover.message(at: 1.5) == .moveCloser)
        // A tier 3 condition shows once per run of being true, not again after each cooldown.
        let complete = CSTG.GuidanceTrace(ticks: 121) { t in
            var g = GuidanceInput(time: t)
            g.overallComplete = true
            return g
        }
        c.check("guidance.completeOncePerRun", complete.message(at: 0.75) == .roomLooksComplete
                && complete.appearances(before: 30) == 1, "got \(complete.appearances(before: 30))")

        // Priorities: tier 1 beats tier 2; within tier 1 the table order wins.
        let tiers = CSTG.GuidanceTrace(ticks: 4) { t in
            var g = GuidanceInput(time: t)
            g.ambientIntensity = 100
            g.centerDistance = 4.0
            return g
        }
        c.check("guidance.tier1BeatsTier2", tiers.message(at: 0.75) == .lightingPoor)
        let order = CSTG.GuidanceTrace(ticks: 4) { t in
            var g = GuidanceInput(time: t)
            g.ambientIntensity = 100
            g.tracking = .relocalizing
            return g
        }
        c.check("guidance.tableOrderWithinTier", order.message(at: 0.75) == .trackingLost)

        // No flicker: a condition toggling every tick never passes the hold.
        let toggle = CSTG.GuidanceTrace(ticks: 20) { t in
            var g = GuidanceInput(time: t)
            g.centerDistance = (Int(t * 4) % 2 == 0) ? Float(0.1) : Float(1.0)
            return g
        }
        c.check("guidance.noFlicker.toggle", toggle.changeCount == 0, "changes \(toggle.changeCount)")
        // No flicker: a value hovering at the threshold keeps the message up (hysteresis).
        let hover = CSTG.GuidanceTrace(ticks: 41) { t in
            var g = GuidanceInput(time: t)
            g.ambientIntensity = t <= 0.75 ? Float(290) : ((Int(t * 4) % 2 == 0) ? Float(310) : Float(290))
            return g
        }
        c.check("guidance.noFlicker.hysteresis", hover.message(at: 0.75) == .lightingPoor && hover.changeCount == 1
                && hover.hapticCount == 1, "changes \(hover.changeCount)")

        // Tier 3 cap: at most 4 per rolling minute, table order among events.
        let events = CSTG.GuidanceTrace(ticks: 245) { t in
            var g = GuidanceInput(time: t)
            g.newWindows = 1
            g.newDoors = 1
            g.newWalls = 1
            return g
        }
        c.check("guidance.eventOrder", events.message(at: 0) == .windowDetected)
        c.check("guidance.tier3Cap", events.appearances(before: 60) == 4, "got \(events.appearances(before: 60))")
        c.check("guidance.tier3CapRolls", events.message(at: 59.75) == nil && events.message(at: 60) != nil)

        // Condition mapping.
        let engine = GuidanceEngine()
        var limited = GuidanceInput(time: 0)
        limited.tracking = .insufficientFeatures
        limited.centerDistance = 4.0
        let limitedSet = engine.conditions(for: limited)
        c.check("guidance.limitedTrackingSuppressesTier2", limitedSet.contains(.trackingLow)
                && !limitedSet.contains(.moveCloser))
        var fast = GuidanceInput(time: 0)
        fast.angularSpeed = 2.0
        var calm = GuidanceInput(time: 0)
        calm.angularSpeed = 1.0
        calm.linearSpeed = 0.5
        c.check("guidance.moveSlower", engine.conditions(for: fast).contains(.moveSlower)
                && !engine.conditions(for: calm).contains(.moveSlower))
        var far = GuidanceInput(time: 0)
        far.centerDistance = 6.0
        c.check("guidance.tooFar", engine.conditions(for: far).contains(.tooFar))
        var dim = GuidanceInput(time: 0)
        dim.depthConfidenceMean = 0.1
        dim.centerDistance = 2.0
        var dimNear = dim
        dimNear.centerDistance = 1.0
        c.check("guidance.lowDepthConfidenceMoveCloser", engine.conditions(for: dim).contains(.moveCloser)
                && !engine.conditions(for: dimNear).contains(.moveCloser))

        let a = MissingArea(centroid: SIMD3<Float>(4, 1, 4.7), normal: SIMD3<Float>(-1, 0, 0), area: 0.2,
                            surface: .wall, suggestedViewpoint: SIMD3<Float>(2.5, 1.4, 4.7))
        let b = MissingArea(centroid: SIMD3<Float>(3.7, 1, 5), normal: SIMD3<Float>(0, 0, -1), area: 0.2,
                            surface: .wall, suggestedViewpoint: SIMD3<Float>(3.7, 1.4, 3.5))
        c.check("guidance.corner", GuidanceEngine.missingKind(for: a, among: [a, b]) == .scanCorner)
        c.check("guidance.singleWallHole", GuidanceEngine.missingKind(for: a, among: [a]) == .needsAnotherPass)

        var resettable = GuidanceEngine()
        for i in 0..<4 {
            var g = GuidanceInput(time: Double(i) * 0.25)
            g.tracking = .excessiveMotion
            _ = resettable.update(g)
        }
        let shown = resettable.current
        resettable.reset()
        c.check("guidance.reset", shown == .moveSlower && resettable.current == nil)
        checkGuidanceExtras(&c)
    }

    // MARK: - Guidance extras (CR-9)

    /// Caller conditions (`GuidanceInput.extraConditions`): tier 2 and 3 kinds obey the display
    /// rules like the engine's own, limited tracking suppresses them, tier 1 kinds are ignored.
    private static func checkGuidanceExtras(_ c: inout CoverageSelfTestChecker) {
        let engine = GuidanceEngine()
        let left = CSTG.GuidanceTrace(ticks: 8) { t in
            var g = GuidanceInput(time: t)
            g.extraConditions = [.objectCaptureLeft]
            return g
        }
        c.check("guidance.extra.shownAfterHold", left.message(at: 0.5) == nil
                && left.message(at: 0.75) == .objectCaptureLeft && left.hapticCount == 0,
                "got \(String(describing: left.message(at: 0.75)))")

        // Limited tracking: the extra waits. Once tracking recovers (1.0 s) it still waits for the
        // tier 1 message's minimum time (hidden at 3.75 s) and the 3 s gap, so it shows at 6.75 s.
        let recover = CSTG.GuidanceTrace(ticks: 32) { t in
            var g = GuidanceInput(time: t)
            if t < 1.0 { g.tracking = .excessiveMotion }
            g.extraConditions = [.objectCaptureLeft]
            return g
        }
        var limited = GuidanceInput(time: 0)
        limited.tracking = .excessiveMotion
        limited.extraConditions = [.objectCaptureLeft]
        let limitedSet = engine.conditions(for: limited)
        let early: [GuidanceKind?] = (0..<27).map { recover.message(at: Double($0) * CSTG.GuidanceTrace.step) }
        let leftEarly: Bool = early.contains { $0 == .objectCaptureLeft }
        let limitedHasLeft: Bool = limitedSet.contains(.objectCaptureLeft)
        let slowerFirst: Bool = recover.message(at: 0.75) == .moveSlower
        let leftLater: Bool = recover.message(at: 6.75) == .objectCaptureLeft
        c.check("guidance.extra.limitedTracking", !limitedHasLeft && slowerFirst && !leftEarly && leftLater,
                "got \(String(describing: recover.message(at: 6.75)))")

        // Tier 1 belongs to the engine: extra tier 1 kinds never become conditions or messages.
        let tier1Kinds: Set<GuidanceKind> = [.trackingLost, .moveSlower, .deviceHot]
        var tier1 = GuidanceInput(time: 0)
        tier1.extraConditions = tier1Kinds
        let ignored = CSTG.GuidanceTrace(ticks: 8) { t in
            var g = GuidanceInput(time: t)
            g.extraConditions = tier1Kinds
            return g
        }
        c.check("guidance.extra.tier1Ignored", engine.conditions(for: tier1).isEmpty && ignored.changeCount == 0,
                "changes \(ignored.changeCount)")

        // Priorities: the engine's "Move closer" precedes object kinds in the table; among
        // extras the table order wins (left before back).
        let withEngine = CSTG.GuidanceTrace(ticks: 4) { t in
            var g = GuidanceInput(time: t)
            g.centerDistance = 4.0
            g.extraConditions = [.objectCaptureLeft, .objectNeedsDetail]
            return g
        }
        let sides = CSTG.GuidanceTrace(ticks: 4) { t in
            var g = GuidanceInput(time: t)
            g.extraConditions = [.objectCaptureBack, .objectCaptureLeft]
            return g
        }
        c.check("guidance.extra.priority", withEngine.message(at: 0.75) == .moveCloser
                && sides.message(at: 0.75) == .objectCaptureLeft)

        // A tier 3 extra shows once per run of being true, like "Looks good" for rooms.
        let done = CSTG.GuidanceTrace(ticks: 121) { t in
            var g = GuidanceInput(time: t)
            g.extraConditions = [.objectLooksComplete]
            return g
        }
        c.check("guidance.extra.tier3OncePerRun", done.message(at: 0.75) == .objectLooksComplete
                && done.appearances(before: 30) == 1, "got \(done.appearances(before: 30))")
        let plain = GuidanceInput(time: 0)
        c.check("guidance.extra.defaultEmpty", plain.extraConditions.isEmpty && engine.conditions(for: plain).isEmpty)
    }

    // MARK: - Measurement confidence

    /// Monotonicity, the SPEC example and the low confidence rule.
    static func checkMeasurement(_ c: inout CoverageSelfTestChecker) {
        typealias M = MeasurementConfidence
        /// Endpoint evidence with good defaults (high confidence, 4 observations, clean tracking).
        func ev(_ d: Float, conf: Float? = 1, obs: Int = 4, track: Float = 1,
                snap: MeasurementSnapKind = .vertex) -> MeasurementEvidence {
            MeasurementEvidence(distance: d, depthConfidence: conf, observations: obs,
                                trackingNormalFraction: track, snap: snap)
        }
        /// True when `values` never decreases (increasing) or never increases (!increasing).
        func monotonic(_ values: [Float], increasing: Bool) -> Bool {
            for i in 1..<values.count {
                if increasing && values[i] < values[i - 1] - 1e-7 { return false }
                if !increasing && values[i] > values[i - 1] + 1e-7 { return false }
            }
            return true
        }
        let distances: [Float] = [0.2, 0.5, 1, 2, 3, 4, 4.5, 5, 6]
        let byDistance = distances.map { M.pointAccuracy(ev($0)) }
        c.check("measure.pointMonotonicDistance", monotonic(byDistance, increasing: true))
        c.check("measure.fartherWorse", M.pointAccuracy(ev(5)) > M.pointAccuracy(ev(1)))
        let lengthByDistance = distances.map { M.estimate(start: ev($0), end: ev($0), length: 3).accuracy }
        c.check("measure.lengthMonotonicDistance", monotonic(lengthByDistance, increasing: true))
        let byObservations = (0...12).map { M.pointAccuracy(ev(2, obs: $0)) }
        c.check("measure.monotonicObservations", monotonic(byObservations, increasing: false))
        c.check("measure.moreObservationsBetter", M.pointAccuracy(ev(2, obs: 9)) < M.pointAccuracy(ev(2, obs: 1)))
        let byConfidence = (0...10).map { M.pointAccuracy(ev(2, conf: Float($0) / 10)) }
        c.check("measure.monotonicConfidence", monotonic(byConfidence, increasing: false))
        let byTracking = (0...10).map { M.pointAccuracy(ev(2, track: Float($0) / 10)) }
        c.check("measure.monotonicTracking", monotonic(byTracking, increasing: false))
        c.check("measure.planeSnapBetter", M.pointAccuracy(ev(2, snap: .plane)) < M.pointAccuracy(ev(2, snap: .none)))

        let wall = ev(2, conf: 1, obs: 9, track: 1, snap: .roomSurface)
        let spec = M.estimate(start: wall, end: wall, length: 5.66)
        c.check("measure.specExample", spec.accuracy >= 0.0125 && spec.accuracy <= 0.014 && !spec.isLowConfidence,
                "got \(spec.accuracy)")
        c.check("measure.driftWithLength", M.estimate(start: ev(1), end: ev(1), length: 10).accuracy
                > M.estimate(start: ev(1), end: ev(1), length: 1).accuracy)
        c.check("measure.low.tracking", M.estimate(start: ev(1, track: 0.5), end: ev(1), length: 2).isLowConfidence)
        c.check("measure.low.noObservations", M.estimate(start: ev(1, obs: 0), end: ev(1), length: 2).isLowConfidence)
        c.check("measure.low.depthConfidence", M.estimate(start: ev(1, conf: 0.2), end: ev(1), length: 2).isLowConfidence)
        let farPoint = ev(5, conf: nil, obs: 1, snap: .none)
        let far = M.estimate(start: farPoint, end: farPoint, length: 1)
        c.check("measure.low.inaccurate", far.isLowConfidence && far.accuracy > 0.05, "got \(far.accuracy)")
        let point = M.estimate(point: ev(1))
        let nanAccuracy = M.pointAccuracy(ev(Float.nan))
        c.check("measure.point.goodAndFinite", !point.isLowConfidence && point.accuracy >= 0.004
                && nanAccuracy.isFinite && nanAccuracy > 0 && nanAccuracy <= 1)
    }
}
