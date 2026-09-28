import Foundation

/// Scan quality sheet text that `Copy.Quality` in Copy.swift does not already hold (QualityUI,
/// docs/MODULES.md 3.25, docs/UX_COPY.md section 6). The Discard button reads
/// `Copy.Scanning.cancelConfirmDiscard`; its confirmation belongs to AppShell (MODULES 3.29).
extension Copy.Quality {
    /// Shown while the quick quality check at Done is still running.
    static let checking = "Checking your scan..."
    /// Shown under `checking` when the check takes much longer than usual, next to Finish
    /// Anyway and Discard, so the user is never stuck on the sheet.
    static let checkingSlow = "This is taking longer than usual. You can finish now."

    /// Degraded mode `depthStripped` (D16).
    static let noteDepthStripped = "Some depth data was missing, so these numbers are rough."
    /// Degraded mode `meshStripped` (D16).
    static let noteMeshStripped = "The detailed 3D scan didn't record. Walls and the floor plan are fine."
    /// Degraded mode `roomPlanFailed` (D16).
    static let noteRoomPlanFailed = "Walls couldn't be found, so there is no floor plan for this scan."
    /// More than 30 percent of the photos were taken in the dark.
    static let noteDark = "It was dark, so the color in your model may look poor."
}
