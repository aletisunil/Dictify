import AppKit
import Carbon
import Foundation
import os

/// Accessibility helpers shared by everything that reads another app's text
/// (`TargetContextReader`, `CorrectionWatcher`). Every call is synchronous IPC
/// into the target app: call these off the main thread, with a messaging
/// timeout set on each element.
enum AXAccess {
    /// Bundle-ID prefixes of browsers. Prefixes so channel builds (Chrome Beta,
    /// Edge Dev, Firefox Developer Edition) match too.
    private static let browserPrefixes = [
        "com.apple.Safari",
        "org.mozilla.firefox",
        "org.mozilla.nightly",
        "app.zen-browser.zen",
    ] + chromiumPrefixes

    /// Chromium browsers only build their page accessibility tree for clients
    /// that ask for it; see `PageAccessibility`.
    private static let chromiumPrefixes = [
        "com.google.Chrome",
        "org.chromium.Chromium",
        "company.thebrowser.Browser", // Arc
        "company.thebrowser.dia",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "ai.perplexity.comet",
        "com.openai.atlas",
    ]

    /// Terminal "fields" are the whole scrollback, which can hold secrets that
    /// commands printed. Never read it. `TargetCategory` reuses the list.
    static let terminalPrefixes = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
    ]

    /// Electron editors built on VS Code switch themselves into screen reader
    /// mode when an app turns their accessibility tree on, which changes the
    /// editor under the user. Their page tree is never requested.
    private static let screenReaderSensitivePrefixes = [
        "com.microsoft.VSCode", // VS Code and Insiders
        "com.vscodium",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
    ]

    /// Chromium and WebKit expose contenteditable (Gmail compose, Slack's
    /// box) as AXTextArea, so these cover web editors too.
    private static let editableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField",
    ]

    static func isBrowser(_ bundleID: String?) -> Bool {
        matches(bundleID, browserPrefixes)
    }

    static func isTerminal(_ bundleID: String?) -> Bool {
        matches(bundleID, terminalPrefixes)
    }

    private static func matches(_ bundleID: String?, _ prefixes: [String]) -> Bool {
        guard let bundleID else { return false }
        return prefixes.contains { bundleID.hasPrefix($0) }
    }

    /// True for apps that only build their page accessibility tree for a
    /// client that asks for it: Chromium browsers and Electron apps (Slack,
    /// Discord, Notion, Obsidian). Without the tree they report no focused
    /// element at all. See `PageAccessibility`.
    static func needsPageAccessibility(pid: pid_t, bundleID: String?) -> Bool {
        if matches(bundleID, chromiumPrefixes) { return true }
        guard !matches(bundleID, screenReaderSensitivePrefixes) else { return false }
        return isElectron(pid: pid)
    }

    private static let electronCache = OSAllocatedUnfairLock(initialState: [String: Bool]())

    /// Electron apps ship "Electron Framework.framework"; their bundle IDs
    /// follow no pattern. Cached per bundle path.
    private static func isElectron(pid: pid_t) -> Bool {
        guard let bundleURL = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
        let key = bundleURL.path
        if let cached = electronCache.withLock({ $0[key] }) { return cached }
        let framework = bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        let result = FileManager.default.fileExists(atPath: framework.path)
        electronCache.withLock { $0[key] = result }
        return result
    }

    /// Runs blocking AX work on `queue` and resumes with its result. AX calls
    /// are synchronous IPC into the target app, so they never run on the
    /// caller's executor.
    static func run<T: Sendable>(on queue: DispatchQueue, _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// The app's focused element when it is editable text that may be read:
    /// not while secure input is on (typing a password turns it on), not a
    /// secure text field, not a field that marks itself protected, and not a
    /// focused page or list - those may report a selection too, but their
    /// text is the page, not the user's draft.
    static func focusedEditableField(app: AXUIElement, timeout: Float) -> AXUIElement? {
        guard !IsSecureEventInputEnabled(),
              let focused = element(app, kAXFocusedUIElementAttribute as CFString, timeout: timeout) else {
            return nil
        }
        if (copy(focused, kAXSubroleAttribute as CFString) as? String) == (kAXSecureTextFieldSubrole as String) {
            return nil
        }
        if let protected = copy(focused, NSAccessibility.Attribute.containsProtectedContent.rawValue as CFString),
           (protected as? Bool) == true {
            return nil
        }
        guard let role = role(of: focused), editableRoles.contains(role) else { return nil }
        return focused
    }

    static func copy(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    static func element(_ parent: AXUIElement, _ attribute: CFString, timeout: Float) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(parent, timeout)
        guard let value = copy(parent, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        let child = value as! AXUIElement
        AXUIElementSetMessagingTimeout(child, timeout)
        return child
    }

    static func role(of element: AXUIElement) -> String? {
        copy(element, kAXRoleAttribute as CFString) as? String
    }

    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let value = copy(element, kAXSelectedTextRangeAttribute as CFString),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    static func string(_ element: AXUIElement, _ range: CFRange) -> String? {
        guard range.length > 0 else { return "" }
        var cfRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    /// Pid of the app that holds keyboard focus system-wide. No messaging
    /// timeout here: on the system-wide element it would change the timeout
    /// for every AX call in the process, the inserter's included.
    static func focusedApplicationPID() -> pid_t? {
        guard let value = copy(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        var pid: pid_t = 0
        return AXUIElementGetPid(value as! AXUIElement, &pid) == .success ? pid : nil
    }
}

/// Turns a Chromium or Electron app's page accessibility tree on while Dictify
/// reads it, and back off once nothing has needed it for `releaseGrace`.
///
/// Electron honours AXManualAccessibility. Chrome rejects it and needs
/// AXEnhancedUserInterface, the attribute VoiceOver sets; Chrome answers that
/// set with kAXErrorNotImplemented even when it applies it, so the result is
/// judged by reading the attribute back. Left on, either attribute makes the
/// app maintain the full tree for every page (CPU and memory for as long as it
/// runs), and AXEnhancedUserInterface also animates or breaks window moves
/// made by window managers. So every reader holds a lease, and the attribute
/// Dictify set is cleared after the last lease ends. The grace period spares
/// a cold rebuild (about 2 s for Gmail) between dictations in a row.
///
/// A tree that was already on (VoiceOver, another assistive app) is never
/// turned off, and neither is anything while VoiceOver is running.
final class PageAccessibility: @unchecked Sendable {
    static let shared = PageAccessibility()

    struct Lease: Sendable {
        fileprivate let pid: pid_t
        /// True when the tree was turned on moments ago. The app builds it
        /// asynchronously, so a read that misses may succeed on a retry.
        let mayBeBuilding: Bool
    }

    static let releaseGrace: TimeInterval = 60
    /// How long after being turned on the tree may still be building.
    private static let buildWindow: TimeInterval = 4
    private static let callTimeout: Float = 0.1

    private struct State {
        var leases = 0
        /// The attribute Dictify set, or nil when the tree was already on or
        /// could not be turned on - then there is nothing to restore.
        var attribute: CFString?
        var enabledAt = Date()
        var pendingRestore: DispatchWorkItem?
    }

    /// All state lives on this queue; every method hops onto it.
    private let queue = DispatchQueue(label: "com.dictify.page-accessibility")
    private var states: [pid_t: State] = [:]

    /// Call off the main thread: turning the tree on is IPC into the app.
    func acquire(pid: pid_t) -> Lease {
        queue.sync {
            if var state = states[pid] {
                state.leases += 1
                state.pendingRestore?.cancel()
                state.pendingRestore = nil
                states[pid] = state
                let building = state.attribute != nil && Date().timeIntervalSince(state.enabledAt) < Self.buildWindow
                return Lease(pid: pid, mayBeBuilding: building)
            }
            let attribute = Self.turnOn(AXUIElementCreateApplication(pid))
            if let attribute {
                Log.pipeline.notice("Page accessibility turned on for pid \(pid, privacy: .public) (\(attribute as String, privacy: .public))")
            }
            states[pid] = State(leases: 1, attribute: attribute)
            return Lease(pid: pid, mayBeBuilding: attribute != nil)
        }
    }

    func release(_ lease: Lease) {
        queue.async { [self] in
            guard var state = states[lease.pid] else { return }
            state.leases -= 1
            guard state.leases <= 0 else {
                states[lease.pid] = state
                return
            }
            guard state.attribute != nil else {
                states[lease.pid] = nil
                return
            }
            let work = DispatchWorkItem { [self] in self.restore(pid: lease.pid) }
            state.pendingRestore = work
            states[lease.pid] = state
            queue.asyncAfter(deadline: .now() + Self.releaseGrace, execute: work)
        }
    }

    /// Clears every attribute Dictify set, now. For app termination: a lease
    /// still held then would otherwise leave the tree on for good.
    func restoreAll() {
        queue.sync {
            for pid in Array(states.keys) {
                restore(pid: pid)
            }
        }
    }

    /// On `queue`.
    private func restore(pid: pid_t) {
        guard let state = states.removeValue(forKey: pid) else { return }
        state.pendingRestore?.cancel()
        guard let attribute = state.attribute, !NSWorkspace.shared.isVoiceOverEnabled else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.callTimeout)
        let result = AXUIElementSetAttributeValue(app, attribute, kCFBooleanFalse)
        Log.pipeline.notice("Page accessibility turned off for pid \(pid, privacy: .public) (\(attribute as String, privacy: .public), result \(result.rawValue, privacy: .public))")
    }

    /// Returns the attribute that turned the tree on, or nil when it was
    /// already on or neither attribute took.
    private static func turnOn(_ app: AXUIElement) -> CFString? {
        AXUIElementSetMessagingTimeout(app, callTimeout)
        let manual = "AXManualAccessibility" as CFString
        let enhanced = "AXEnhancedUserInterface" as CFString
        if (AXAccess.copy(app, manual) as? Bool) == true || (AXAccess.copy(app, enhanced) as? Bool) == true {
            return nil
        }
        if AXUIElementSetAttributeValue(app, manual, kCFBooleanTrue) == .success {
            return manual
        }
        _ = AXUIElementSetAttributeValue(app, enhanced, kCFBooleanTrue)
        return (AXAccess.copy(app, enhanced) as? Bool) == true ? enhanced : nil
    }
}
