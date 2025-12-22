import SwiftUI

@main
struct CheapExpanderApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("CheapExpander", systemImage: appState.isEnabled ? "bolt.fill" : "bolt.slash") {
            MenuBarView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 600)
    }
}
