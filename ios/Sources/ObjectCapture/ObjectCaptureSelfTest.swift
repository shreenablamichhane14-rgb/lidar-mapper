import Foundation
import RealityKit
// SwiftUI brings in the RealityKit cross-import overlay that declares `ObjectCaptureSession`
// and its nested enums (rule 0.2.13).
import SwiftUI

/// Plain-Swift checks for ObjectCapture (no XCTest), run from the Diagnostics suite list off the
/// main actor. No Object Capture or photogrammetry session is created (only Apple enum values
/// are built), no camera, no network; files only under `FileManager.default.temporaryDirectory`
/// (ObjectCaptureSelfTest+Files.swift), removed afterwards. Fixed ids and dates. About 0.6 s,
/// most of it the `waitForNoReconstruction(timeout: 0.5)` check.
enum ObjectCaptureSelfTest {
    /// Failing checks as "name: detail"; empty when all pass.
    static func run() -> [String] {
        var failures: [String] = []
        stageChecks(&failures)
        failureChecks(&failures)
        feedbackChecks(&failures)
        onboardingChecks(&failures)
        reviewChecks(&failures)
        preflightChecks(&failures)
        photogrammetryChecks(&failures)
        reduceChecks(&failures)
        diagnosticsChecks(&failures)
        activityChecks(&failures)
        fileChecks(&failures)
        return failures
    }

    /// Records a failure when `ok` is false.
    static func check(_ failures: inout [String], _ name: String, _ ok: Bool, _ detail: @autoclosure () -> String) {
        if !ok { failures.append("\(name): \(detail())") }
    }

    // MARK: Signals

    /// `stage` for the six plain states and a `.failed`.
    private static func stageChecks(_ failures: inout [String]) {
        let table: [(state: ObjectCaptureSession.CaptureState, want: ObjectCaptureStage)] = [
            (state: .initializing, want: .initializing), (state: .ready, want: .ready),
            (state: .detecting, want: .detecting), (state: .capturing, want: .capturing),
            (state: .finishing, want: .finishing), (state: .completed, want: .completed),
        ]
        for row in table {
            let got = ObjectCaptureSignals.stage(row.state)
            check(&failures, "stage.\(row.want.rawValue)", got == row.want, "got \(got.rawValue)")
        }
        let failed = ObjectCaptureSignals.stage(.failed(ObjectCaptureSession.Error.cancelled))
        check(&failures, "stage.failed", failed == .failed, "got \(failed.rawValue)")
    }

    /// `failure` for the five `ObjectCaptureSession.Error` cases and an unrelated `NSError`.
    private static func failureChecks(_ failures: inout [String]) {
        typealias CaptureError = ObjectCaptureSession.Error
        let folder = URL(fileURLWithPath: "/nonexistent/Images", isDirectory: true)
        let table: [(error: CaptureError, want: ObjectScanFailure)] = [
            (error: .cancelled, want: .cancelled),
            (error: .directoryNotEmpty(folder), want: .directoryNotEmpty),
            (error: .insufficientStorage(requiredBytes: 123_456), want: .insufficientStorage(requiredBytes: 123_456)),
            (error: .sensorFailed, want: .sensorFailed),
            (error: .trackingFailed, want: .trackingFailed),
        ]
        for (index, row) in table.enumerated() {
            let got = ObjectCaptureSignals.failure(row.error)
            check(&failures, "failure.case\(index)", got == row.want, "got \(got)")
        }
        let other = ObjectCaptureSignals.failure(NSError(domain: "mapper.selftest", code: 7))
        var isOther = false
        if case .other = other { isOther = true }
        check(&failures, "failure.nsError", isOther, "got \(other)")

        let enough = ObjectCaptureSignals.failureCopy(.sensorFailed, imageCount: ObjectScanFolders.minimumImages)
        let few = ObjectCaptureSignals.failureCopy(.sensorFailed, imageCount: ObjectScanFolders.minimumImages - 1)
        check(&failures, "failureCopy.usePhotos", enough.canUsePhotos && !few.canUsePhotos,
              "enough \(enough.canUsePhotos), few \(few.canUsePhotos)")
        let storage = ObjectCaptureSignals.failureCopy(.insufficientStorage(requiredBytes: 2_000_000_000), imageCount: 0)
        check(&failures, "failureCopy.storage", storage.title == Copy.Errors.storageFullTitle && !storage.body.isEmpty,
              "title \(storage.title)")
        let seal = ObjectCaptureSignals.failureCopy(.other(ObjectCaptureSignals.sealFailurePrefix + "x"), imageCount: 12)
        check(&failures, "failureCopy.seal", seal.title == Copy.Errors.saveFailed.title && seal.canUsePhotos,
              "title \(seal.title)")

        let starts: [(issue: ObjectPreflightIssue, want: MapperError?)] = [
            (issue: .unsupported, want: .unsupportedDevice), (issue: .lowStorage(free: 5), want: .lowStorage(freeBytes: 5)),
            (issue: .deviceHot, want: .deviceTooHot), (issue: .deviceWarm, want: nil),
        ]
        let wrong = starts.filter { ObjectCaptureSignals.startError(for: $0.issue) != $0.want }
        check(&failures, "startError", wrong.isEmpty, "wrong for \(wrong.map { "\($0.issue)" })")
    }

