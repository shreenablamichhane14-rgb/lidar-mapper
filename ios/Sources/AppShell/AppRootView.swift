import SwiftUI

/// The app's root (docs/MODULES.md 3.29, ARCHITECTURE 10.1): a `NavigationStack(path:)` over
/// `HomeScreen` with the result, Settings and Diagnostics routes; the scan cover
/// (`.fullScreenCover(item:)`, processing suspended while it is up); the export sheet
/// (`.sheet(item:)`); the launch recovery sheet; and the no-LiDAR alert.
///
/// Launch, once: `ProjectLibrary.shared.reload()`, the capability and memory log lines,
/// `RecoveryService.pending()` (the recovery sheet when not empty), `ExportRunner.removeStaleStaging()`
/// off main, then `ProcessingPlans.resumePending()` now that Home is on screen, and the
/// self-tests once per new build (paused while a scan cover is up).
struct AppRootView: View {
    /// Navigation state.
    @StateObject private var router: AppRouter
    /// The project list (Store). Not observed here: HomeScreen observes it, so a list change or
    /// a 10 Hz progress update never re-renders the root and the pushed result screen.
    private let library: ProjectLibrary
    /// Processing state (Pipeline), observed by HomeScreen only.
    private let runner: ProcessingRunner

    /// Creates the root.
    init() {
        _router = StateObject(wrappedValue: AppRouter())
        library = ProjectLibrary.shared
        runner = ProcessingRunner.shared
    }

    /// Home in its stack, with the covers, sheets and alerts of the app.
    var body: some View {
        let appRouter = router
        return NavigationStack(path: $router.path) {
            home
                .navigationDestination(for: AppRoute.self) { route in
                    destination(route)
                }
        }
        .environmentObject(router)
        .sheet(item: $router.exportRequest) { request in
            ExportSheet(projectID: request.projectID, viewState: request.viewState)
        }
        .fullScreenCover(item: $router.scanRequest, onDismiss: {
            appRouter.scanCoverDismissed()
        }) { request in
            AppScanCoordinator(request: request) { projectID in
                appRouter.scanFlowEnded(projectID)
            }
        }
        .sheet(isPresented: $router.showsRecoverySheet, onDismiss: {
            appRouter.recoverySheetDismissed()
        }) {
            recoverySheet
        }
        .alert(Copy.Errors.noLidar.title, isPresented: $router.showsNoLidarAlert) {
            Button(Copy.Errors.ok, role: .cancel) {}
        } message: {
            Text(Copy.Errors.noLidar.body)
        }
        .alert(Copy.Errors.saveFailed.title, isPresented: $router.showsRecoveryError) {
            Button(Copy.Errors.ok, role: .cancel) {}
        } message: {
            Text(Copy.Errors.saveFailed.body)
        }
        .task {
            launch()
        }
    }

    // MARK: - Content

    /// Home with the build 4 modes.
    private var home: some View {
        let appRouter = router
        return HomeScreen(library: library, runner: runner, availableModes: AppRouter.availableModes,
                          onNewScan: { mode in appRouter.startScan(mode) },
                          onOpen: { id in appRouter.openResult(id) },
                          onSettings: { appRouter.openSettings() })
    }

    /// The screen of a route.
    @ViewBuilder private func destination(_ route: AppRoute) -> some View {
        switch route {
        case .result(let id):
            AppResultsCoordinator(projectID: id)
                .environmentObject(router)
        case .settings:
            SettingsScreen()
        case .diagnostics:
            DiagnosticsScreen()
        }
    }

    /// The first unfinished scan of the queue, with Keep Scan and Discard.
    @ViewBuilder private var recoverySheet: some View {
        if let info = router.recoveryQueue.first {
            let appRouter = router
            AppRecoverySheet(info: info, onKeep: {
                AppRootView.keep(info, router: appRouter)
            }, onDiscard: {
                AppRootView.discard(info, router: appRouter)
            })
            .id(info.scanID)
            .presentationDetents([.medium, .large])
            .interactiveDismissDisabled()
        }
    }

