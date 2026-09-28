import Foundation

// Plain-Swift checks of the ScanUI module (no XCTest), run from Settings > Diagnostics like
// UnitsSelfTest: the preflight decision, the phase reducer, the time rules, the alert mapping,
// strings and settings, and the Demo Mode room written into a temporary package (checks in
// ScanUISelfTest+Demo.swift). Deterministic (fixed ids and dates), no ARKit, camera or network;
// files only under FileManager.default.temporaryDirectory, removed afterwards. The demo room is
// one small mesh consolidation and one quality evaluation (a few hundred ms on an A15).
//
// CHECK COUNT (60 when every group runs to the end):
//   preflight decision          14
//   phase reducer               13
//   time rules                   6
//   alerts and copy             10
//   settings, tips, names        6
//   demo room and recorders     11

/// ScanUI module self-test. `run()` returns one line per failing check; empty means all passed.
enum ScanUISelfTest {
    /// Failing checks as "name: detail".
    static func run() -> [String] {
        var c = ScanUISelfTestChecker()
        checkPreflight(&c)
        checkReducer(&c)
        checkTimeRules(&c)
        checkAlertsAndCopy(&c)
        checkSettingsAndNames(&c)
        checkDemoRoom(&c)
        if c.failures.isEmpty && c.count < 50 {
            c.failures.append("selfTest: only \(c.count) checks ran")
        }
        return c.failures
    }

    /// Fixed date of the checks: 2026-09-28 12:00 UTC.
    static let fixedDate = Date(timeIntervalSince1970: 1_790_596_800)

    /// A fixed identifier built from `n` (no randomness).
    static func fixedID(_ n: Int) -> UUID {
        let lo = UInt8(truncatingIfNeeded: n)
        let hi = UInt8(truncatingIfNeeded: n >> 8)
        return UUID(uuid: (0x53, 0x43, 0x41, 0x4E, 0x55, 0x49, 0x00, 0x00, 0x80, 0, 0, 0, 0, 0, hi, lo))
    }

    // MARK: - Preflight

    /// `ScanPreflight.evaluate`: blocking issues, their order, warnings and Demo Mode.
    private static func checkPreflight(_ c: inout ScanUISelfTestChecker) {
        func report(_ camera: CameraPermission = .authorized, lidar: Bool = true, free: Int64 = 20_000_000_000,
                 battery: Float? = 0.8, thermal: ThermalLevel = .nominal, demo: Bool = false) -> PreflightReport {
            ScanPreflight.evaluate(cameraStatus: camera, lidarSupported: lidar, freeBytes: free, batteryLevel: battery,
                                   thermal: thermal, isDemo: demo)
        }
        let denied = report(.denied)
        c.check("preflight.cameraDenied", denied.blocking == .cameraDenied, "\(String(describing: denied.blocking))")
        let noLidar = report(lidar: false)
        c.check("preflight.noLidar", noLidar.blocking == .noLidar, "\(String(describing: noLidar.blocking))")
        let oneGB = report(free: 1_000_000_000)
        c.check("preflight.oneGBBlocks", oneGB.blocking == .lowStorage(free: 1_000_000_000),
                "\(String(describing: oneGB.blocking))")
        let undetermined = report(.undetermined)
        c.check("preflight.undetermined", undetermined.blocking == .cameraUndetermined,
                "\(String(describing: undetermined.blocking))")
        let storageFirst = report(.denied, free: 1_000_000_000)
        c.check("preflight.storageBeforeCamera", storageFirst.blocking == .lowStorage(free: 1_000_000_000))
        let lidarFirst = report(.undetermined, lidar: false, free: 1_000_000_000)
        c.check("preflight.lidarFirst", lidarFirst.blocking == .noLidar)

        let warned = report(free: 2_000_000_000, battery: 0.15, thermal: .serious)
        c.check("preflight.warningsDoNotBlock", warned.blocking == nil, "\(String(describing: warned.blocking))")
        c.check("preflight.storageWarning", warned.warnings.contains(.storageWarning(free: 2_000_000_000)),
                "\(warned.warnings)")
        c.check("preflight.batteryWarning", warned.warnings.contains(.lowBattery(0.15)), "\(warned.warnings)")
        c.check("preflight.heatWarning", warned.warnings.contains(.deviceHot), "\(warned.warnings)")
        let clean = report()
        c.check("preflight.clean", clean == PreflightReport(blocking: nil, warnings: []), "\(clean)")
        let charging = report(battery: nil)
        c.check("preflight.chargingNoBatteryWarning", charging.warnings.isEmpty, "\(charging.warnings)")

        let demo = report(.denied, lidar: false, free: 2_000_000_000, demo: true)
        c.check("preflight.demoIgnoresCameraLidar", demo.blocking == nil && demo.warnings.isEmpty,
                "\(demo)")
        let demoFull = report(.denied, lidar: false, free: 30_000_000, demo: true)
        c.check("preflight.demo30MBBlocks", demoFull.blocking == .lowStorage(free: 30_000_000),
                "\(String(describing: demoFull.blocking))")
    }