    /// Feedback names, guidance mapping, flip and over-capture sets, tracking.
    private static func feedbackChecks(_ failures: inout [String]) {
        typealias Feedback = ObjectCaptureSession.Feedback
        let all: [Feedback] = [.environmentLowLight, .environmentTooDark, .movingTooFast, .objectNotDetected,
                               .objectNotFlippable, .objectTooClose, .objectTooFar, .outOfFieldOfView, .overCapturing]
        let names = all.map { ObjectCaptureSignals.name(of: $0) }
        let distinct = Set(names).count == all.count && !names.contains(ObjectCaptureSignals.unknownFeedbackName)
        check(&failures, "feedback.names", distinct, "\(names)")

        let fastFar: Set<Feedback> = [.movingTooFast, .objectTooFar]
        let mapped = GuidanceSignals.guidance(for: fastFar)
        check(&failures, "feedback.moveSlower", mapped == .moveSlower, "got \(String(describing: mapped))")
        let over: Set<Feedback> = [.overCapturing]
        let overMapped = GuidanceSignals.guidance(for: over)
        check(&failures, "feedback.overCapturingNoBanner", overMapped == nil, "got \(String(describing: overMapped))")

        let flip: Set<Feedback> = [.objectNotFlippable, .movingTooFast]
        check(&failures, "feedback.notFlippable",
              ObjectCaptureSignals.containsNotFlippable(flip) && !ObjectCaptureSignals.containsNotFlippable(fastFar),
              "contains check wrong")
        check(&failures, "feedback.overCapturing",
              ObjectCaptureSignals.containsOverCapturing(over) && !ObjectCaptureSignals.containsOverCapturing(flip),
              "contains check wrong")

        let normal = ObjectCaptureSignals.isNormal(.normal)
        let unavailable = ObjectCaptureSignals.isNormal(.notAvailable)
        let limited = ObjectCaptureSignals.isNormal(.limited(reason: .excessiveMotion))
        check(&failures, "tracking.isNormal", normal && !unavailable && !limited,
              "normal \(normal), notAvailable \(unavailable), limited \(limited)")
    }

    // MARK: Onboarding

