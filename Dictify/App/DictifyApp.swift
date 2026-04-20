import AppKit
import SwiftUI

@main
struct DictifyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The AppDelegate owns the main window as a plain NSWindow so we can
        // control lifecycle (close-doesn't-quit, dock reopen, onboarding handoff).
        // We keep a Settings scene purely so ⌘, routes to our main window.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") {
                        Task { @MainActor in
                            appDelegate.showMainWindow(selectedTab: .general)
                        }
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
                CommandGroup(after: .windowArrangement) {
                    Button("Dictify Home") {
                        Task { @MainActor in
                            appDelegate.showMainWindow(selectedTab: .home)
                        }
                    }
                    .keyboardShortcut("0", modifiers: .command)
                }
            }
    }
}
