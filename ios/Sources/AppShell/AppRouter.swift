import Foundation
import Combine

/// A screen pushed on the app's navigation stack (ARCHITECTURE 10.1).
enum AppRoute: Hashable {
    /// The result screen of a project.
    case result(UUID)
    /// Settings.
    case settings
    /// Settings > Diagnostics.
    case diagnostics
}

/// Drives the scan cover (`.fullScreenCover(item:)`): one request per scan, so every scan gets
/// a fresh `ScanFlowModel`.
struct ScanRequest: Identifiable, Equatable {
    /// Identity of this presentation.
    var id: UUID
    /// What is being scanned.
    var mode: ScanMode
    /// Demo Mode: `FakeScanEngine`, no camera, no ARKit.
    var isDemo: Bool
}

/// Drives the export sheet. `UUID` itself is not `Identifiable`, so `.sheet(item:)` needs this
/// wrapper (never add a retroactive `extension UUID: Identifiable`).
struct ExportRequest: Identifiable, Equatable {
    /// Identity of this presentation.
    let id: UUID
    /// The project to export.
    var projectID: UUID
    /// What the result screen showed when Export was tapped (Hide Furniture, plan toggles).
    var viewState: ExportViewState
}

/// App navigation state (ARCHITECTURE 10.1): the stack path over Home, the scan cover, the
/// export sheet, the launch recovery queue and the no-LiDAR alert. Main actor.
///
/// Processing never runs next to a capture (ARCHITECTURE 12.1): `startScan` suspends the
/// runner before the cover (and so the preflight) appears, and `scanCoverDismissed` resumes it
/// once the cover is gone.
@MainActor final class AppRouter: ObservableObject {
    /// Modes New Scan can start in build 4.
    static let availableModes: Set<ScanMode> = [.room]
    /// Log category of the app shell.
    nonisolated static let logCategory = "appshell"

    /// The pushed screens, Home being the root.
    @Published var path: [AppRoute]
    /// The scan in progress; drives `.fullScreenCover(item:)`.
    @Published var scanRequest: ScanRequest?
    /// The export in progress; drives `.sheet(item: $router.exportRequest)`.
    @Published var exportRequest: ExportRequest?
    /// Unfinished scans still to offer at launch, oldest first (the first one is on screen).
    @Published var recoveryQueue: [InProgressScanInfo] = []
    /// True while the "This iPhone can't scan in 3D" alert shows.
    @Published var showsNoLidarAlert = false
    /// True while the recovery error alert shows.
    @Published var showsRecoveryError = false

    /// The project to open once the scan cover has closed (set by a finished scan).
    private var pendingResult: UUID?
    /// True once the launch sequence ran (the root view's task can run again after the cover).
    private(set) var hasLaunched = false

    /// An empty stack at Home.
    init() {
        path = []
    }

    // MARK: - Navigation

    /// New Scan with a picked mode. Outside Demo Mode a device without LiDAR shows
    /// `Copy.Errors.noLidar` instead; otherwise processing is suspended and the cover appears.
    func startScan(_ mode: ScanMode) {
        guard scanRequest == nil else {
            log("new scan ignored: a scan is already up")
            return
        }
        guard AppRouter.availableModes.contains(mode) else {
            log("new scan ignored: \(mode.rawValue) is not available in this version")
            return
        }
        let isDemo = ScanUISettings.isDemoMode()
        if !isDemo && !ScanPreflight.lidarSupported(for: mode) {
            log("new scan refused: this device has no LiDAR scanner or RoomPlan")
            showsNoLidarAlert = true
            return
        }
        ProcessingRunner.shared.suspendAll(reason: "capture")
        let request = ScanRequest(id: UUID(), mode: mode, isDemo: isDemo)
        log("scan cover opens: \(mode.rawValue), demo \(isDemo)")
        scanRequest = request
    }

    /// Pushes the result screen of a project (Home row, finished scan).
    func openResult(_ id: UUID) {
        log("open result \(AppRouter.short(id))")
        path = [.result(id)]
    }

    /// Pushes Settings.
    func openSettings() {
        path = [.settings]
    }

    /// Presents the export sheet for a project with the result screen's view state.
    func export(projectID: UUID, viewState: ExportViewState) {
        guard exportRequest == nil else { return }
        log("export sheet opens for \(AppRouter.short(projectID))")
        exportRequest = ExportRequest(id: UUID(), projectID: projectID, viewState: viewState)
    }

    // MARK: - Scan cover

    /// The scan flow ended: with a project (Finish) the result opens once the cover is gone;
    /// without one (cancel, discard, failure) Home stays.
    func scanFlowEnded(_ projectID: UUID?) {
        if let id = projectID {
            pendingResult = id
            log("scan finished with project \(AppRouter.short(id))")
        } else {
            log("scan ended without a project")
        }
        scanRequest = nil
    }

    /// The cover is gone: processing resumes and the finished project's result opens.
    func scanCoverDismissed() {
        ProcessingRunner.shared.resumeAll()
        guard let id = pendingResult else { return }
        pendingResult = nil
        openResult(id)
    }

    // MARK: - Launch

    /// Marks the launch sequence as done; returns false when it already ran.
    func beginLaunch() -> Bool {
        guard !hasLaunched else { return false }
        hasLaunched = true
        return true
    }

    /// Replaces the recovery queue (launch).
    func offerRecovery(_ infos: [InProgressScanInfo]) {
        recoveryQueue = infos
        if !infos.isEmpty { log("recovery offered for \(infos.count) unfinished scans") }
    }

    /// Drops the scan on screen from the recovery queue; `failed` shows the error alert.
    func recoveryHandled(_ info: InProgressScanInfo, failed: Bool) {
        recoveryQueue.removeAll { $0.scanID == info.scanID }
        if failed { showsRecoveryError = true }
    }

    // MARK: - Log

    /// Writes one line to the app log.
    func log(_ message: String) {
        LogStore.shared.write(message, category: AppRouter.logCategory)
    }

    /// First 8 characters of an id for the log.
    nonisolated static func short(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }
}
