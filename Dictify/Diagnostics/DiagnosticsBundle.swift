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

    /// Present a save panel and write the bundle. Returns the written URL, or
    /// `nil` if the user cancelled or the write failed.
    @MainActor
    static func saveBundle(_ text: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFileName()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            Log.ui.error("Failed to write diagnostics bundle: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Open a pre-filled mail draft to the developer. `mailto:` cannot attach
    /// files, so the caller is expected to have saved + revealed the bundle
    /// first; the body reminds the user to attach it.
    static func composeEmail(bundleURL: URL?) {
        let subject = "Dictify Diagnostics (v\(appVersion))"
        var body = """
        Describe what went wrong here:


        """
        if let bundleURL {
            body += "\n(Please attach the saved log file: \(bundleURL.lastPathComponent))\n"
        }
        let query = "subject=\(encode(subject))&body=\(encode(body))"
        guard let url = URL(string: "mailto:\(Constants.Diagnostics.supportEmail)?\(query)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Helpers

    static func suggestedFileName() -> String {
        let stamp = fileTimestamp(Date())
        return "dictify-logs-\(stamp).txt"
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
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

    private static func lineTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    private static func headerTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }

    private static func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }
}
