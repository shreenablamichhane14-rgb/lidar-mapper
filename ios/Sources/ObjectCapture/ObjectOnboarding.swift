import Foundation

// The three-lap onboarding of an object scan (docs/MODULES.md 3.33; REUSE 2.1 step 8; RESEARCH
// 3.3 recommended 4): a first lap at chest height, then either a flip
// (`beginNewScanPassAfterFlip()`, a new box) or a lap from lower down (`beginNewScanPass()`, same
// box), then a third lap (flip again, or from higher up to capture the top). Pure and
// nonisolated: the model calls it on main and the self-test off main.

/// Where the user is in the three laps.
enum ObjectOnboardingState: Equatable, Sendable {
    case firstSegment                     // first lap at chest height
    case reviewFirst                      // lap 1 done: flip, or scan lower
    case flipObject                       // after beginNewScanPassAfterFlip: new box, second lap
    case captureFromLowerAngle            // second lap, lower
    case reviewSecond(flipped: Bool)      // lap 2 done
    case flipObjectAgain                  // third lap after a second flip
    case captureFromHigherAngle           // third lap, higher, capture the top
    case done                             // all laps done: only Done remains
}

/// What happened: the session finished a lap, or the user picked a review choice or Done.
enum ObjectOnboardingEvent: Equatable, Sendable { case passCompleted, chooseFlip, chooseNoFlip, finishTapped }

/// The session call a transition asks for.
enum ObjectPassCommand: Equatable, Sendable { case none, beginNewScanPass, beginNewScanPassAfterFlip, finish }

/// One button of the review sheet.
struct ObjectReviewChoice: Equatable, Sendable {
    /// Button text (Copy.ObjectCapture or Copy.Scanning).
    var title: String
    /// Event sent to `ObjectScanModel.choose(_:)`.
    var event: ObjectOnboardingEvent
    /// True for the one prominent button.
    var isPrimary: Bool
}

/// Transitions, pass numbers and texts of the three-lap onboarding.
enum ObjectOnboarding {
    /// Laps Apple recommends (WWDC23 10191).
    static let recommendedPasses = 3

    /// Pure transition plus the session call to make. passCompleted moves a lap state to its
    /// review (the third lap to `.done`); in a review, chooseFlip gives
    /// `.beginNewScanPassAfterFlip` and chooseNoFlip `.beginNewScanPass`; finishTapped gives
    /// `.finish` from any review or `.done`; every other pair is ignored (`.none`, same state).
    static func next(_ state: ObjectOnboardingState, _ event: ObjectOnboardingEvent) -> (state: ObjectOnboardingState, command: ObjectPassCommand) {
        switch (state, event) {
        case (.firstSegment, .passCompleted):
            return (state: .reviewFirst, command: .none)
        case (.flipObject, .passCompleted):
            return (state: .reviewSecond(flipped: true), command: .none)
        case (.captureFromLowerAngle, .passCompleted):
            return (state: .reviewSecond(flipped: false), command: .none)
        case (.flipObjectAgain, .passCompleted), (.captureFromHigherAngle, .passCompleted):
            return (state: .done, command: .none)
        case (.reviewFirst, .chooseFlip):
            return (state: .flipObject, command: .beginNewScanPassAfterFlip)
        case (.reviewFirst, .chooseNoFlip):
            return (state: .captureFromLowerAngle, command: .beginNewScanPass)
        case (.reviewSecond, .chooseFlip):
            return (state: .flipObjectAgain, command: .beginNewScanPassAfterFlip)
        case (.reviewSecond, .chooseNoFlip):
            return (state: .captureFromHigherAngle, command: .beginNewScanPass)
        case (.reviewFirst, .finishTapped), (.reviewSecond, .finishTapped), (.done, .finishTapped):
            return (state: state, command: .finish)
        default:
            return (state: state, command: .none)
        }
    }

    /// Pass number of a state, 1...3 (for the log and the review title).
    static func pass(of state: ObjectOnboardingState) -> Int {
        switch state {
        case .firstSegment, .reviewFirst: return 1
        case .flipObject, .captureFromLowerAngle, .reviewSecond: return 2
        case .flipObjectAgain, .captureFromHigherAngle, .done: return 3
        }
    }

    /// True for the states that show the review sheet (a finished lap or all laps done).
    static func isReview(_ state: ObjectOnboardingState) -> Bool {
        switch state {
        case .reviewFirst, .reviewSecond, .done: return true
        case .firstSegment, .flipObject, .captureFromLowerAngle, .flipObjectAgain, .captureFromHigherAngle: return false
        }
    }

