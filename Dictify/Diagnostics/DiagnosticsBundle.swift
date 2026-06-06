import AppKit
import Foundation

/// Assembles collected + redacted log records into a single shareable plaintext
/// document and provides the export actions used by the About tab.
///
/// The bundle is deliberately plaintext: it pastes into an email body, copies to
/// the clipboard, and saves to disk with zero ceremony. A header block carries
/// the environment context a developer needs (app version, OS, device) plus a
/// banner stating the content is redacted.
enum DiagnosticsBundle {
    /// Build the full redacted bundle string. Safe to share by construction —
    /// every body line passes through `LogRedactor`.
    static func build(
        window: TimeInterval = Constants.Diagnostics.captureWindow
    ) async -> String {
        let records = await LogCollector.collect(window: window)
        let redacted = records.map(LogRedactor.redact)
        return format(records: redacted, window: window)
    }

    // MARK: - Formatting

    static func format(records: [LogRecord], window: TimeInterval) -> String {
        var out = header(window: window, count: records.count)
        out += "\n\n"
        if records.isEmpty {
            out += "(no recent log entries)\n"
        } else {
            for record in records {
                out += "\(lineTimestamp(record.date)) [\(record.category)] \(record.level.uppercased())  \(record.message)\n"
            }
        }
        return out
    }

    private static func header(window: TimeInterval, count: Int) -> String {
        """
        # Dictify Diagnostics
        # ---------------------------------------------------------------
        # Logs redacted for sharing — no API keys or dictated text included.
        # ---------------------------------------------------------------
        App:      Dictify \(appVersion) (build \(appBuild))
        macOS:    \(ProcessInfo.processInfo.operatingSystemVersionString)
        Device:   \(deviceModel)
        Window:   last \(Int(window / 60)) min
        Entries:  \(count)
        Captured: \(headerTimestamp(Date()))
        """
    }

    // MARK: - Export actions

    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Open a mail draft to the developer with the bundle **attached**.
    ///
    /// `mailto:` can't carry attachments, so we use `NSSharingService`'s
    /// compose-email service, which takes the file URL as an item and attaches
    /// it for real. The bundle is written to a temp file first (no save panel).
    /// Returns `true` if a draft was opened, `false` if Mail couldn't be reached
    /// (caller should fall back to Copy Logs).
    @MainActor
    static func email(bundle text: String) -> Bool {
        guard let fileURL = writeTempBundle(text) else { return false }
        guard let service = NSSharingService(named: .composeEmail) else { return false }
        service.recipients = [Constants.Diagnostics.supportEmail]
        service.subject = "Dictify Diagnostics (v\(appVersion))"
        let body = "Describe what went wrong here:\n\n\n"
        let items: [Any] = [body, fileURL]
        guard service.canPerform(withItems: items) else { return false }
        service.perform(withItems: items)
        return true
    }

    /// Write the bundle to a uniquely-named file in the temp directory so it can
    /// be attached to an email. Returns `nil` on write failure.
    static func writeTempBundle(_ text: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedFileName())
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            Log.ui.error("Failed to write diagnostics bundle: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Helpers

    static func suggestedFileName() -> String {
        let stamp = fileTimestamp(Date())
        // Short random suffix so two near-simultaneous exports (e.g. Copy then
        // Email within the same second) can't collide on one temp filename.
        let suffix = String(UUID().uuidString.prefix(8))
        return "dictify-logs-\(stamp)-\(suffix).txt"
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private static var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    private static var deviceModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    // Cached, fixed-format formatters. `lineTimestamp` runs once per record (up to
    // `maxEntries`), so allocating a DateFormatter per call is wasteful; POSIX
    // locale keeps the fixed numeric formats stable regardless of user locale.
    private static let lineFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static let fileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    private static let isoFormatter = ISO8601DateFormatter()

    private static func lineTimestamp(_ date: Date) -> String {
        lineFormatter.string(from: date)
    }

    private static func headerTimestamp(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static func fileTimestamp(_ date: Date) -> String {
        fileFormatter.string(from: date)
    }
}
