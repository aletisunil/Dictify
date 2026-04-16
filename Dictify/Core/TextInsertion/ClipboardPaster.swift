import Cocoa

final class ClipboardPaster: @unchecked Sendable {
    func paste(_ text: String, diagnostics: AccessibilityInserter.Diagnostics? = nil) {
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        Task { @MainActor [previousContents] in
            // Small delay to let the pasteboard write commit before posting key events.
            try? await Task.sleep(nanoseconds: 50_000_000)
            Self.simulatePaste()

            // Restore clipboard after a longer delay so the target app has time to read it.
            // Electron apps (WhatsApp, Slack, Discord) need more time than native apps.
            try? await Task.sleep(nanoseconds: 800_000_000)

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if let previous = previousContents {
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func simulatePaste() {
        guard CGPreflightPostEventAccess() else {
            return
        }

        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }
}
