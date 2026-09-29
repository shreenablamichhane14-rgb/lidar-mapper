import SwiftUI

/// The app entry point: starts the log, keeps the wireless debug log session-only and shows
/// `ContentView` (AppShell's `AppRootView`).
@main
struct MapperApp: App {
    /// Foreground, inactive or background; logged, and the debug listener stops in the background.
    @Environment(\.scenePhase) private var scenePhase

    /// Logs the launch and turns the wireless debug setting off (it never starts by itself).
    init() {
        LogStore.shared.write("app launched", category: "app")
        // The wireless debug log is session-only (AppShell, R18): it never starts by itself.
        AppWirelessDebug.resetAtLaunch()
    }

    /// One window with the app root.
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            LogStore.shared.write("app \(phase == .active ? "active" : phase == .background ? "background" : "inactive")", category: "app")
            if phase == .background {
                AppWirelessDebug.appDidEnterBackground()
            }
        }
    }
}
