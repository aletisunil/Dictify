import AppKit
import Carbon
import Foundation
import os

/// Reads the browser tab host and the focused field's text through
/// Accessibility. Every AX call is a synchronous IPC round-trip into the target
/// app, so all of it runs on a private queue - never the main thread or the
/// hotkey path - under per-call messaging timeouts and a search budget. A slow
/// or hung target only costs a missing hint, never a late dictation.
enum TargetContextReader {
    struct Request: Sendable {
        let pid: pid_t
        let bundleID: String?
        let appName: String?
        /// Read the tab host and classify the target (app-aware tone).
        let includeWebsite: Bool
        /// Read the text around the cursor.
        let includeField: Bool
    }

    static let maxBeforeLength = 1000
    static let maxSelectedLength = 500
    static let maxAfterLength = 300

    /// Per-call AX messaging timeouts (seconds). The default is 6 s.
    private static let urlCallTimeout: Float = 0.05
    private static let fieldCallTimeout: Float = 0.1
    /// Budget for finding the tab's AXWebArea.
    private static let webAreaSearchBudget: TimeInterval = 0.05
    private static let webAreaSearchMaxElements = 400
    /// Chromium builds its page tree asynchronously after it is first turned
    /// on, so the first read can come back empty; see `read`.
    private static let pageAccessibilityWait: TimeInterval = 4
    private static let pageAccessibilityPollInterval: UInt64 = 150_000_000

    private static let queue = DispatchQueue(label: "com.dictify.target-context", qos: .userInitiated)

    static func read(_ request: Request) async -> TargetContext {
        let start = DispatchTime.now()
        let isBrowser = AXAccess.isBrowser(request.bundleID)

        var pass = await AXAccess.run(on: queue) { readOnce(request, isBrowser: isBrowser, lease: nil) }
        // A cold Chromium can take seconds to build a heavy page's tree (about
        // 2 s for Gmail), so keep re-reading what is missing while the user
        // speaks. The pipeline cancels this task when refinement starts or the
        // dictation is dropped, which ends the wait with whatever has been
        // read by then.
        if pass.lease?.mayBeBuilding == true {
            let deadline = Date().addingTimeInterval(pageAccessibilityWait)
            while isIncomplete(pass, request, isBrowser: isBrowser), Date() < deadline {
                do {
                    try await Task.sleep(nanoseconds: pageAccessibilityPollInterval)
                } catch {
                    break
                }
                let lease = pass.lease
                let retry = await AXAccess.run(on: queue) { readOnce(request, isBrowser: isBrowser, lease: lease) }
                pass.host = pass.host ?? retry.host
                pass.field = pass.field ?? retry.field
            }
        }
        if let lease = pass.lease {
            PageAccessibility.shared.release(lease)
        }
        let host = pass.host

        let category: TargetCategory = request.includeWebsite
            ? TargetCategory.classify(bundleID: request.bundleID, host: host)
            : .other
        // In a browser the app name says nothing about the page; without a
        // host it would only steer the register at random.
        let knowsTarget = request.includeWebsite && (!isBrowser || host != nil)
        let context = TargetContext(
            appName: knowsTarget ? request.appName : nil,
            bundleID: request.bundleID,
            host: request.includeWebsite ? host : nil,
            category: category,
            field: pass.field
        )

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        let fieldSummary = pass.field.map { "before=\($0.before.count) selected=\($0.selected.count) after=\($0.after.count)" } ?? "none"
        Log.pipeline.notice("""
            Target context: bundle=\(request.bundleID ?? "unknown", privacy: .public) \
            host=\(context.host ?? "none", privacy: .public) \
            category=\(category.rawValue, privacy: .public) \
            field=\(fieldSummary, privacy: .public) \
            in \(String(format: "%.1f", elapsedMs), privacy: .public) ms
            """)
        return context
    }