    // MARK: - Reducer

    /// `ScanFlowModel.nextPhase`: the main path, the permission path, both cancel paths,
    /// discard, engine-initiated finishes, failures and terminal phases.
    private static func checkReducer(_ c: inout ScanUISelfTestChecker) {
        let project = fixedID(1)
        let room = fixedID(2)
        let path: [ScanFlowSignal] = [.preflightPassed, .tipsDone, .doneTapped, .roomFinished(room), .evaluated,
                                      .finishTapped, .completed(project)]
        var phase = ScanFlowPhase.preflight
        var visited: [ScanFlowPhase] = []
        for signal in path {
            phase = ScanFlowModel.nextPhase(phase, on: signal)
            visited.append(phase)
        }
        let expected: [ScanFlowPhase] = [.tips, .capturing, .stopping, .checking, .quality, .finishing, .done(project)]
        c.check("reducer.mainPath", visited == expected, "\(visited)")

        let asked = ScanFlowModel.nextPhase(.preflight, on: .permissionNeeded)
        let granted = ScanFlowModel.nextPhase(asked, on: .permissionGranted)
        c.check("reducer.permissionPath", asked == .permission && granted == .tips, "\(asked) \(granted)")
        c.check("reducer.permissionDenied", ScanFlowModel.nextPhase(.permission, on: .permissionDenied) == .cancelled)
        c.check("reducer.preflightBlocked", ScanFlowModel.nextPhase(.preflight, on: .preflightBlocked) == .cancelled)
        c.check("reducer.cancelWhileCapturing", ScanFlowModel.nextPhase(.capturing, on: .cancelConfirmed) == .cancelled)
        c.check("reducer.cancelWhileStopping", ScanFlowModel.nextPhase(.stopping, on: .cancelConfirmed) == .cancelled)
        c.check("reducer.discardOnSheet", ScanFlowModel.nextPhase(.quality, on: .discarded) == .cancelled)
        c.check("reducer.engineStopping", ScanFlowModel.nextPhase(.capturing, on: .engineStopping) == .stopping)
        c.check("reducer.roomFinishedWhileCapturing",
                ScanFlowModel.nextPhase(.capturing, on: .roomFinished(room)) == .checking)
        let afterCheck: ScanFlowPhase = ScanFlowModel.nextPhase(.checking, on: .failed("error.deviceTooHot"))
        let afterSheet: ScanFlowPhase = ScanFlowModel.nextPhase(.quality, on: .failed("error.lowMemory"))
        c.check("reducer.failedAfterRoomFinishedStays", afterCheck == .checking && afterSheet == .quality,
                "\(afterCheck) \(afterSheet)")
        c.check("reducer.failedBeforeRoomFinished",
                ScanFlowModel.nextPhase(.capturing, on: .failed("error.ioFailed")) == .failed("error.ioFailed"))
        let doneStays: ScanFlowPhase = ScanFlowModel.nextPhase(.done(project), on: .cancelConfirmed)
        let cancelledStays: ScanFlowPhase = ScanFlowModel.nextPhase(.cancelled, on: .tipsDone)
        c.check("reducer.terminalStays", doneStays == .done(project) && cancelledStays == .cancelled,
                "\(doneStays) \(cancelledStays)")
        c.check("reducer.finishWhileChecking", ScanFlowModel.nextPhase(.checking, on: .finishTapped) == .finishing)
    }

