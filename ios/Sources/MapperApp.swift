import SwiftUI

@main
struct MapperApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        LogStore.shared.write("app launched", category: "app")
        if UserDefaults.standard.bool(forKey: SettingsKey.wirelessDebug) {
            DebugServer.shared.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            LogStore.shared.write("app \(phase == .active ? "active" : phase == .background ? "background" : "inactive")", category: "app")
        }
    }
}
