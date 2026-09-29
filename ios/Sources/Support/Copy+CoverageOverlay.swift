import Foundation

extension Copy {
    /// Text of the live coverage overlay (docs/MODULES.md 3.38): the minimap's VoiceOver label and
    /// value, and the Show Colors / Hide Colors toggle of screens that host the colored overlay.
    /// The legend itself uses `Copy.Scanning.legend*` and `Copy.A11y.coverageLegend`.
    enum CoverageOverlay {
        /// VoiceOver label of the minimap.
        static let minimapLabel = "Map of your scan"
        /// VoiceOver value of the minimap: the rounded share of the scan that is covered.
        static func minimapValue(_ percent: Int) -> String { "\(percent) percent scanned" }
        /// Toggle that turns the colored overlay on.
        static let showColors = "Show Colors"
        /// Toggle that turns the colored overlay off.
        static let hideColors = "Hide Colors"
    }
}
