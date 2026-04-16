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

    func expandedBody() -> String {
        var result = body
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short

        result = result.replacingOccurrences(of: "{{date}}", with: dateFormatter.string(from: now))
        result = result.replacingOccurrences(of: "{{time}}", with: timeFormatter.string(from: now))

        if result.contains("{{clipboard}}") {
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