    // MARK: - Time rules

    /// The 4 minute hint, the 5 minute limit, the 30 second paused prompt and the timer parts.
    private static func checkTimeRules(_ c: inout ScanUISelfTestChecker) {
        c.check("time.noCueBefore4Min", ScanFlowModel.timeCue(elapsed: 239, hintShown: false, limitShown: false) == nil)
        c.check("time.hintAt4Min", ScanFlowModel.timeCue(elapsed: 240, hintShown: false, limitShown: false) == .hint)
        c.check("time.limitAt5Min", ScanFlowModel.timeCue(elapsed: 300, hintShown: true, limitShown: false) == .limit)
        c.check("time.eachOnce", ScanFlowModel.timeCue(elapsed: 400, hintShown: true, limitShown: true) == nil)
        let early = ScanFlowModel.pausedPromptDue(pausedSeconds: 29.5, alreadyPrompted: false)
        let due = ScanFlowModel.pausedPromptDue(pausedSeconds: 30, alreadyPrompted: false)
        let again = ScanFlowModel.pausedPromptDue(pausedSeconds: 90, alreadyPrompted: true)
        c.check("time.pausedPrompt", !early && due && !again, "\(early) \(due) \(again)")
        let parts = ScanFlowModel.elapsedParts(245.7)
        c.check("time.elapsedParts", parts.minutes == 4 && parts.seconds == 5, "\(parts)")
    }

    // MARK: - Alerts and copy

    /// `ScanErrorCopy` for every MapperError and preflight issue, button titles and strings.
    private static func checkAlertsAndCopy(_ c: inout ScanUISelfTestChecker) {
        let errors: [MapperError] = [
            .lowStorage(freeBytes: 100), .unsupportedDevice, .cameraDenied, .trackingFailed, .deviceTooHot, .lowMemory,
            .sceneTooLarge, .roomPlanFailed("x"), .objectCaptureFailed("x"), .processingFailed(step: .quality, reason: "x"),
            .outOfMemory(step: .quality), .corruptProject("x"), .ioFailed("x"), .cancelled,
        ]
        let emptyErrors = errors.filter { error in
            let alert = ScanErrorCopy.alert(for: error)
            return alert.title.isEmpty || alert.body.isEmpty || alert.actions.isEmpty
        }
        c.check("alerts.everyErrorHasText", emptyErrors.isEmpty, "\(emptyErrors.map { $0.copyKey })")
        c.check("alerts.cameraDeniedButtons", ScanErrorCopy.alert(for: .cameraDenied).actions == [.openSettings, .ok])
        c.check("alerts.trackingButtons", ScanErrorCopy.alert(for: .trackingFailed).actions == [.resume, .finishNow])
        c.check("alerts.noticeOnlyOK", ScanErrorCopy.notice(for: .trackingFailed).actions == [.ok])
        c.check("alerts.heatText", ScanErrorCopy.alert(for: .deviceTooHot).title == Copy.RoomCapture.tooHotFinished.title)
        let issues: [PreflightIssue] = [.cameraDenied, .cameraUndetermined, .noLidar, .lowStorage(free: 1),
                                        .storageWarning(free: 2_000_000_000), .lowBattery(0.1), .deviceHot]
        let emptyIssues = issues.filter { ScanErrorCopy.alert(for: $0).title.isEmpty }
        c.check("alerts.everyIssueHasText", emptyIssues.isEmpty, "\(emptyIssues)")
        let actions: [ScanAlertAction] = [.ok, .openSettings, .finishNow, .resume]
        let titles = actions.map { ScanErrorCopy.title(for: $0) }
        c.check("alerts.buttonTitles", !titles.contains("") && Set(titles).count == titles.count, "\(titles)")

        c.check("copy.elapsed", Copy.ScanUI.elapsed(minutes: 4, seconds: 5) == "4:05",
                Copy.ScanUI.elapsed(minutes: 4, seconds: 5))
        c.check("copy.elapsedTwoDigits", Copy.ScanUI.elapsed(minutes: 12, seconds: 30) == "12:30")
        let counts = Copy.ScanUI.counts(walls: 4, doors: 1, windows: 2)
        c.check("copy.counts", counts == "4 walls, 1 door, 2 windows", counts)
    }

