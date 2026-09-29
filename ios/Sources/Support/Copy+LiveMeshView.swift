import Foundation

extension Copy {
    /// Text of the mesh-only scan screens (docs/MODULES.md 3.32): the saving line of LiveMeshScreen,
    /// the timer's VoiceOver label of LiveMeshTopBar, and the Diagnostics toggle for the scanner
    /// debug view (shown by AppShell).
    enum LiveMeshView {
        /// Shown while a mesh-only pass is being saved after Done.
        static let saving = "Saving your scan..."
        /// Diagnostics toggle: ARKit's scene-understanding wireframe over the live camera.
        static let debugViewToggle = "Show Scanner Debug View"
        /// Footer under the debug view toggle.
        static let debugViewFooter = "Draws the scanner's raw output over the camera. For troubleshooting only."
        /// VoiceOver label of the scan timer in the top bar.
        static let elapsedLabel = "Scan time"
    }
}
