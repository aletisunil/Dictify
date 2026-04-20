import Foundation

@MainActor
final class SnippetStore: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []
    @Published private(set) var lastSaveError: Error?
    private let fileURL = Constants.Storage.snippetsFileURL

    init() {
        load()
    }

    /// Snippet context for the Llama refinement prompt. Truncated to a rough
    /// token budget (recency-sorted: most recently created survives).
    var snippetContext: String {
        snippetContext(maxTokens: Constants.API.snippetContextMaxTokens)
    }

    func snippetContext(maxTokens: Int) -> String {
        guard !snippets.isEmpty else { return "No snippets defined." }
        let sorted = snippets.sorted { $0.createdAt > $1.createdAt }
        let formatted = sorted.map { "When the user says \"\($0.cue)\", replace it with: \($0.expandedBody())" }
        return TokenBudget.fit(formatted, joiner: "\n", maxTokens: maxTokens)
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
