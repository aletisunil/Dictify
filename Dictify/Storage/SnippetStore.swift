import Foundation

@MainActor
final class SnippetStore: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []
    @Published private(set) var lastSaveError: Error?
    private let fileURL = Constants.Storage.snippetsFileURL

    init() {
        load()
    }

    /// Builds the snippet block injected into the refinement prompt so the model
    /// expands cues — including misheard/reformatted ones the local whole-word
    /// matcher would miss. Bodies are resolved via `expandedBody()` here (on the
    /// main actor) so `{{date}}`/`{{time}}`/`{{clipboard}}` are substituted before
    /// the prompt is sent; the model never has to compute them. Returns "" when no
    /// snippets exist so the prompt's cacheable prefix stays byte-identical.
    func snippetContext() -> String {
        let lines: [String] = snippets.compactMap { snippet in
            let cue = snippet.cue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cue.isEmpty else { return nil }
            // Single-line the body so each snippet stays one prompt line; the model
            // restores any intended line breaks from the body's literal "\n".
            let body = snippet.expandedBody().replacingOccurrences(of: "\n", with: "\\n")
            return "  \"\(cue)\" => \(body)"
        }
        return lines.joined(separator: "\n")
    }

    /// True when a *different* snippet already uses this cue (case-insensitive,
    /// trimmed). Drives editor validation and the add/update guards.
    func cueExists(_ cue: String, excluding id: UUID? = nil) -> Bool {
        let needle = cue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }
        return snippets.contains {
            $0.id != id && $0.cue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
        }
    }

    /// Appends unless the cue already exists. Returns true when added.
    @discardableResult
    func add(_ snippet: Snippet) -> Bool {
        guard !cueExists(snippet.cue, excluding: snippet.id) else { return false }
        var snippet = snippet
        snippet.cue = snippet.cue.trimmingCharacters(in: .whitespacesAndNewlines)
        snippets.append(snippet)
        save()
        return true
    }

    @discardableResult
    func update(_ snippet: Snippet) -> Bool {
        guard !cueExists(snippet.cue, excluding: snippet.id) else { return false }
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            var snippet = snippet
            snippet.cue = snippet.cue.trimmingCharacters(in: .whitespacesAndNewlines)
            snippets[index] = snippet
            save()
        }
        return true
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