    // MARK: - Launch

    /// The launch sequence (once per process; the task can run again after a cover closes).
    private func launch() {
        guard router.beginLaunch() else { return }
        router.log("launch: version \(AppInfo.buildTag)")
        ProjectLibrary.shared.reload()
        AppCapabilityProbe.logLaunchFacts()
        router.offerRecovery(RecoveryService.pending())
        Task.detached(priority: .utility) {
            ExportRunner.removeStaleStaging()
        }
        ProcessingPlans.resumePending()
        startLaunchSelfTests()
    }

    /// Runs every self-test once after a new build was installed, in the background, pausing
    /// while a scan cover is up. The install is recorded first, so a crashing suite cannot loop.
    private func startLaunchSelfTests() {
        let defaults = UserDefaults.standard
        let current = AppInfo.installStamp
        guard AppSelfTestRunner.launchRunDue(recorded: defaults.string(forKey: SettingsKey.selfTestsBuild),
                                             current: current) else { return }
        defaults.set(current, forKey: SettingsKey.selfTestsBuild)
        router.log("self-tests run once for build \(current)")
        let appRouter = router
        Task {
            await AppSelfTestRunner.shared.runAll(priority: .utility, shouldWait: { appRouter.scanRequest != nil })
        }
    }

    // MARK: - Recovery actions

    /// Keep Scan: seals, moves and enqueues the scan (after a frame, so the button's spinner
    /// shows while the files are listed).
    private static func keep(_ info: InProgressScanInfo, router: AppRouter) {
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            var failed = false
            do {
                try RecoveryService.recover(info)
            } catch {
                failed = true
                router.log("recover \(AppRouter.short(info.scanID)) failed: \(StoreFiles.describe(error))")
            }
            router.recoveryHandled(info, failed: failed)
        }
    }

    /// Discard: removes the folder (and its empty project) off main.
    private static func discard(_ info: InProgressScanInfo, router: AppRouter) {
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try RecoveryService.discard(info)
                    return nil
                } catch {
                    return StoreFiles.describe(error)
                }
            }.value
            if let failure {
                router.log("discard \(AppRouter.short(info.scanID)) failed: \(failure)")
            } else {
                router.log("unfinished scan \(AppRouter.short(info.scanID)) discarded by the user")
            }
            router.recoveryHandled(info, failed: failure != nil)
        }
    }
}

/// The launch recovery sheet for one unfinished scan (ARCHITECTURE 3.4, 10.2): what happened,
/// when the scan started, Keep Scan (prominent, at the bottom within thumb reach) and Discard.
struct AppRecoverySheet: View {
    /// The unfinished scan.
    let info: InProgressScanInfo
    /// Keep Scan tapped.
    let onKeep: () -> Void
    /// Discard tapped.
    let onDiscard: () -> Void

    /// True after a button was tapped (both disable, a spinner shows).
    @State private var isWorking = false

    /// Creates the sheet for one unfinished scan.
    init(info: InProgressScanInfo, onKeep: @escaping () -> Void, onDiscard: @escaping () -> Void) {
        self.info = info
        self.onKeep = onKeep
        self.onDiscard = onDiscard
    }

    /// The sheet.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "arrow.counterclockwise.circle")
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text(Copy.AppShell.recoverTitle)
                        .font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Text(Copy.AppShell.recoverBody)
                        .font(.body)
                    Text(Copy.AppShell.recoverStarted(info.startedAt.formatted(date: .abbreviated, time: .shortened)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 28)
            }
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: 10) {
                Button {
                    isWorking = true
                    onKeep()
                } label: {
                    HStack(spacing: 8) {
                        if isWorking { ProgressView() }
                        Text(Copy.AppShell.recoverKeep)
                    }
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                Button(role: .destructive) {
                    isWorking = true
                    onDiscard()
                } label: {
                    Text(Copy.AppShell.recoverDiscard)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
            .disabled(isWorking)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}
