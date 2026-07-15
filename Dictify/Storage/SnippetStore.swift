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
    /// matcher would miss. `{{date}}`/`{{time}}` are resolved here (on the main
    /// actor) so the model never has to compute them; `{{clipboard}}` is kept as
    /// a literal placeholder because clipboard contents must never be sent to
    /// the API — the pipeline substitutes it locally after refinement. Returns
    /// "" when no snippets exist so the prompt's cacheable prefix stays
    /// byte-identical.
    func snippetContext() -> String {
        let lines: [String] = snippets.compactMap { snippet in
            let cue = snippet.cue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cue.isEmpty else { return nil }
            // Single-line the body so each snippet stays one prompt line; the model
            // restores any intended line breaks from the body's literal "\n".
            let body = snippet.expandedBody(resolvingClipboard: false)
                .replacingOccurrences(of: "\n", with: "\\n")
            return "  \"\(cue)\" => \(body)"
        }
        return lines.joined(separator: "\n")
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
    /// (or when refinement is disabled/failed). Matches cues against windows
    /// of 1–4 consecutive words, comparing case-insensitively with spaces and
    /// punctuation stripped — so cue "pasteclip" matches "paste clip",
    /// "Paste Clip.", or "paste-clip". Whole-word only: a cue never matches
    /// inside a longer word. Punctuation around the matched window is
    /// preserved. Single pass over `text`: spliced bodies are never rescanned,
    /// so one snippet's body can't trigger another snippet's cue.
    ///
    /// `skippingCuesEmbeddedInBodies` guards the post-refinement path: once the
    /// model may have spliced bodies into the text, a cue that also occurs
    /// inside some snippet's body is indistinguishable from expanded output,
    /// and expanding it again would duplicate the body. Such cues are left to
    /// the model; cues occurring in no body are safe to expand.
    func expandCues(in text: String, skippingCuesEmbeddedInBodies: Bool = false) -> String {
        // First snippet wins when two cues normalize identically (the editor
        // only blocks exact-duplicate cues, not e.g. "paste-clip" vs "pasteclip").
        var bodyByCue: [String: String] = [:]
        for snippet in snippets {
            let cueNorm = Self.normalizeForCueMatch(snippet.cue)
            guard !cueNorm.isEmpty, bodyByCue[cueNorm] == nil else { continue }
            bodyByCue[cueNorm] = snippet.expandedBody()
        }
        if skippingCuesEmbeddedInBodies {
            let bodies = Array(bodyByCue.values)
            bodyByCue = bodyByCue.filter { cueNorm, _ in
                !bodies.contains { Self.cueOccurs(cueNorm, in: $0) }
            }
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

    /// Whether any snippet cue window-matches in `text` (same rules as
    /// `expandCues`). Cheap local pre-check the pipeline uses on short
    /// transcripts to decide whether the refinement model is still needed
    /// for cue expansion.
    func containsCue(in text: String) -> Bool {
        var cues: [String: String] = [:]
        for snippet in snippets {
            let cueNorm = Self.normalizeForCueMatch(snippet.cue)
            guard !cueNorm.isEmpty else { continue }
            cues[cueNorm] = ""
        }
        guard !cues.isEmpty else { return false }
        return !Self.cueMatches(in: Self.tokenize(text), cues: cues).isEmpty
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
    /// 1–4 consecutive tokens whose joined normalized text equals a key of
    /// `cues` (normalized cue → body). At a given position the longest
    /// matching cue wins, and the narrowest window for that cue is kept so
    /// trailing punctuation-only tokens aren't swallowed.
    private static func cueMatches(
        in tokens: [Token], cues: [String: String]
    ) -> [(start: Int, length: Int, body: String)] {
        let maxWindow = 4
        let maxCueLength = cues.keys.map(\.count).max() ?? 0
        var matches: [(start: Int, length: Int, body: String)] = []
        var i = 0
        while i < tokens.count {
            var best: (length: Int, joinedCount: Int, body: String)?
            var joined = ""
            for len in 1...maxWindow where i + len <= tokens.count {
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

    /// Whether the cue window-matches anywhere in `text` (same matching rules
    /// as `expandCues`).
    private static func cueOccurs(_ normalizedCue: String, in text: String) -> Bool {
        !cueMatches(in: tokenize(text), cues: [normalizedCue: ""]).isEmpty
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
