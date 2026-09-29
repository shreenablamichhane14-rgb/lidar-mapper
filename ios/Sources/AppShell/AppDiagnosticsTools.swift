import SwiftUI
import UIKit
import Combine

extension SettingsKey {
    /// String: the app version whose self-tests already ran automatically at launch
    /// (`AppInfo.buildTag`); a new build runs them once more (AppShell).
    static let selfTestsBuild = "selfTestsBuild"
}

/// Version facts of the running app, read from the bundle.
enum AppInfo {
    /// "0.4 (7)": marketing version and build number ("?" when missing).
    static var buildTag: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// Runs every module's self-test off the main thread, one after another, and logs each result
/// exactly as the old first screen did ("units self-test: passed in 0.12 s" and one
/// "units self-test FAIL: ..." line per failure), so `tools/phone_log.py` output keeps its
/// format. Main actor; Diagnostics and the launch run share `shared`.
@MainActor final class AppSelfTestRunner: ObservableObject {
    /// The app's runner.
    static let shared = AppSelfTestRunner()

    /// Results of the current or last run, in suite order.
    @Published private(set) var results: [SelfTestResult] = []
    /// True while a run is in progress.
    @Published private(set) var isRunning = false
    /// True once a run started in this app session.
    @Published private(set) var hasRun = false

    /// Creates a runner. The app uses `shared`.
    init() {}

    /// Runs `DiagnosticsScreen.suites` in order, each in a detached task at `priority`. Before
    /// each suite, `shouldWait` is polled once a second (the launch run pauses while the scan
    /// cover is up). A second call while running returns at once.
    func runAll(priority: TaskPriority, shouldWait: () -> Bool = { false }) async {
        guard !isRunning else { return }
        isRunning = true
        hasRun = true
        results = []
        for suite in DiagnosticsScreen.suites {
            while shouldWait() {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            let result = await Task.detached(priority: priority) { () -> SelfTestResult in
                let start = CFAbsoluteTimeGetCurrent()
                let failures = suite.run()
                return SelfTestResult(name: suite.name, failures: failures, seconds: CFAbsoluteTimeGetCurrent() - start)
            }.value
            results.append(result)
            let status = result.failures.isEmpty ? "passed" : "\(result.failures.count) failed"
            LogStore.shared.write("\(suite.name.lowercased()) self-test: \(status) in \(String(format: "%.2f", result.seconds)) s", category: "app")
            for failure in result.failures {
                LogStore.shared.write("\(suite.name.lowercased()) self-test FAIL: \(failure)", category: "app")
            }
        }
        isRunning = false
    }

    /// Pure: whether the launch run is due (the recorded build differs from this one).
    nonisolated static func launchRunDue(recorded: String?, current: String) -> Bool {
        recorded != current
    }
}

/// Share Log: the newest log file through `ShareLink(item:preview:)`; nothing when no log file
/// exists yet.
struct AppShareLogLink: View {
    /// The newest log file, read when the row appears.
    @State private var logURL: URL?

    /// Creates the row.
    init() {}

    /// The share row.
    var body: some View {
        Group {
            if let url = logURL {
                ShareLink(item: url, preview: SharePreview(url.lastPathComponent)) {
                    Label(Copy.Settings.shareLog, systemImage: "square.and.arrow.up")
                }
            } else {
                Label(Copy.Settings.shareLog, systemImage: "square.and.arrow.up")
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            logURL = await Task.detached(priority: .utility) { LogStore.shared.files().first }.value
        }
    }
}

/// The texture orientation check (ARCHITECTURE 15 question 10): the numbered checkerboard of
/// `ViewerDiagnostics.uvCheckerContent()` in a `ViewerContainer`, with what it should look like.
struct AppUVCheckerView: View {
    /// The viewer of the check.
    @StateObject private var viewer = ViewerModel()
    /// True when the pattern could not be made.
    @State private var failed = false
    /// Closes the sheet.
    @Environment(\.dismiss) private var dismiss

    /// Creates the check.
    init() {}

    /// The viewer, the hint and Done.
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    ViewerContainer(model: viewer, background: .black)
                    if failed {
                        Text(Copy.AppShell.uvCheckFailed)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
                Text(Copy.AppShell.uvCheckHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.bar)
            }
            .navigationTitle(Copy.AppShell.uvCheck)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.AppShell.done) { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    /// Writes the checkerboard off main and shows it (a failure is logged and shown).
    private func load() async {
        let made = await Task.detached(priority: .userInitiated) { () -> ViewerContent? in
            do {
                return try ViewerDiagnostics.uvCheckerContent()
            } catch {
                LogStore.shared.write("uv checker failed: \(error)", category: "viewer")
                return nil
            }
        }.value
        guard let content = made else {
            failed = true
            return
        }
        await viewer.load(content)
    }
}
