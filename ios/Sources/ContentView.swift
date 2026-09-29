import SwiftUI

/// The app's first view, kept so `MapperApp` stays unchanged in shape: it hosts AppShell's
/// `AppRootView` (Home in a NavigationStack with the scan cover, results, Settings and
/// Diagnostics). The capability probe rows, `SelfTestSuite`, `SelfTestResult` and the self-test
/// suite list moved to `AppShell/AppDiagnosticsScreen.swift` (Settings > Diagnostics).
struct ContentView: View {
    /// The app root.
    var body: some View {
        AppRootView()
    }
}
