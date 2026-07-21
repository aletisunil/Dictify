import Foundation

@MainActor
final class SnippetStore: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []
    @Published private(set) var lastSaveError: Error?
    private let fileURL: URL

    init(fileURL: URL = Constants.Storage.snippetsFileURL) {
        self.fileURL = fileURL
        load()
    }

    /// Trimmed, non-empty cues — appended to the Whisper prompt so cues are
    /// transcribed the way the user typed them ("pasteclip" stays one word
    /// instead of splitting into "paste clip").
    var cueTerms: [String] {
        snippets.compactMap {
            let cue = $0.cue.trimmingCharacters(in: .whitespacesAndNewlines)
            return cue.isEmpty ? nil : cue
        }
    }

    /// Deterministic fallback expansion for cues the refinement model missed
    /// (or when refinement is disabled/failed). Matches cues against consecutive
    /// words, comparing case-insensitively with spaces and
    /// punctuation stripped — so cue "pasteclip" matches "paste clip",
    /// "Paste Clip.", or "paste-clip". Whole-word only: a cue never matches
    /// inside a longer word. Punctuation around the matched window is
    /// preserved. Single pass over `text`: spliced bodies are never rescanned,
    /// so one snippet's body can't trigger another snippet's cue.
    ///
    func expandCues(in text: String) -> String {
        var bodyByCue: [String: String] = [:]
        for snippet in snippets {
            let cueNorm = Self.normalizeForCueMatch(snippet.cue)
            guard !cueNorm.isEmpty, bodyByCue[cueNorm] == nil else { continue }
            bodyByCue[cueNorm] = snippet.expandedBody()
        }
        guard !bodyByCue.isEmpty else { return text }

        let tokens = Self.tokenize(text)
        var pieces: [String] = []
        var cursor = text.startIndex
        for match in Self.cueMatches(in: tokens, cues: bodyByCue) {
            let first = tokens[match.start].range
            let last = tokens[match.start + match.length - 1].range
            // Keep punctuation hugging the window ("Paste clip." → body + ".").
            let leading = text[first].prefix { !$0.isLetter && !$0.isNumber }
            let trailing = text[last].reversed().prefix { !$0.isLetter && !$0.isNumber }
            pieces.append(String(text[cursor..<first.lowerBound]))
            pieces.append(String(leading) + match.body + String(trailing.reversed()))
            cursor = last.upperBound
        }
        pieces.append(String(text[cursor...]))
        return pieces.joined()
    }

    /// Lowercases and strips everything but letters/digits, so word splits and
    /// punctuation don't break the comparison.
    private static func normalizeForCueMatch(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private struct Token {
        let range: Range<String.Index>
        let norm: String
    }

    /// Whitespace-separated runs with their normalized forms.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace {
                end = text.index(after: end)
            }
            tokens.append(Token(range: index..<end, norm: normalizeForCueMatch(String(text[index..<end]))))
            index = end
        }
        return tokens
    }

    /// Non-overlapping cue matches, earliest-first. Each match is a window of
    /// consecutive tokens whose joined normalized text equals a key of
    /// `cues` (normalized cue → body). At a given position the longest
    /// matching cue wins, and the narrowest window for that cue is kept so
    /// trailing punctuation-only tokens aren't swallowed.
    private static func cueMatches(
        in tokens: [Token], cues: [String: String]
    ) -> [(start: Int, length: Int, body: String)] {
        let maxCueLength = cues.keys.map(\.count).max() ?? 0
        var matches: [(start: Int, length: Int, body: String)] = []
        var i = 0
        while i < tokens.count {
            var best: (length: Int, joinedCount: Int, body: String)?
            var joined = ""
            let remainingTokenCount = tokens.count - i
            for len in 1...remainingTokenCount {
                joined += tokens[i + len - 1].norm
                // Strict `>` so a punctuation-only token that doesn't grow
                // `joined` can't widen an already-found match.
                if joined.count > (best?.joinedCount ?? 0), let body = cues[joined] {
                    best = (len, joined.count, body)
                }
                // Wider windows only grow `joined` — nothing further can match.
                if joined.count >= maxCueLength { break }
            }
            if let best {
                matches.append((i, best.length, best.body))
                i += best.length
            } else {
                i += 1
            }
        }
        return matches
    }

    /// True when a different snippet uses an equivalent cue under the same
    /// normalization as runtime matching. This prevents ambiguous pairs such as
    /// `pasteclip` and `paste-clip`, where the old behavior silently chose first.
    func cueExists(_ cue: String, excluding id: UUID? = nil) -> Bool {
        let needle = Self.normalizeForCueMatch(cue)
        guard !needle.isEmpty else { return false }
        return snippets.contains {
            $0.id != id && Self.normalizeForCueMatch($0.cue) == needle
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