    /// The instruction shown over the camera for a state while capturing (Copy.ObjectCapture);
    /// the ready and detecting stages show `aimHint` and `boxHint` instead.
    static func instruction(for state: ObjectOnboardingState) -> String {
        switch state {
        case .firstSegment: return Copy.ObjectCapture.orbitHint
        case .reviewFirst, .reviewSecond: return Copy.ObjectCapture.reviewTitle(pass(of: state))
        case .flipObject, .flipObjectAgain: return Copy.ObjectCapture.flippedHint
        case .captureFromLowerAngle: return Copy.ObjectCapture.lowerHint
        case .captureFromHigherAngle: return Copy.ObjectCapture.higherHint
        case .done: return GuidanceKind.objectLooksComplete.message.text
        }
    }

    /// False once `.objectNotFlippable` was seen during the scan (RESEARCH 3.3 gotcha 15); the
    /// review then leads with the no-flip choice and shows `Copy.ObjectCapture.flipWarning`.
    static func flipRecommended(sawNotFlippable: Bool) -> Bool {
        !sawNotFlippable
    }

    /// True when the scan has enough photos to build a model.
    static func canFinish(shots: Int) -> Bool {         // shots >= ObjectScanFolders.minimumImages
        shots >= ObjectScanFolders.minimumImages
    }

    // MARK: Review sheet texts

    /// Title of the review sheet for a review state, nil for a lap state.
    static func reviewTitle(for state: ObjectOnboardingState) -> String? {
        isReview(state) ? Copy.ObjectCapture.reviewTitle(pass(of: state)) : nil
    }

    /// Body of the review sheet for a review state, nil for a lap state.
    static func reviewBody(for state: ObjectOnboardingState) -> String? {
        switch state {
        case .reviewFirst: return Copy.ObjectCapture.reviewFirstBody
        case .reviewSecond(let flipped):
            return flipped ? Copy.ObjectCapture.reviewSecondFlippedBody : Copy.ObjectCapture.reviewSecondBody
        case .done: return GuidanceKind.objectLooksComplete.message.text
        case .firstSegment, .flipObject, .captureFromLowerAngle, .flipObjectAgain, .captureFromHigherAngle: return nil
        }
    }

    /// True when the review offers a flip and a flip is not recommended (the warning shows).
    static func showsFlipWarning(for state: ObjectOnboardingState, flipRecommended: Bool) -> Bool {
        guard !flipRecommended else { return false }
        switch state {
        case .reviewFirst, .reviewSecond: return true
        case .firstSegment, .flipObject, .captureFromLowerAngle, .flipObjectAgain, .captureFromHigherAngle, .done: return false
        }
    }

    /// Buttons of the review sheet, primary first; Done is always last. After the first lap the
    /// flip leads unless it is not recommended; after a second lap without a flip, Scan Higher
    /// leads; a flip that is not recommended reads "Flip Anyway".
    static func reviewChoices(for state: ObjectOnboardingState, flipRecommended: Bool) -> [ObjectReviewChoice] {
        let done = ObjectReviewChoice(title: Copy.Scanning.done, event: .finishTapped, isPrimary: false)
        switch state {
        case .reviewFirst:
            let lower = Copy.ObjectCapture.scanLower
            if flipRecommended {
                return [ObjectReviewChoice(title: Copy.ObjectCapture.flipObject, event: .chooseFlip, isPrimary: true),
                        ObjectReviewChoice(title: lower, event: .chooseNoFlip, isPrimary: false), done]
            }
            return [ObjectReviewChoice(title: lower, event: .chooseNoFlip, isPrimary: true),
                    ObjectReviewChoice(title: Copy.ObjectCapture.flipAnyway, event: .chooseFlip, isPrimary: false), done]
        case .reviewSecond(let flipped):
            let higher = Copy.ObjectCapture.scanHigher
            if flipped && flipRecommended {
                return [ObjectReviewChoice(title: Copy.ObjectCapture.flipAgain, event: .chooseFlip, isPrimary: true),
                        ObjectReviewChoice(title: higher, event: .chooseNoFlip, isPrimary: false), done]
            }
            let flipTitle: String
            if !flipRecommended {
                flipTitle = Copy.ObjectCapture.flipAnyway
            } else {
                flipTitle = Copy.ObjectCapture.flipObject
            }
            return [ObjectReviewChoice(title: higher, event: .chooseNoFlip, isPrimary: true),
                    ObjectReviewChoice(title: flipTitle, event: .chooseFlip, isPrimary: false), done]
        case .done:
            return [ObjectReviewChoice(title: Copy.Scanning.done, event: .finishTapped, isPrimary: true)]
        case .firstSegment, .flipObject, .captureFromLowerAngle, .flipObjectAgain, .captureFromHigherAngle:
            return []
        }
    }
}
