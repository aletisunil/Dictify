import Cocoa

/// Apps known to break AX insertion. These skip straight to clipboard without
/// wasting a verification round-trip on AX.
private let clipboardOnlyBundleIDs: Set<String> = [
    "com.tinyspeck.slackmacgap",      // Slack
    "com.hnc.Discord",                 // Discord
    "notion.id",                       // Notion
    "com.electron.whatsapp",           // WhatsApp
    "WhatsApp"
]

enum ClipboardPasteOutcome: Sendable, Equatable {
    case success
    case skippedSecureField
    case postEventDenied
}

@MainActor
final class ClipboardPaster {
    /// Returns the outcome synchronously enough for the pipeline to react
    /// (surface an NSAlert etc.). Pasteboard restore happens asynchronously.
    @discardableResult
    func paste(_ text: String, diagnostics: AccessibilityInserter.Diagnostics? = nil) -> ClipboardPasteOutcome {
        // Honour the secure-field signal from the AX pass. We must NOT paste
        // into password or protected fields; do nothing and bubble up.
        if diagnostics?.isSecureOrProtected == true {
            Log.ui.notice("Skipped clipboard paste into secure/protected field")
            return .skippedSecureField
        }

        // Snapshot every item and type on the pasteboard, not just the string.
        // This preserves images, files, RTF, URLs, etc.
        let pasteboard = NSPasteboard.general
        let snapshot = Self.snapshot(pasteboard)

        pasteboard.clearContents()
        Self.writeConcealed(text, to: pasteboard)
        let changeCountAfterOverwrite = pasteboard.changeCount

        guard CGPreflightPostEventAccess() else {
            // Cannot synthesize Cmd+V. Restore what we clobbered and bail.
            Self.restore(snapshot: snapshot, to: pasteboard)
            return .postEventDenied
        }

        // Shared flag so the async poll Task and the hard-timeout DispatchQueue
        // don't double-restore (which would clobber fresh clipboard writes).
        let restoredBox = RestoredBox()

        Task { [snapshot, changeCountAfterOverwrite] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            Self.simulatePaste()

            // NSPasteboard.changeCount bumps only when someone WRITES to the
            // pasteboard — a normal paste (read) never changes it, so paste
            // consumption is unobservable. Instead: wait long enough for slow
            // hosts (Electron) to process the ⌘V, then restore the snapshot
            // only while our write is still the latest. If the count moved,
            // the user or another app wrote something newer — restoring would
            // clobber it, so leave the pasteboard alone.
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 80_000_000)
                if pasteboard.changeCount != changeCountAfterOverwrite {
                    // Another writer owns the clipboard now. Claim the box so
                    // the hard-timeout below can't restore over it either.
                    _ = restoredBox.claim()
                    Log.ui.notice("Clipboard rewritten by another app — skipping snapshot restore")
                    return
                }
            }

            if restoredBox.claim() {
                Self.restore(snapshot: snapshot, to: pasteboard)
            }
        }

        // Hard-timeout safety net. DispatchQueue.main.asyncAfter fires even if
        // the Task above is suspended/cancelled, so a backgrounded app can't
        // leave the user's clipboard with our inserted text. Same ownership
        // rule: only restore while our write is still the latest.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [snapshot] in
            guard pasteboard.changeCount == changeCountAfterOverwrite,
                  restoredBox.claim() else { return }
            Self.restore(snapshot: snapshot, to: pasteboard)
        }

        return .success
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        Self.writeConcealed(text, to: pasteboard)
    }

    /// Writes `text` to the pasteboard alongside the nspasteboard.org
    /// "concealed" marker so third-party clipboard managers (Raycast, Alfred,
    /// Maccy, Paste, etc.) skip recording the transcription in their history.
    /// Spec: http://nspasteboard.org
    private static func writeConcealed(_ text: String, to pasteboard: NSPasteboard) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.writeObjects([item])
    }

    static func shouldSkipAccessibilityFor(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return clipboardOnlyBundleIDs.contains(bundleID)
    }

    // MARK: - Snapshot / restore

    private struct PasteboardSnapshot {
        let items: [[String: Data]]
    }

    /// Single-shot flag shared between the async poll Task and the hard-timeout
    /// dispatch. First caller to `claim()` wins; subsequent callers get `false`.
    private final class RestoredBox: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        var items: [[String: Data]] = []
        if let pbItems = pasteboard.pasteboardItems {
            for item in pbItems {
                var typeDict: [String: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        typeDict[type.rawValue] = data
                    }
                }
                if !typeDict.isEmpty {
                    items.append(typeDict)
                }
            }
        }
        return PasteboardSnapshot(items: items)
    }

    private static func restore(snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }

        var newItems: [NSPasteboardItem] = []
        for typeDict in snapshot.items {
            let item = NSPasteboardItem()
            for (rawType, data) in typeDict {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
            newItems.append(item)
        }
        pasteboard.writeObjects(newItems)
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