    /// The flip path, the no-flip path, finish, ignored events, pass numbers, flip advice,
    /// the photo minimum and the instructions.
    private static func onboardingChecks(_ failures: inout [String]) {
        typealias Step = (event: ObjectOnboardingEvent, state: ObjectOnboardingState, command: ObjectPassCommand)
        let flipPath: [Step] = [
            (event: .passCompleted, state: .reviewFirst, command: .none),
            (event: .chooseFlip, state: .flipObject, command: .beginNewScanPassAfterFlip),
            (event: .passCompleted, state: .reviewSecond(flipped: true), command: .none),
            (event: .chooseFlip, state: .flipObjectAgain, command: .beginNewScanPassAfterFlip),
            (event: .passCompleted, state: .done, command: .none),
        ]
        walk(&failures, "onboarding.flip", flipPath)
        let noFlipPath: [Step] = [
            (event: .passCompleted, state: .reviewFirst, command: .none),
            (event: .chooseNoFlip, state: .captureFromLowerAngle, command: .beginNewScanPass),
            (event: .passCompleted, state: .reviewSecond(flipped: false), command: .none),
            (event: .chooseNoFlip, state: .captureFromHigherAngle, command: .beginNewScanPass),
            (event: .passCompleted, state: .done, command: .none),
        ]
        walk(&failures, "onboarding.noFlip", noFlipPath)

        let finish = ObjectOnboarding.next(.reviewFirst, .finishTapped)
        check(&failures, "onboarding.finishInReview", finish.state == .reviewFirst && finish.command == .finish,
              "got \(finish.state) \(finish.command)")
        let finishDone = ObjectOnboarding.next(.done, .finishTapped)
        check(&failures, "onboarding.finishWhenDone", finishDone.command == .finish, "got \(finishDone.command)")
        let ignored = ObjectOnboarding.next(.done, .passCompleted)
        check(&failures, "onboarding.doneIgnoresPass", ignored.state == .done && ignored.command == ObjectPassCommand.none,
              "got \(ignored.state) \(ignored.command)")
        let lapFlip = ObjectOnboarding.next(.firstSegment, .chooseFlip)
        check(&failures, "onboarding.lapIgnoresChoice", lapFlip.state == .firstSegment && lapFlip.command == ObjectPassCommand.none,
              "got \(lapFlip.state) \(lapFlip.command)")

        let passes = [ObjectOnboarding.pass(of: .firstSegment), ObjectOnboarding.pass(of: .captureFromLowerAngle),
                      ObjectOnboarding.pass(of: .captureFromHigherAngle), ObjectOnboarding.pass(of: .reviewSecond(flipped: true))]
        check(&failures, "onboarding.pass", passes == [1, 2, 3, 2], "got \(passes)")
        check(&failures, "onboarding.flipRecommended",
              !ObjectOnboarding.flipRecommended(sawNotFlippable: true) && ObjectOnboarding.flipRecommended(sawNotFlippable: false),
              "wrong advice")
        check(&failures, "onboarding.canFinish",
              !ObjectOnboarding.canFinish(shots: 9) && ObjectOnboarding.canFinish(shots: 10), "threshold wrong")

        let states = allStates
        let empty = states.filter { ObjectOnboarding.instruction(for: $0).isEmpty }
        check(&failures, "onboarding.instructions", empty.isEmpty, "empty for \(empty)")
        check(&failures, "onboarding.doneInstruction",
              ObjectOnboarding.instruction(for: .done) == GuidanceKind.objectLooksComplete.message.text, "wrong text")
        let ready = ObjectOnboarding.overlayInstruction(stage: .ready, onboarding: .firstSegment, detectionFailed: false)
        let notFound = ObjectOnboarding.overlayInstruction(stage: .ready, onboarding: .firstSegment, detectionFailed: true)
        let finishing = ObjectOnboarding.overlayInstruction(stage: .finishing, onboarding: .done, detectionFailed: false)
        let readyOK = ready == Copy.ObjectCapture.aimHint
        let notFoundOK = notFound == Copy.ObjectCapture.notFoundHint
        check(&failures, "onboarding.overlay", readyOK && notFoundOK && finishing == nil,
              "ready \(String(describing: ready)), notFound \(String(describing: notFound))")
    }

    /// Every onboarding state, in lap order.
    static let allStates: [ObjectOnboardingState] = [
        .firstSegment, .reviewFirst, .flipObject, .captureFromLowerAngle, .reviewSecond(flipped: true),
        .reviewSecond(flipped: false), .flipObjectAgain, .captureFromHigherAngle, .done,
    ]

    /// Walks `steps` from `.firstSegment`, one check per step.
    private static func walk(_ failures: inout [String], _ name: String,
                             _ steps: [(event: ObjectOnboardingEvent, state: ObjectOnboardingState, command: ObjectPassCommand)]) {
        var state = ObjectOnboardingState.firstSegment
        for (index, step) in steps.enumerated() {
            let next = ObjectOnboarding.next(state, step.event)
            check(&failures, "\(name).\(index)", next.state == step.state && next.command == step.command,
                  "\(state) + \(step.event) gave \(next.state) \(next.command)")
            state = next.state
        }
    }

