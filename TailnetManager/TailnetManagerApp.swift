import SwiftUI

@main
struct TailnetManagerApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            RootView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Lock Tailnet Manager") { appState.lock() }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(!appState.isSignedIn || !appState.isUnlocked)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await appState.refreshNow() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!appState.isSignedIn || !appState.isUnlocked || appState.isRefreshing)
            }
        }
        #else
        WindowGroup {
            RootView()
                .environment(appState)
        }
        #endif
    }
}
