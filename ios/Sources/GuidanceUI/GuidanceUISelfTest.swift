import Foundation
import ARKit
import RoomPlan
import RealityKit

/// Plain-Swift checks for GuidanceUI (no XCTest), run from the Diagnostics suite list off the
/// main actor. Pure and deterministic: no ARKit, RoomPlan or Object Capture session, no camera,
/// no files, no clock, no haptics and no VoiceOver posts (the announcer's decisions are checked
/// through `GuidanceAnnouncerState`). 54 checks.
enum GuidanceUISelfTest {
    /// Failing checks as "name: detail"; empty when all pass.
    static func run() -> [String] {
        var failures: [String] = []
        trackingChecks(&failures)
        filterChecks(&failures)
        hapticChecks(&failures)
        feedbackChecks(&failures)
        instructionChecks(&failures)
        announcerChecks(&failures)
        copyChecks(&failures)
        return failures
    }

    /// Records a failure when `ok` is false.
    private static func check(_ failures: inout [String], _ name: String, _ ok: Bool, _ detail: String) {
        if !ok { failures.append("\(name): \(detail)") }
    }

    // MARK: Tracking

    /// Mappings for every `TrackingSummary` case and every `ARCamera.TrackingState` shape.
    private static func trackingChecks(_ failures: inout [String]) {
        let expected: [TrackingSummary: GuidanceTracking] = [
            .normal: .normal,
            .initializing: .initializing,
            .excessiveMotion: .excessiveMotion,
            .insufficientFeatures: .insufficientFeatures,
            .relocalizing: .relocalizing,
            .limited: .insufficientFeatures,
            .notAvailable: .initializing,
        ]
        for summary in TrackingSummary.allCases {
            let name = "tracking.summary.\(summary.rawValue)"
            guard let want = expected[summary] else {
                check(&failures, name, false, "no expectation for this case")
                continue
            }
            let got = GuidanceSignals.tracking(summary)
            check(&failures, name, got == want, "expected \(want), got \(got)")
        }

        let arCases: [(name: String, state: ARCamera.TrackingState, want: GuidanceTracking)] = [
            (name: "normal", state: .normal, want: .normal),
            (name: "notAvailable", state: .notAvailable, want: .initializing),
            (name: "limited.initializing", state: .limited(.initializing), want: .initializing),
            (name: "limited.relocalizing", state: .limited(.relocalizing), want: .relocalizing),
            (name: "limited.excessiveMotion", state: .limited(.excessiveMotion), want: .excessiveMotion),
            (name: "limited.insufficientFeatures", state: .limited(.insufficientFeatures), want: .insufficientFeatures),
        ]
        for item in arCases {
            let got = GuidanceSignals.tracking(item.state)
            check(&failures, "tracking.arkit.\(item.name)", got == item.want, "expected \(item.want), got \(got)")
        }
    }

    // MARK: Filter

    /// Coaching suppression: the three always-allowed kinds pass, everything else is dropped with
    /// its haptic; without coaching every kind passes untouched.
    private static func filterChecks(_ failures: inout [String]) {
        let coaching = GuidanceFilter(roomPlanCoaching: true)
        let allowed: [GuidanceKind] = [.deviceHot, .trackingLost, .trackingLow]
        for kind in allowed {
            let input = GuidanceOutput(message: kind, fireHaptic: true)
            let out = coaching.filter(input)
            check(&failures, "filter.coaching.passes.\(kind.rawValue)", out == input,
                  "got \(describe(out.message)) haptic \(out.fireHaptic)")
        }
        let dropped: [GuidanceKind] = [.moveSlower, .doorDetected, .scanCeiling]
        for kind in dropped {
            let out = coaching.filter(GuidanceOutput(message: kind, fireHaptic: true))
            check(&failures, "filter.coaching.drops.\(kind.rawValue)", out.message == nil && !out.fireHaptic,
                  "got \(describe(out.message)) haptic \(out.fireHaptic)")
        }

        let passing = Set(GuidanceKind.allCases.filter { coaching.allows($0) })
        check(&failures, "filter.coaching.onlyAlwaysAllowed", passing == GuidanceFilter.alwaysAllowed,
              "passing \(passing.map(\.rawValue).sorted())")

        let nothing = coaching.filter(GuidanceOutput(message: nil, fireHaptic: false))
        check(&failures, "filter.coaching.nilPassesThrough", nothing.message == nil && !nothing.fireHaptic,
              "got \(describe(nothing.message))")

        let passAll = GuidanceFilter()
        var blocked: [String] = []
        for kind in GuidanceKind.allCases {
            let input = GuidanceOutput(message: kind, fireHaptic: kind.message.tier == 1)
            if passAll.filter(input) != input { blocked.append(kind.rawValue) }
        }
        check(&failures, "filter.notCoaching.passesAll", blocked.isEmpty && !passAll.roomPlanCoaching,
              "blocked \(blocked)")

        let tiers = GuidanceFilter.alwaysAllowed.map { $0.message.tier }
        check(&failures, "filter.alwaysAllowed.tier1", tiers.count == 3 && tiers.allSatisfy { $0 == 1 },
              "tiers \(tiers)")
    }

