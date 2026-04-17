import Foundation

/// Moves a malformed JSON file aside so we return a clean state without
/// destroying user data. Callers should log the reason.
enum StorageQuarantine {
    static func quarantine(_ url: URL, reason: String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let quarantineURL = url.deletingPathExtension()
            .appendingPathExtension("\(url.pathExtension).corrupt-\(timestamp)")
        do {
            try FileManager.default.moveItem(at: url, to: quarantineURL)
            Log.storage.notice("Quarantined \(url.lastPathComponent, privacy: .public) → \(quarantineURL.lastPathComponent, privacy: .public) (reason: \(reason, privacy: .public))")
        } catch {
            Log.storage.error("Failed to quarantine \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