    // MARK: - Settings, tips, names

    /// Settings keys and defaults (in a temporary UserDefaults suite), tips and default names.
    private static func checkSettingsAndNames(_ c: inout ScanUISelfTestChecker) {
        c.check("settings.tipsKey", SettingsKey.tipsSeen(.room) == "tipsSeen.room", SettingsKey.tipsSeen(.room))
        let suite = "MapperScanUISelfTest"
        if let defaults = UserDefaults(suiteName: suite) {
            defaults.removePersistentDomain(forName: suite)
            let absentIsOn = ScanUISettings.keepAllPhotos(defaults)
            defaults.set(false, forKey: SettingsKey.keepScanPhotos)
            let settings = ScanUISettings.scanSettings(for: .room, defaults)
            c.check("settings.keepPhotos", absentIsOn && !settings.keepAllPhotos && settings.findRooms,
                    "\(absentIsOn) \(settings)")
            let before = ScanUISettings.tipsSeen(.room, defaults)
            ScanUISettings.markTipsSeen(.room, defaults)
            let after = ScanUISettings.tipsSeen(.room, defaults)
            c.check("settings.tipsSeen", !before && after && !ScanUISettings.tipsSeen(.house, defaults))
            defaults.removePersistentDomain(forName: suite)
        } else {
            c.check("settings.suite", false, "no UserDefaults suite")
        }
        let tips = ScanTipsSheet.tips(for: .room)
        c.check("tips.room", tips == Copy.Onboarding.room && tips.count == 5, "\(tips.count)")
        let name = ScanFlowModel.defaultProjectName(mode: .room, now: fixedDate, locale: Locale(identifier: "en_US"),
                                                    timeZone: TimeZone(identifier: "UTC") ?? TimeZone.current)
        c.check("names.room", name == Copy.Home.defaultRoomName("Sep 28"), name)
        let house = ScanFlowModel.defaultProjectName(mode: .house, now: fixedDate, locale: Locale(identifier: "en_US"),
                                                     timeZone: TimeZone(identifier: "UTC") ?? TimeZone.current)
        c.check("names.house", house == Copy.Home.defaultHouseName("Sep 28"), house)
    }
}

/// Counts checks and collects failures of ScanUISelfTest.
struct ScanUISelfTestChecker {
    /// Failing checks as "name: detail".
    var failures: [String] = []
    /// Number of checks run.
    var count = 0

    /// Records one check; the detail is built only on failure.
    mutating func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        count += 1
        guard !ok else { return }
        let text = detail()
        failures.append(text.isEmpty ? name + ": failed" : name + ": " + text)
    }

    /// Records one check that `value` is within `tolerance` of `expected`.
    mutating func near(_ name: String, _ value: Float, _ expected: Float, tolerance: Float) {
        let ok = value.isFinite && abs(value - expected) <= tolerance
        check(name, ok, "\(value), expected \(expected)")
    }
}
