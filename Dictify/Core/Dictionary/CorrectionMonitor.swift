import AppKit
import ApplicationServices
import os

/// Watches the text field Dictify last inserted into and, when the user fixes a
/// mis-transcribed word there, auto-adds the correction to the dictionary.
///
/// Rather than a C-callback `AXObserver`, it captures at two natural moments that
/// keep all work on the main actor:
///   1. the user switches away from the app they were editing in
///      (`NSWorkspace.didDeactivateApplicationNotification`), and
///   2. the start of the next dictation (`captureArmed()`), called by the pipeline.
///
/// Works only on the AX-insertion path — clipboard-paste targets (Slack, Discord,
/// most Electron apps) expose no readable AX value, so corrections there aren't
/// learned. Gated on `autoLearnEnabled` and Accessibility permission.
@MainActor
final class CorrectionMonitor {
    private let dictionaryStore: DictionaryStore
    private let settings: DictifySettings

    private var armedElement: AXUIElement?
    private var armedText: String = ""
    // Observer token is read in the nonisolated deinit; the monitor is
    // app-lifetime and single-instance, so unsynchronized access is safe.
    private nonisolated(unsafe) var workspaceObserver: NSObjectProtocol?

    init(dictionaryStore: DictionaryStore, settings: DictifySettings) {
        self.dictionaryStore = dictionaryStore
        self.settings = settings

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.capture()
            }
        }
    }

    deinit {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
    }

    /// Arm monitoring after a successful AX insertion. Flushes any pending
    /// correction from a prior insertion before re-arming on the new field.
    func arm(insertedText: String) {
        guard settings.autoLearnEnabled, AccessibilityInserter.isAccessibilityGranted else {
            disarm()
            return
        }
        capture()
        guard !insertedText.isEmpty, let element = Self.focusedElement() else {
            disarm()
            return
        }
        armedElement = element
        armedText = insertedText
    }

    /// Capture any pending correction now (e.g. at the start of the next dictation).
    func captureArmed() {
        capture()
    }

    private func disarm() {
        armedElement = nil
        armedText = ""
    }

    private func capture() {
        guard settings.autoLearnEnabled else { disarm(); return }
        guard let element = armedElement, !armedText.isEmpty else { return }
        defer { disarm() }

        guard let current = Self.stringValue(element), current != armedText else { return }
        let corrections = CorrectionLearner.extractCorrections(
            originalText: armedText,
            fieldValue: current,
            existingDictionary: dictionaryStore.entries.map { $0.term }
        )
        guard !corrections.isEmpty else { return }

        let added = dictionaryStore.addLearned(corrections)
        if !added.isEmpty {
            Log.pipeline.notice("Auto-learned \(added.count, privacy: .public) correction(s) from a user edit")
        }
    }

    // MARK: - AX helpers

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return nil
        }
        return (focused as! AXUIElement)
    }

    private static func stringValue(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
