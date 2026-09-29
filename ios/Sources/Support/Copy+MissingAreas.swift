import Foundation

extension Copy {
    /// Text of the Show Missing Areas tour (docs/MODULES.md 3.40). The step line, the hint, the
    /// filled notice, Next Area and the all-done line reuse `Copy.Quality`; Done, Cancel and Keep
    /// Scanning reuse `Copy.Scanning`; the up and down hints reuse the guidance texts of
    /// `.scanCeiling` and `.pointAtFloor`.
    enum MissingAreas {
        /// Notice when the area in front of the user stays empty (glass or a mirror, D19).
        static let cantScan = "This spot can't be scanned. It may be glass or a mirror."
        /// Shown while the scan quality is evaluated again after Done.
        static let rechecking = "Checking your scan again..."
        /// Distance to the next place to stand; `distance` comes from `LengthFormat.display`.
        static func distanceAway(_ distance: String) -> String { "\(distance) away" }
        /// Cancel confirmation title.
        static let cancelTitle = "Stop filling in missing areas?"
        /// Cancel confirmation message.
        static let cancelBody = "What you scanned in this pass will be lost. Your room scan is kept."
        /// Destructive button of the cancel confirmation.
        static let cancelDiscardPass = "Discard This Pass"
        /// VoiceOver direction announcements and the arrow's label.
        static let a11yAhead = "Missing area ahead"
        static let a11yLeft = "Missing area to your left"
        static let a11yRight = "Missing area to your right"
        static let a11yBehind = "Missing area behind you"
        static let a11yUp = "Missing area above you"
        static let a11yDown = "Missing area below you"
    }
}