    /// Review sheet contents per state.
    private static func reviewChecks(_ failures: inout [String]) {
        let lapStates = allStates.filter { !ObjectOnboarding.isReview($0) }
        let reviewStates = allStates.filter { ObjectOnboarding.isReview($0) }
        check(&failures, "review.states", lapStates.count == 5 && reviewStates.count == 4, "laps \(lapStates.count)")
        let missing = reviewStates.filter {
            ObjectOnboarding.reviewTitle(for: $0) == nil || ObjectOnboarding.reviewBody(for: $0) == nil
        }
        check(&failures, "review.texts", missing.isEmpty, "missing for \(missing)")
        let noChoices = lapStates.allSatisfy { ObjectOnboarding.reviewChoices(for: $0, flipRecommended: true).isEmpty }
        check(&failures, "review.lapHasNoChoices", noChoices, "lap state has choices")

        let first = ObjectOnboarding.reviewChoices(for: .reviewFirst, flipRecommended: true)
        let firstNoFlip = ObjectOnboarding.reviewChoices(for: .reviewFirst, flipRecommended: false)
        let firstEvent: ObjectOnboardingEvent? = first.first?.event
        let firstPrimary: Bool = first.first?.isPrimary ?? false
        check(&failures, "review.firstLeadsWithFlip", firstEvent == .chooseFlip && firstPrimary,
              "got \(first.map(\.title))")
        let leadsWithLower = firstNoFlip.first?.event == .chooseNoFlip
        let offersFlipAnyway = firstNoFlip.contains(where: { $0.title == Copy.ObjectCapture.flipAnyway })
        check(&failures, "review.notFlippableLeadsWithLower", leadsWithLower && offersFlipAnyway,
              "got \(firstNoFlip.map(\.title))")
        let done = ObjectOnboarding.reviewChoices(for: .done, flipRecommended: true)
        check(&failures, "review.doneOnlyFinishes", done.count == 1 && done.first?.event == .finishTapped,
              "got \(done.map(\.title))")
        let every = reviewStates.filter { $0 != .done }.allSatisfy {
            ObjectOnboarding.reviewChoices(for: $0, flipRecommended: true).last?.event == .finishTapped
        }
        check(&failures, "review.doneLast", every, "Done is not the last choice")
        let warnsNotFlippable = ObjectOnboarding.showsFlipWarning(for: .reviewFirst, flipRecommended: false)
        let quietWhenFlippable = !ObjectOnboarding.showsFlipWarning(for: .reviewFirst, flipRecommended: true)
        let quietWhenDone = !ObjectOnboarding.showsFlipWarning(for: .done, flipRecommended: false)
        check(&failures, "review.flipWarning", warnsNotFlippable && quietWhenFlippable && quietWhenDone,
              "warning rule wrong")
    }

    // MARK: Preflight

    /// Blocks unsupported, 2.9 GB free and critical heat; warns at serious heat; passes at 3.1 GB.
    private static func preflightChecks(_ failures: inout [String]) {
        let plenty: Int64 = 3_100_000_000
        let unsupported = ObjectCapturePreflight.evaluate(captureSupported: false, photogrammetrySupported: true,
                                                          freeBytes: plenty, thermal: .nominal)
        let noPhotogrammetry = ObjectCapturePreflight.evaluate(captureSupported: true, photogrammetrySupported: false,
                                                               freeBytes: plenty, thermal: .nominal)
        let captureBlocked: Bool = unsupported.blocking == ObjectPreflightIssue.unsupported
        let photogrammetryBlocked: Bool = noPhotogrammetry.blocking == ObjectPreflightIssue.unsupported
        check(&failures, "preflight.unsupported", captureBlocked && photogrammetryBlocked,
              "got \(String(describing: unsupported.blocking)), \(String(describing: noPhotogrammetry.blocking))")
        let low = ObjectCapturePreflight.evaluate(captureSupported: true, photogrammetrySupported: true,
                                                  freeBytes: 2_900_000_000, thermal: .nominal)
        check(&failures, "preflight.lowStorage", low.blocking == .lowStorage(free: 2_900_000_000),
              "got \(String(describing: low.blocking))")
        let hot = ObjectCapturePreflight.evaluate(captureSupported: true, photogrammetrySupported: true,
                                                  freeBytes: plenty, thermal: .critical)
        check(&failures, "preflight.critical", hot.blocking == .deviceHot, "got \(String(describing: hot.blocking))")
        let warm = ObjectCapturePreflight.evaluate(captureSupported: true, photogrammetrySupported: true,
                                                   freeBytes: plenty, thermal: .serious)
        let warmWarnings: [ObjectPreflightIssue] = [.deviceWarm]
        let warmOK: Bool = warm.blocking == nil && warm.warnings == warmWarnings
        check(&failures, "preflight.serious", warmOK,
              "got \(String(describing: warm.blocking)) \(warm.warnings)")
        let fine = ObjectCapturePreflight.evaluate(captureSupported: true, photogrammetrySupported: true,
                                                   freeBytes: plenty, thermal: .fair)
        check(&failures, "preflight.passes", fine.blocking == nil && fine.warnings.isEmpty,
              "got \(String(describing: fine.blocking)) \(fine.warnings)")
    }
}
