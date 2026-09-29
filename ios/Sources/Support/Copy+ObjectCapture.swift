import Foundation

extension Copy {
    /// Object Capture screen text (docs/MODULES.md 3.33): the controls Mapper draws over Apple's
    /// `ObjectCaptureView`, the lap review sheet, the shot counter and the capture-time alerts.
    /// Guidance banners come from `GuidanceKind`; Cancel, Done and the discard dialog reuse
    /// `Copy.Scanning`.
    enum ObjectCapture {
        /// Buttons of the ready and detecting stages.
        static let continueButton = "Continue", startCapture = "Start Capture", resetBox = "Reset Box"

        /// Instruction in the ready stage.
        static let aimHint = "Aim at your object, then tap Continue"
        /// Instruction after Continue found no object (`startDetecting()` returned false).
        static let notFoundHint = "Can't find your object. Step back so it fits on screen"
        /// Instruction in the detecting stage (the box is shown).
        static let boxHint = "Drag the box edges to fit your object"
        /// Instruction during the first lap.
        static let orbitHint = "Keep moving around your object"
        /// Instruction during a second lap without a flip.
        static let lowerHint = "Hold your iPhone lower and walk around again"
        /// Instruction during a third lap without a flip.
        static let higherHint = "Hold your iPhone higher and capture the top"
        /// Instruction during a lap after the object was flipped.
        static let flippedHint = "Walk around the object again"

        /// Title of the review sheet after a lap.
        static func reviewTitle(_ laps: Int) -> String { "\(laps) of 3 laps done" }
        /// Review body after the first lap.
        static let reviewFirstBody = "Turn the object on its side to capture the bottom, or walk around again from lower down."
        /// Review body after a second lap that followed a flip.
        static let reviewSecondFlippedBody = "Turn the object onto another side for the last lap, or finish now."
        /// Review body after a second lap without a flip.
        static let reviewSecondBody = "Walk around once more from higher up, or finish now."

        /// Review choices.
        static let flipObject = "Flip Object", flipAgain = "Flip Again", scanLower = "Scan Lower"
        static let scanHigher = "Scan Higher", flipAnyway = "Flip Anyway"
        /// Shown in the review when Object Capture reported the object may not line up after a flip.
        static let flipWarning = "This object may not line up after flipping. Walking around it again works better."

        /// Shot counter over the camera.
        static func shotCount(taken: Int, limit: Int) -> String { "\(taken) of \(limit) photos" }

        /// Done tapped with fewer than 10 photos.
        static let tooFewPhotos = (title: "Keep going",
                                   body: "Walk around the object a bit more. Mapper needs at least 10 photos to build a model.")
        /// Shown while the session finishes and the photos are saved.
        static let saving = "Saving your photos..."
        /// The session failed (camera, sensor or tracking) with photos on disk.
        static let failed = (title: "Object scan stopped",
                             body: "Something went wrong with the camera. You can build a model from the photos taken so far.")
        /// Builds the model from the photos taken before a failure.
        static let usePhotos = "Use These Photos"

        /// VoiceOver label of Apple's capture view.
        static let a11yCaptureView = "Object scan view"
        /// VoiceOver label of the shot counter.
        static func a11yShotCount(taken: Int, limit: Int) -> String { "\(taken) of \(limit) photos taken" }
    }
}