    /// The text around the cursor of whatever field has keyboard focus now.
    /// Read right before insertion: the snapshot from the start of the
    /// recording says nothing about a field the user moved to since. Never
    /// turns a page tree on (that would delay the insertion), so it is nil
    /// in a Chromium or Electron app no lease has touched lately.
    static func currentField() async -> FieldContext? {
        await AXAccess.run(on: queue) {
            guard let pid = AXAccess.focusedApplicationPID(),
                  !AXAccess.isTerminal(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier) else {
                return nil
            }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, fieldCallTimeout)
            return focusedFieldContext(app: app)
        }
    }

    private static func isIncomplete(_ pass: Pass, _ request: Request, isBrowser: Bool) -> Bool {
        (request.includeWebsite && isBrowser && pass.host == nil)
            || (request.includeField && pass.field == nil)
    }

    // MARK: - One pass

    private struct Pass {
        var host: String?
        var field: FieldContext?
        /// Held while the page tree is needed; `read` releases it.
        var lease: PageAccessibility.Lease?
    }

    /// One read. `lease` is the one an earlier pass took; without one, this
    /// pass takes a lease when the app needs its page tree turned on.
    private static func readOnce(_ request: Request, isBrowser: Bool, lease: PageAccessibility.Lease?) -> Pass {
        var pass = Pass(lease: lease)
        let app = AXUIElementCreateApplication(request.pid)
        AXUIElementSetMessagingTimeout(app, urlCallTimeout)
        let readsField = request.includeField
            && !AXAccess.isTerminal(request.bundleID)

        if request.includeWebsite, isBrowser {
            // Chromium names the tab's URL on the window's root view even
            // with its page tree off, so the host usually costs two calls and
            // no side effects.
            pass.host = windowRootHost(app: app)
        }
        // The page tree is only switched on when something needs it: the
        // field's text, or a host the root view did not give.
        if pass.lease == nil, readsField || (request.includeWebsite && pass.host == nil),
           AXAccess.needsPageAccessibility(pid: request.pid, bundleID: request.bundleID) {
            pass.lease = PageAccessibility.shared.acquire(pid: request.pid)
        }
        if request.includeWebsite, isBrowser, pass.host == nil {
            pass.host = webAreaHost(app: app)
        }
        if readsField {
            pass.field = focusedFieldContext(app: app)
        }
        return pass
    }

    // MARK: - Website

    /// Host from the URL Chromium exposes on the focused window's root view
    /// (a direct child of the window). Only direct children are checked: deeper
    /// elements with an AXURL include bookmark buttons and page links.
    private static func windowRootHost(app: AXUIElement) -> String? {
        guard let window = AXAccess.element(app, kAXFocusedWindowAttribute as CFString, timeout: urlCallTimeout),
              let children = AXAccess.copy(window, kAXChildrenAttribute as CFString) as? [AXUIElement] else {
            return nil
        }
        for child in children {
            AXUIElementSetMessagingTimeout(child, urlCallTimeout)
            if let host = host(of: child) {
                return host
            }
        }
        return nil
    }

    /// Host of the AXWebArea holding the keyboard focus, or of the first one
    /// found in the focused window.
    private static func webAreaHost(app: AXUIElement) -> String? {
        let deadline = Date().addingTimeInterval(webAreaSearchBudget)

        // Fast path: when focus is inside the page (a compose box), the web
        // area is an ancestor - a handful of calls instead of a tree search.
        if let focused = AXAccess.element(app, kAXFocusedUIElementAttribute as CFString, timeout: urlCallTimeout) {
            var current: AXUIElement? = focused
            var depth = 0
            while let node = current, depth < 40, Date() < deadline {
                if AXAccess.role(of: node) == "AXWebArea", let host = host(of: node) {
                    return host
                }
                current = AXAccess.element(node, kAXParentAttribute as CFString, timeout: urlCallTimeout)
                depth += 1
            }
        }

        // Breadth-first from the focused window for focus outside the page
        // (address bar, a toolbar button).
        guard let window = AXAccess.element(app, kAXFocusedWindowAttribute as CFString, timeout: urlCallTimeout) else {
            return nil
        }
        var queue: [AXUIElement] = [window]
        var index = 0
        while index < queue.count, index < webAreaSearchMaxElements, Date() < deadline {
            let node = queue[index]
            index += 1
            if AXAccess.role(of: node) == "AXWebArea" {
                if let host = host(of: node) {
                    return host
                }
                continue // Page content never holds the tab's own web area.
            }
            if let children = AXAccess.copy(node, kAXChildrenAttribute as CFString) as? [AXUIElement] {
                for child in children {
                    AXUIElementSetMessagingTimeout(child, urlCallTimeout)
                }
                queue.append(contentsOf: children)
            }
        }
        return nil
    }

    private static func host(of webArea: AXUIElement) -> String? {
        guard let value = AXAccess.copy(webArea, "AXURL" as CFString) else { return nil }
        let url: URL?
        if CFGetTypeID(value) == CFURLGetTypeID() {
            url = (value as! CFURL) as URL
        } else {
            url = (value as? String).flatMap(URL.init(string:))
        }
        guard let url,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        return host
    }

    // MARK: - Field

    private static func focusedFieldContext(app: AXUIElement) -> FieldContext? {
        guard let focused = AXAccess.focusedEditableField(app: app, timeout: fieldCallTimeout),
              let selection = AXAccess.selectedRange(focused) else {
            return nil
        }

        // Prefer fetching just the window around the caret: a long document's
        // full AXValue is an expensive copy, most of it unused.
        if let total = (AXAccess.copy(focused, kAXNumberOfCharactersAttribute as CFString) as? NSNumber)?.intValue,
           selection.location >= 0, selection.location + selection.length <= total {
            let selectionEnd = selection.location + selection.length
            let beforeStart = max(0, selection.location - maxBeforeLength)
            let afterEnd = min(total, selectionEnd + maxAfterLength)
            if let before = AXAccess.string(focused, CFRange(location: beforeStart, length: selection.location - beforeStart)),
               let selected = AXAccess.string(focused, CFRange(location: selection.location, length: min(selection.length, maxSelectedLength))),
               let after = AXAccess.string(focused, CFRange(location: selectionEnd, length: afterEnd - selectionEnd)) {
                return FieldContext(before: before, selected: selected, after: after)
            }
        }

        guard let value = AXAccess.copy(focused, kAXValueAttribute as CFString) as? String else { return nil }
        return split(value as NSString, at: selection)
    }

    /// Splits a full field value around the selection, truncating each part
    /// on composed-character boundaries so no emoji or accent is cut in half.
    private static func split(_ value: NSString, at selection: CFRange) -> FieldContext? {
        let location = selection.location
        let end = location + selection.length
        guard location >= 0, selection.length >= 0, end <= value.length else { return nil }

        func clamp(_ range: NSRange) -> String {
            guard range.length > 0 else { return "" }
            return value.substring(with: value.rangeOfComposedCharacterSequences(for: range))
        }
        let beforeStart = max(0, location - maxBeforeLength)
        let before = clamp(NSRange(location: beforeStart, length: location - beforeStart))
        let selected = clamp(NSRange(location: location, length: min(selection.length, maxSelectedLength)))
        let after = clamp(NSRange(location: end, length: min(value.length - end, maxAfterLength)))
        return FieldContext(before: before, selected: selected, after: after)
    }
}
