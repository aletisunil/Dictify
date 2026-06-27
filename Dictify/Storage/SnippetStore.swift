import Foundation

@MainActor
final class SnippetStore: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []
    @Published private(set) var lastSaveError: Error?
    private let fileURL = Constants.Storage.snippetsFileURL

    init() {
        load()
    }

    /// Deterministically replaces each snippet cue (whole-word, case-insensitive)
    /// in `text` with its expanded body. Longest cues first so a short cue can't
    /// match inside a longer cue's text. Pure local string work — no model.
    func expand(in text: String) -> String {
        guard !snippets.isEmpty else { return text }
        var result = text
        let sorted = snippets.sorted { $0.cue.count > $1.cue.count }
        for snippet in sorted {
            let cue = snippet.cue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cue.isEmpty else { continue }
            // (?i) case-insensitive; \w lookarounds give whole-word matching
            // without consuming surrounding punctuation/whitespace.
            let pattern = "(?i)(?<!\\w)\(NSRegularExpression.escapedPattern(for: cue))(?!\\w)"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            // escapedTemplate so bodies containing $ or \ aren't read as refs.
            let template = NSRegularExpression.escapedTemplate(for: snippet.expandedBody())
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    func add(_ snippet: Snippet) {
        snippets.append(snippet)
        save()
    }

    func update(_ snippet: Snippet) {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = snippet
            save()
        }
    }

    func remove(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        save()
    }

    func removeAt(_ offsets: IndexSet) {
        snippets.remove(atOffsets: offsets)
        save()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            snippets = Self.defaultSnippets()
            save()
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(SnippetFile.self, from: data)
            snippets = file.snippets
        } catch {
            Log.storage.error("Failed to load snippets.json: \(error.localizedDescription, privacy: .public)")
            StorageQuarantine.quarantine(fileURL, reason: "decode_failed")
            snippets = []
        }
    }

    private static func defaultSnippets() -> [Snippet] {
        [
            Snippet(
                cue: "signoff",
                body: "Thanks,\nJohn Doe",
                category: "email"
            ),
            Snippet(
                cue: "myemail",
                body: "john.doe@example.com",
                category: "contact"
            ),
            Snippet(
                cue: "todaysdate",
                body: "{{date}}",
                category: "general"
            ),
            Snippet(
                cue: "pasteclip",
                body: "{{clipboard}}",
                category: "general"
            )
        ]
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let file = SnippetFile(snippets: snippets)

        do {
            let data = try encoder.encode(file)
            try data.write(to: fileURL, options: .atomic)
            lastSaveError = nil
        } catch {
            Log.storage.error("Failed to save snippets.json (attempt 1): \(error.localizedDescription, privacy: .public)")
            do {
                let data = try encoder.encode(file)
                try data.write(to: fileURL, options: .atomic)
                lastSaveError = nil
            } catch {
                Log.storage.error("Failed to save snippets.json (retry): \(error.localizedDescription, privacy: .public)")
                lastSaveError = error
            }
        }
    }
}
