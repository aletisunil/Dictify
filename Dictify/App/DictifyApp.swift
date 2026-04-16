import AppKit
import SwiftUI

@main
struct DictifyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    Task { @MainActor in
                        appDelegate.openSettings()
                    }
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
