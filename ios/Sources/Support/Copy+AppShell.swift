import Foundation

extension Copy {
    /// Text of the app shell (docs/MODULES.md 3.29): launch recovery, Settings extras and the
    /// Diagnostics screen. Settings reuses `Copy.Settings`; errors reuse `Copy.Errors`.
    enum AppShell {
        // MARK: Recovery (ARCHITECTURE 3.4)

        /// Title of the recovery sheet shown at launch for an unfinished scan.
        static let recoverTitle = "Recover unfinished scan?"
        /// Body of the recovery sheet.
        static let recoverBody = "Mapper closed before a scan was finished. You can keep what was scanned."
        /// Keeps the unfinished scan and builds its model.
        static let recoverKeep = "Keep Scan"
        /// Deletes the unfinished scan.
        static let recoverDiscard = "Discard"
        /// Line under the body naming when the scan started, for example "Started Sep 28, 2026 at 3:12 PM".
        static func recoverStarted(_ date: String) -> String { "Started \(date)" }

        // MARK: Settings extras

        /// Settings toggle: show the other unit system in parentheses.
        static let showBoth = "Show both units"
        /// Settings footer while the wireless debug log is on and Wi-Fi has an address.
        static let wirelessDebugAddress = "Open this address in a browser on a computer on the same Wi-Fi."
        /// Settings footer while the wireless debug log is on but there is no Wi-Fi address.
        static let wirelessDebugNoWiFi = "Connect to Wi-Fi to see the address."

        // MARK: Diagnostics

        /// Diagnostics screen title and its link in Settings.
        static let diagnosticsTitle = "Diagnostics"
        /// Diagnostics toggle: New Scan uses a sample room instead of the camera.
        static let demoMode = "Demo Mode"
        /// Footer of the Demo Mode toggle.
        static let demoModeFooter = "Try every screen with a sample room. The camera is not used."
        /// Diagnostics toggle: records every live scan update to a file for later replay.
        static let recordSnapshots = "Record Scan Snapshots"
        /// Diagnostics row that opens the texture orientation test pattern.
        static let uvCheck = "Texture Orientation Check"
        /// What the texture orientation test pattern should look like.
        static let uvCheckHint = "Cell 1 (red) belongs at the lower left and cell 64 (yellow) at the upper right. If cell 57 (blue) is at the lower left, the texture is upside down."
        /// Shown when the test pattern could not be made.
        static let uvCheckFailed = "The test pattern could not be made. Share the log from Settings."
        /// Section title of the self-test results.
        static let selfTests = "Self-Tests"
        /// Runs every self-test again.
        static let runSelfTests = "Run Again"
        /// Shown while the self-tests run.
        static let runningSelfTests = "Running self-tests..."
        /// One passed self-test, for example "Units self-test passed".
        static func selfTestPassed(_ name: String) -> String { "\(name) self-test passed" }
        /// One failed self-test, for example "Units self-test: 2 failed".
        static func selfTestFailed(_ name: String, count: Int) -> String { "\(name) self-test: \(count) failed" }
        /// A duration in seconds, for example "0.12 s".
        static func seconds(_ value: String) -> String { "\(value) s" }
        /// Diagnostics toggle for the ARKit delegate relay (CaptureCore).
        static let captureRelay = "Capture Delegate Relay"
        /// Footer of the capture relay toggle.
        static let captureRelayFooter = "Turn off only if the camera view goes black during a room scan."
        /// Section of the testing toggles (Demo Mode, snapshots, relay).
        static let testingSection = "Testing"
        /// Section of the capability rows.
        static let supportSection = "What This iPhone Supports"
        /// Section of the device facts.
        static let deviceSection = "This iPhone"
        /// Closes the texture orientation check.
        static let done = "Done"

        // MARK: Capability rows (the same names as the capability log line)

        /// ARKit scene reconstruction with classification.
        static let probeMesh = "LiDAR mesh (ARKit scene reconstruction)"
        /// ARKit scene depth.
        static let probeDepth = "Scene depth"
        /// RoomPlan room capture.
        static let probeRoomPlan = "RoomPlan"
        /// RealityKit Object Capture.
        static let probeObjectCapture = "Object Capture"
        /// RealityKit on-device photogrammetry.
        static let probePhotogrammetry = "On-device photogrammetry"
        /// VoiceOver value of a supported capability or a passed self-test.
        static let supported = "Yes"
        /// VoiceOver value of an unsupported capability or a failed self-test.
        static let notSupported = "No"

        // MARK: Device facts

        /// Memory the app may still use.
        static let availableMemory = "Available memory"
        /// Memory of the device.
        static let physicalMemory = "Physical memory"
        /// Hardware model code.
        static let deviceModel = "Model"
        /// iOS version.
        static let systemVersion = "iOS version"
        /// Battery, heat and Low Power Mode.
        static let power = "Battery and heat"
    }
}
