import Foundation

@MainActor
final class SnippetStore: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []
    private let fileURL = Constants.Storage.snippetsFileURL

    init() {
        load()
    }

    var snippetContext: String {
        guard !snippets.isEmpty else { return "No snippets defined." }
        return snippets.map { "When the user says \"\($0.cue)\", replace it with: \($0.expandedBody())" }
            .joined(separator: "\n")
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
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(SnippetFile.self, from: data)
            snippets = file.snippets
        } catch {}
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let file = SnippetFile(snippets: snippets)
            let data = try encoder.encode(file)
            try data.write(to: fileURL, options: .atomic)
        } catch {}
    }
}
