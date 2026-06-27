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
    /// in `text` with its expanded body. Pure local string work — no model.
    ///
    /// All cues are matched against the *original* text in a single scan and the
    /// hits are spliced in one pass. Inserted bodies are never re-scanned, so a
    /// cue can't expand inside another snippet's freshly-inserted body. On
    /// overlap the longer cue wins (then the earlier one); shorter losers are
    /// dropped so each character of the original is expanded at most once.
    func expand(in text: String) -> String {
        guard !snippets.isEmpty else { return text }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        // Collect every candidate match across all snippets.
        struct Hit { let range: NSRange; let body: String; let cueLength: Int }
        var hits: [Hit] = []
        for snippet in snippets {
            let cue = snippet.cue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cue.isEmpty else { continue }
            // (?i) case-insensitive; \w lookarounds give whole-word matching
            // without consuming surrounding punctuation/whitespace.
            let pattern = "(?i)(?<!\\w)\(NSRegularExpression.escapedPattern(for: cue))(?!\\w)"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let body = snippet.expandedBody()
            for match in regex.matches(in: text, range: fullRange) {
                hits.append(Hit(range: match.range, body: body, cueLength: cue.count))
            }
        }
        guard !hits.isEmpty else { return text }

        // Resolve overlaps: sort by start, then prefer the longer cue. Walk
        // left-to-right keeping only hits that start past the last kept hit's end.
        hits.sort {
            $0.range.location != $1.range.location
                ? $0.range.location < $1.range.location
                : $0.cueLength > $1.cueLength
        }
        var chosen: [Hit] = []
        var nextStart = 0
        for hit in hits where hit.range.location >= nextStart {
            chosen.append(hit)
            nextStart = hit.range.location + hit.range.length
        }

        // Splice right-to-left so earlier ranges stay valid as we mutate.
        let result = NSMutableString(string: text)
        for hit in chosen.reversed() {
            result.replaceCharacters(in: hit.range, with: hit.body)
        }
        return result as String
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