    // MARK: Haptics

    /// `shouldFireHaptic`: tier 1 only, cooldown, setting, and odd clocks.
    private static func hapticChecks(_ failures: inout [String]) {
        let cooldown = GuidancePolicy.hapticCooldownSeconds
        /// Shorthand for the announcer's pure haptic decision.
        func fire(_ kind: GuidanceKind, _ now: Double, _ last: Double?, _ enabled: Bool) -> Bool {
            GuidanceAnnouncer.shouldFireHaptic(kind: kind, now: now, lastHaptic: last, enabled: enabled)
        }
        check(&failures, "haptic.tier2", !fire(.scanCeiling, 100, nil, true), "tier 2 fired")
        check(&failures, "haptic.tier3", !fire(.doorDetected, 100, nil, true), "tier 3 fired")
        check(&failures, "haptic.withinCooldown", !fire(.trackingLost, 100 + cooldown - 0.1, 100, true),
              "fired \(cooldown - 0.1) s after the last")
        check(&failures, "haptic.disabled", !fire(.trackingLost, 100, nil, false), "fired with the setting off")
        check(&failures, "haptic.firstTier1", fire(.trackingLost, 100, nil, true), "did not fire")
        check(&failures, "haptic.afterCooldown", fire(.deviceHot, 100 + cooldown, 100, true),
              "did not fire \(cooldown) s after the last")
        check(&failures, "haptic.clockBackwards", fire(.trackingLow, 10, 100, true), "did not fire after a new timeline")
        check(&failures, "haptic.nonFinite", !fire(.trackingLow, Double.nan, nil, true), "fired at NaN")
        check(&failures, "haptic.cooldownIsFive", cooldown == 5.0, "cooldown \(cooldown)")

        let tier1 = GuidanceKind.allCases.filter { $0.message.tier == 1 }
        let silent = tier1.filter { !fire($0, 0, nil, true) }
        check(&failures, "haptic.allTier1Fire", !tier1.isEmpty && silent.isEmpty, "silent \(silent.map(\.rawValue))")
    }

    // MARK: Object Capture feedback

    /// Feedback set mapping and priority.
    private static func feedbackChecks(_ failures: inout [String]) {
        typealias Feedback = ObjectCaptureSession.Feedback
        /// Shorthand for the feedback set mapping.
        func mapped(_ items: Set<Feedback>) -> GuidanceKind? { GuidanceSignals.guidance(for: items) }

        let fastAndFar: Set<Feedback> = [.movingTooFast, .objectTooFar]
        check(&failures, "feedback.priority", mapped(fastAndFar) == .moveSlower, "got \(describe(mapped(fastAndFar)))")
        check(&failures, "feedback.empty", mapped([]) == nil, "got \(describe(mapped([])))")

        let unmapped: Set<Feedback> = [.overCapturing, .objectNotDetected, .objectNotFlippable]
        check(&failures, "feedback.unmapped", mapped(unmapped) == nil, "got \(describe(mapped(unmapped)))")

        let dark: Set<Feedback> = [.environmentTooDark, .outOfFieldOfView]
        check(&failures, "feedback.darkBeatsView", mapped(dark) == .lightingPoor, "got \(describe(mapped(dark)))")

        let closeAndFar: Set<Feedback> = [.objectTooFar, .objectTooClose]
        check(&failures, "feedback.closeBeatsFar", mapped(closeAndFar) == .tooClose, "got \(describe(mapped(closeAndFar)))")

        let everything: Set<Feedback> = [.environmentLowLight, .environmentTooDark, .movingTooFast,
                                         .objectNotDetected, .objectNotFlippable, .objectTooClose,
                                         .objectTooFar, .outOfFieldOfView, .overCapturing]
        check(&failures, "feedback.all", mapped(everything) == .lightingPoor, "got \(describe(mapped(everything)))")

        let table: [(item: Feedback, want: GuidanceKind?)] = [
            (item: .movingTooFast, want: .moveSlower),
            (item: .objectTooClose, want: .tooClose),
            (item: .objectTooFar, want: .tooFar),
            (item: .environmentTooDark, want: .lightingPoor),
            (item: .environmentLowLight, want: .lightingPoor),
            (item: .outOfFieldOfView, want: .objectKeepInView),
            (item: .objectNotDetected, want: nil),
            (item: .objectNotFlippable, want: nil),
            (item: .overCapturing, want: nil),
        ]
        var wrong: [String] = []
        for row in table where GuidanceSignals.kind(forFeedback: row.item) != row.want {
            wrong.append("\(row.item)")
        }
        check(&failures, "feedback.table", wrong.isEmpty, "wrong for \(wrong)")
    }

