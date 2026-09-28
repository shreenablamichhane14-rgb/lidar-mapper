import Foundation

extension Copy {
    /// Scan flow text that UX_COPY.md section 4 does not already have (docs/MODULES.md 3.24):
    /// the timer, the live counts, the time hint and limit, preflight warnings, the paused
    /// prompt and the small status lines of the scan screen.
    enum ScanUI {
        /// Elapsed scan time as "{m}:{ss}", for example "4:05". Negative parts count as 0.
        static func elapsed(minutes: Int, seconds: Int) -> String {
            let m = Swift.max(0, minutes)
            let s = Swift.max(0, seconds)
            let padded = s < 10 ? "0\(s)" : "\(s)"
            return "\(m):\(padded)"
        }

        /// Shown once after 4 minutes of scanning (tier 3 style hint).
        static let timeHint = "Almost done? Tap Done when the room looks complete"
        /// Time limit card after 5 minutes (no automatic stop).
        static let timeLimitTitle = "Time to finish this room"
        /// Body of the time limit card.
        static let timeLimitBody = "Long scans make your iPhone hot. Tap Done now. You can scan more later."

        /// Preflight warning: free space under 3 GB.
        static let storageWarningTitle = "Storage is getting low"
        /// Body of the storage warning; `size` is the free space, for example "2.1 GB".
        static func storageWarningBody(_ size: String) -> String {
            "About \(size) free. A room scan can use a few hundred MB."
        }
        /// Preflight warning: thermal state serious or worse.
        static let warmTitle = "Your iPhone is warm"
        /// Body of the warm warning.
        static let warmBody = "Scanning makes it warmer. Take a break if it gets hot."

        /// Small banner on the scan screen in Demo Mode.
        static let demoBanner = "Demo Mode: no camera is used"

        /// Live counts under the timer, for example "4 walls, 1 door, 2 windows".
        static func counts(walls: Int, doors: Int, windows: Int) -> String {
            let w = Swift.max(0, walls)
            let d = Swift.max(0, doors)
            let n = Swift.max(0, windows)
            let wallText = w == 1 ? "1 wall" : "\(w) walls"
            let doorText = d == 1 ? "1 door" : "\(d) doors"
            let windowText = n == 1 ? "1 window" : "\(n) windows"
            return "\(wallText), \(doorText), \(windowText)"
        }

        /// Alert title after 30 seconds paused (buttons Finish Now and Resume).
        static let pausedFinishPrompt = "Still paused. Finish with what you have?"
        /// Button in the paused chrome and alerts: finish the room with what was scanned.
        static let finishNow = "Finish Now"

        /// Shown while the preflight checks run.
        static let preparing = "Getting ready..."
        /// Shown while the scan is being saved after Done.
        static let saving = "Saving your scan..."
        /// Shown while a discarded scan is being removed.
        static let discarding = "Discarding scan..."
        /// Heading of the tips screen before the first scan of a mode.
        static let tipsTitle = "Tips for a good scan"
        /// VoiceOver label of the timer.
        static let elapsedLabel = "Scan time"
        /// VoiceOver label of the live counts.
        static let countsLabel = "Found so far"
    }
}
