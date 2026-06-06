import Foundation
import OSLog

/// One unified-log entry reduced to the fields a shareable bundle needs.
struct LogRecord {
    let date: Date
    let category: String
    let level: String
    let message: String
}

/// Reads Dictify's recent `os.Logger` output back out of the unified logging
/// system via `OSLogStore`.
///
/// This works because the app is **not** sandboxed (see `Dictify.entitlements`),
/// so `OSLogStore.local()` can read the current process's own entries. We filter
/// to `Constants.bundleIdentifier` and a bounded time window so collection stays
/// fast and the resulting bundle stays email-sized.
///
/// IMPORTANT: entries returned here are **not** treated as safe to share. A
/// same-process read may return `.private` interpolations unredacted, so every
/// record must pass through `LogRedactor` before it leaves the app. Correctness
/// of the privacy guarantee lives in the redactor, not here.
enum LogCollector {
    /// Collect recent log records for this app, newest-window-first in
    /// chronological order. Never throws — on failure it returns a single
    /// synthetic record so the caller never silently produces an empty bundle.
    static func collect(
        window: TimeInterval = Constants.Diagnostics.captureWindow,
        cap: Int = Constants.Diagnostics.maxEntries
    ) async -> [LogRecord] {
        // OSLogStore reads can be slow; keep them off the main actor.
        await Task.detached(priority: .userInitiated) {
            collectSync(window: window, cap: cap)
        }.value
    }

    private static func collectSync(window: TimeInterval, cap: Int) -> [LogRecord] {
        do {
            let store = try OSLogStore.local()
            let start = store.position(date: Date().addingTimeInterval(-window))
            // Predicate-filter at the store level so we don't enumerate the
            // entire system log just to discard most of it.
            let predicate = NSPredicate(format: "subsystem == %@", Constants.bundleIdentifier)
            let entries = try store.getEntries(at: start, matching: predicate)

            var records: [LogRecord] = []
            for case let entry as OSLogEntryLog in entries {
                records.append(
                    LogRecord(
                        date: entry.date,
                        category: entry.category,
                        level: levelString(entry.level),
                        message: entry.composedMessage
                    )
                )
                if records.count >= cap { break }
            }

            if records.isEmpty {
                return [syntheticRecord("No Dictify log entries found in the last \(Int(window / 60)) minutes.")]
            }
            return records
        } catch {
            return [syntheticRecord("Log collection failed: \(error.localizedDescription)")]
        }
    }

    private static func syntheticRecord(_ message: String) -> LogRecord {
        LogRecord(date: Date(), category: "diagnostics", level: "notice", message: message)
    }

    private static func levelString(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        case .undefined: return "undefined"
        @unknown default: return "unknown"
        }
    }
}
