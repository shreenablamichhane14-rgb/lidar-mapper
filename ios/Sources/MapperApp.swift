import SwiftUI

@main
struct MapperApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        LogStore.shared.write("app launched", category: "app")
        // The wireless debug log is session-only (AppShell, R18): it never starts by itself.
        AppWirelessDebug.resetAtLaunch()
    }

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
