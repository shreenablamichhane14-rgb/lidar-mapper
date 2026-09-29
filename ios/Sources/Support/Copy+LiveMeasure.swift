import Foundation

extension Copy {
    /// Quick Measure screen (LiveMeasure, docs/MODULES.md 3.36). The measuring words themselves
    /// (Add Point, Undo, Clear All, Save, hints, snap targets, accuracy) are in `Copy.Measure`.
    enum LiveMeasure {
        /// Hint while the reticle finds no surface under it.
        static let noSurface = "Point at a surface"
        /// Hint before any surface was found.
        static let findingSurfaces = "Move your iPhone slowly to find surfaces"
        /// Title of the measurement list.
        static let listTitle = "Measurements"
        /// Name of the n-th distance, counted from 1.
        static func itemTitle(_ n: Int) -> String { "Distance \(n)" }
        /// Close with unsaved measurements.
        static let discardTitle = "Discard these measurements?"
        static let discardBody = "They haven't been saved yet."
        static let discardConfirm = "Discard"
        /// Shown while the project is created.
        static let saving = "Saving..."
        /// Alert after tracking relocalized while points were on screen.
        static let relocalized = "Tracking was lost for a moment. Check your points, or clear them and measure again."
        /// VoiceOver value of the reticle while a point is pending.
        static func a11yLive(_ value: String) -> String { "Current distance, \(value)" }
    }
}