    // MARK: RoomPlan instructions

    /// Log names and the coaching flag for all six instructions.
    private static func instructionChecks(_ failures: inout [String]) {
        let instructions: [RoomCaptureSession.Instruction] = [
            .normal, .moveCloseToWall, .moveAwayFromWall, .turnOnLight, .slowDown, .lowTexture,
        ]
        let names = instructions.map { GuidanceSignals.name(of: $0) }
        let distinct = Set(names).count == instructions.count
        let known = !names.contains(GuidanceSignals.unknownInstructionName)
        check(&failures, "instruction.namesDistinct", distinct && known, "names \(names)")

        let expected = ["normal", "moveCloseToWall", "moveAwayFromWall", "turnOnLight", "slowDown", "lowTexture"]
        check(&failures, "instruction.namesStable", names == expected, "names \(names)")

        let coachingFlags = instructions.map { GuidanceSignals.isCoaching($0) }
        let wantFlags = [false, true, true, true, true, true]
        check(&failures, "instruction.isCoaching", coachingFlags == wantFlags, "flags \(coachingFlags)")
    }

    // MARK: Announcer decisions

    /// The announcer's pure state: announce each newly shown kind once, tier 1 high priority,
    /// haptic only for new tier 1 kinds outside the cooldown and with the setting on.
    private static func announcerChecks(_ failures: inout [String]) {
        typealias Decision = GuidanceAnnouncerState.Decision
        var state = GuidanceAnnouncerState()
        let afterCooldown: Double = 2 + GuidancePolicy.hapticCooldownSeconds + 0.5

        let steps: [(name: String, kind: GuidanceKind?, now: Double, want: Decision)] = [
            (name: "idle", kind: nil, now: 0,
             want: .quiet),
            (name: "tier3Shown", kind: .doorDetected, now: 1,
             want: Decision(announce: .doorDetected, highPriority: false, fireHaptic: false)),
            (name: "sameKindQuiet", kind: .doorDetected, now: 1.25,
             want: .quiet),
            (name: "tier1Shown", kind: .trackingLow, now: 2,
             want: Decision(announce: .trackingLow, highPriority: true, fireHaptic: true)),
            (name: "tier1InCooldown", kind: .deviceHot, now: 3,
             want: Decision(announce: .deviceHot, highPriority: true, fireHaptic: false)),
            (name: "hidden", kind: nil, now: 4,
             want: .quiet),
            (name: "tier1AfterCooldown", kind: .trackingLow, now: afterCooldown,
             want: Decision(announce: .trackingLow, highPriority: true, fireHaptic: true)),
        ]
        for step in steps {
            let got = state.present(step.kind, now: step.now, hapticsEnabled: true)
            check(&failures, "announcer.\(step.name)", got == step.want, "got \(got)")
        }
        check(&failures, "announcer.lastHaptic", state.lastHaptic == afterCooldown,
              "lastHaptic \(String(describing: state.lastHaptic))")

        var muted = GuidanceAnnouncerState()
        let mutedDecision = muted.present(.trackingLost, now: 0, hapticsEnabled: false)
        let mutedWant = Decision(announce: .trackingLost, highPriority: true, fireHaptic: false)
        check(&failures, "announcer.settingOff", mutedDecision == mutedWant && muted.lastHaptic == nil,
              "got \(mutedDecision)")

        state.reset()
        check(&failures, "announcer.reset", state == GuidanceAnnouncerState(), "state \(state)")
    }

    // MARK: Copy

    /// The banner shows `kind.message.text`, so every kind needs its own Copy entry written as a
    /// guidance sentence (no final period, UX_COPY voice rules).
    private static func copyChecks(_ failures: inout [String]) {
        var bad: [String] = []
        for kind in GuidanceKind.allCases {
            guard let message = Copy.Guidance.all[kind] else {
                bad.append("\(kind.rawValue) missing")
                continue
            }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || text.hasSuffix(".") || text != message.text { bad.append(kind.rawValue) }
        }
        check(&failures, "copy.guidanceTexts", bad.isEmpty, "bad \(bad)")
    }

    // MARK: Helpers

    /// "nil" or the raw value, for failure details.
    private static func describe(_ kind: GuidanceKind?) -> String {
        kind?.rawValue ?? "nil"
    }
}
