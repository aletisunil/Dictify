import AppKit
import Foundation
import os

/// Watches the field Dictify just inserted into and reports the corrections
/// the user makes to the inserted words (see `CorrectionLearner`).
///
/// The watch ends when focus moves to another element or app, after
/// `maxDuration`, or when its task is cancelled (the next dictation starts).
/// It then reports what the last read showed. Reads that no longer contain
/// the dictation (a chat field cleared by sending) keep the previous result.
/// Field text never leaves this type; logs carry counts only.
enum CorrectionWatcher {
    struct Target: Sendable {
        let pid: pid_t
        let bundleID: String?
    }

    private static let settleDelay: UInt64 = 400_000_000
    private static let locateRetryDelay: UInt64 = 300_000_000
    /// A cold Chromium needs about 2 s to build a heavy page's tree.
    private static let locateAttempts = 10
    private static let pollInterval: UInt64 = 1_000_000_000
    private static let maxDuration: TimeInterval = 90
    /// Larger documents are not polled: reading them every second costs too
    /// much for a hint.
    private static let maxFieldLength = 50_000
    private static let callTimeout: Float = 0.1

    private static let queue = DispatchQueue(label: "com.dictify.correction-watch", qos: .utility)

    static func watch(_ target: Target, inserted: String) async -> [CorrectionLearner.Correction] {
        guard !AXAccess.isTerminal(target.bundleID) else { return [] }
        do {
            try await Task.sleep(nanoseconds: settleDelay)
        } catch {
            return []
        }

        // Chromium and Electron only expose the field while their page tree
        // is on; the lease keeps it on for the whole watch.
        var lease: PageAccessibility.Lease?
        if AXAccess.needsPageAccessibility(pid: target.pid, bundleID: target.bundleID) {
            lease = await AXAccess.run(on: queue) { PageAccessibility.shared.acquire(pid: target.pid) }
        }
        defer {
            if let lease { PageAccessibility.shared.release(lease) }
        }

        var baseline: Baseline?
        let insertedWords = CorrectionLearner.words(inserted)
        for _ in 0..<locateAttempts {
            baseline = await AXAccess.run(on: queue) { readBaseline(target, insertedWords: insertedWords) }
            if baseline != nil { break }
            do {
                try await Task.sleep(nanoseconds: locateRetryDelay)
            } catch {
                return []
            }
        }
        guard let baseline else {
            Log.pipeline.notice("Correction watch: inserted text not found in the field")
            return []
        }

        Log.pipeline.notice("Correction watch: watching \(baseline.span.count, privacy: .public) inserted word(s)")
        var found: [CorrectionLearner.Correction] = []
        var reason = "timeout"
        let deadline = Date().addingTimeInterval(maxDuration)
        while Date() < deadline {
            let cancelled: Bool
            do {
                try await Task.sleep(nanoseconds: pollInterval)
                cancelled = false
            } catch {
                cancelled = true
            }
            // One more read even when cancelled or focus has moved: the next
            // dictation has not inserted anything yet, and the field can still
            // be read, so this catches an edit made just before moving on.
            let read = await AXAccess.run(on: queue) { readField(target, baseline: baseline) }
            if let words = read.words,
               let corrections = CorrectionLearner.corrections(original: baseline.words, span: baseline.span, edited: words) {
                found = corrections
            }
            if cancelled {
                reason = "next dictation"
                break
            }
            if !read.stillFocused {
                reason = "focus moved"
                break
            }
        }
        Log.pipeline.notice("Correction watch ended (\(reason, privacy: .public)): \(found.count, privacy: .public) correction(s)")
        return found
    }

    // MARK: - Reads (on `queue`)

    private struct Baseline: @unchecked Sendable {
        let field: AXUIElement
        let words: [String]
        let span: Range<Int>
    }

    private static func readBaseline(_ target: Target, insertedWords: [String]) -> Baseline? {
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, callTimeout)
        guard let field = AXAccess.focusedEditableField(app: app, timeout: callTimeout),
              let value = AXAccess.copy(field, kAXValueAttribute as CFString) as? String,
              value.utf16.count <= maxFieldLength else {
            return nil
        }
        let words = CorrectionLearner.words(value)
        var caretWord: Int?
        if let caret = AXAccess.selectedRange(field), caret.location >= 0, caret.location <= value.utf16.count {
            caretWord = CorrectionLearner.words((value as NSString).substring(to: caret.location)).count
        }
        guard let span = CorrectionLearner.locate(insertedWords, in: words, caretWord: caretWord) else { return nil }
        return Baseline(field: field, words: words, span: span)
    }

    private struct FieldRead: Sendable {
        let words: [String]?
        /// False once the user has moved on: another app or another element
        /// in the app has focus, or the field is gone.
        let stillFocused: Bool
    }

    private static func readField(_ target: Target, baseline: Baseline) -> FieldRead {
        AXUIElementSetMessagingTimeout(baseline.field, callTimeout)
        var words: [String]?
        if let value = AXAccess.copy(baseline.field, kAXValueAttribute as CFString) as? String,
           value.utf16.count <= maxFieldLength {
            words = CorrectionLearner.words(value)
        }
        let app = AXUIElementCreateApplication(target.pid)
        let stillFocused = words != nil
            && AXAccess.focusedApplicationPID() == target.pid
            && AXAccess.element(app, kAXFocusedUIElementAttribute as CFString, timeout: callTimeout)
                .map { CFEqual($0, baseline.field) } == true
        return FieldRead(words: words, stillFocused: stillFocused)
    }
}
