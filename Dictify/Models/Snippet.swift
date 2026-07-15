import Foundation
import AppKit

struct Snippet: Codable, Identifiable, Hashable {
    var id: UUID
    var cue: String
    var body: String
    var category: String
    var variables: [String]
    var createdAt: Date

    init(id: UUID = UUID(), cue: String, body: String, category: String = "general", variables: [String] = []) {
        self.id = id
        self.cue = cue
        self.body = body
        self.category = category
        self.variables = variables
        self.createdAt = Date()
    }

    /// Resolves `{{date}}`/`{{time}}` and, when `resolvingClipboard` is true,
    /// `{{clipboard}}`. Pass `resolvingClipboard: false` for any text that will
    /// be sent over the network — the clipboard must never leave the Mac, so
    /// the placeholder is kept literal and substituted locally afterwards.
    func expandedBody(resolvingClipboard: Bool = true) -> String {
        var result = body
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short

        result = result.replacingOccurrences(of: "{{date}}", with: dateFormatter.string(from: now))
        result = result.replacingOccurrences(of: "{{time}}", with: timeFormatter.string(from: now))

        if resolvingClipboard && result.contains("{{clipboard}}") {
            let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
            result = result.replacingOccurrences(of: "{{clipboard}}", with: clipboard)
        }

        return result
    }
}

struct SnippetFile: Codable {
    var version: Int = 1
    var snippets: [Snippet]
}
