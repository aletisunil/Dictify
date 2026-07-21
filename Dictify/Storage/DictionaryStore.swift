import Foundation

@MainActor
final class DictionaryStore: ObservableObject {
    @Published private(set) var entries: [DictionaryEntry] = []
    @Published private(set) var lastSaveError: Error?
    private let fileURL: URL

    init(fileURL: URL = Constants.Storage.dictionaryFileURL) {
        self.fileURL = fileURL
        load()
    }

    /// Whisper prompt, truncated to a rough token budget. Entries used by recent
    /// successful transcriptions rank first; creation date breaks unused ties.
    var promptString: String {
        promptString(maxTokens: Constants.API.whisperPromptMaxTokens)
    }

    func promptString(maxTokens: Int) -> String {
        let sorted = entries.sorted {
            let lhsDate = $0.lastUsedAt ?? $0.addedAt
            let rhsDate = $1.lastUsedAt ?? $1.addedAt
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            if $0.useCount != $1.useCount { return $0.useCount > $1.useCount }
            return $0.addedAt > $1.addedAt
        }
        let formatted = sorted.map { $0.term }
        return TokenBudget.fit(formatted, joiner: ", ", maxTokens: maxTokens)
    }

    /// True when a *different* entry already uses this term (case-insensitive,
    /// trimmed). Drives editor validation and the add/update guards.
    func termExists(_ term: String, excluding id: UUID? = nil) -> Bool {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }
        return entries.contains { entry in
            guard entry.id != id else { return false }
            return ([entry.term] + entry.aliases).contains {
                Self.matchKey($0) == needle
            }
        }
    }

    /// True when any proposed alias is already owned by another entry or is
    /// another entry's canonical term. Matching uses the same trimmed,
    /// case-insensitive normalization as deterministic correction.
    func aliasesConflict(_ aliases: [String], excluding id: UUID? = nil) -> Bool {
        let proposed = Set(Self.cleanedAliases(aliases).map(Self.matchKey))
        guard !proposed.isEmpty else { return false }
        return entries.contains { entry in
            guard entry.id != id else { return false }
            let occupied = Set(([entry.term] + entry.aliases).map(Self.matchKey))
            return !proposed.isDisjoint(with: occupied)
        }
    }

    /// Appends unless the term already exists. Returns true when added.
    @discardableResult
    func add(_ entry: DictionaryEntry) -> Bool {
        guard !termExists(entry.term, excluding: entry.id),
              !aliasesConflict(entry.aliases, excluding: entry.id),
              !entry.aliases.contains(where: {
                  Self.matchKey($0) == Self.matchKey(entry.term)
              }) else { return false }
        var entry = entry
        entry.term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.aliases = Self.cleanedAliases(entry.aliases)
        entries.append(entry)
        save()
        return true
    }

    @discardableResult
    func update(_ entry: DictionaryEntry) -> Bool {
        guard !termExists(entry.term, excluding: entry.id),
              !aliasesConflict(entry.aliases, excluding: entry.id),
              !entry.aliases.contains(where: {
                  Self.matchKey($0) == Self.matchKey(entry.term)
              }) else { return false }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            var entry = entry
            entry.term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.aliases = Self.cleanedAliases(entry.aliases)
            entries[index] = entry
            save()
        }
        return true
    }

    func remove(_ entry: DictionaryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func removeAt(_ offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        save()
    }

    /// Applies all alias corrections against the original transcript in a single
    /// pass. Replacements are never rescanned, so one dictionary rule cannot
    /// recursively trigger another. Canonical hits also update prompt recency.
    func applyCorrections(to text: String) -> String {
        struct Candidate {
            let alias: String
            let replacement: String
            let entryID: UUID
        }

        var candidateByKey: [String: Candidate] = [:]
        for entry in entries {
            for alias in Self.cleanedAliases(entry.aliases) {
                let key = Self.matchKey(alias)
                guard key != Self.matchKey(entry.term), candidateByKey[key] == nil else { continue }
                candidateByKey[key] = Candidate(alias: alias, replacement: entry.term, entryID: entry.id)
            }
        }

        let candidates = candidateByKey.values.sorted { $0.alias.count > $1.alias.count }
        var matchedEntryIDs = Self.canonicalMatches(in: text, entries: entries)
        guard !candidates.isEmpty else {
            recordUsage(for: matchedEntryIDs)
            return text
        }

        let alternatives = candidates
            .map { NSRegularExpression.escapedPattern(for: $0.alias) }
            .joined(separator: "|")
        let pattern = "(?<![\\p{L}\\p{N}_])(?:\(alternatives))(?![\\p{L}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            recordUsage(for: matchedEntryIDs)
            return text
        }

        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else {
            recordUsage(for: matchedEntryIDs)
            return text
        }

        var output = ""
        var cursor = 0
        for match in matches {
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let heard = source.substring(with: match.range)
            if let candidate = candidateByKey[Self.matchKey(heard)] {
                output += candidate.replacement
                matchedEntryIDs.insert(candidate.entryID)
            } else {
                output += heard
            }
            cursor = NSMaxRange(match.range)
        }
        output += source.substring(from: cursor)
        recordUsage(for: matchedEntryIDs)
        return output
    }

    private func recordUsage(for ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let now = Date()
        for index in entries.indices where ids.contains(entries[index].id) {
            entries[index].useCount += 1
            entries[index].lastUsedAt = now
        }
        save()
    }

    private static func canonicalMatches(in text: String, entries: [DictionaryEntry]) -> Set<UUID> {
        let sourceRange = NSRange(text.startIndex..., in: text)
        return Set(entries.compactMap { entry in
            let escaped = NSRegularExpression.escapedPattern(for: entry.term)
            let pattern = "(?<![\\p{L}\\p{N}_])\(escaped)(?![\\p{L}\\p{N}_])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  regex.firstMatch(in: text, range: sourceRange) != nil else { return nil }
            return entry.id
        })
    }

    private static func cleanedAliases(_ aliases: [String]) -> [String] {
        var seen: Set<String> = []
        return aliases.compactMap { alias in
            let cleaned = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = matchKey(cleaned)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return cleaned
        }
    }

    private static func matchKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            entries = Self.defaultEntries()
            save()
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(DictionaryFile.self, from: data)
            entries = file.terms
        } catch {
            Log.storage.error("Failed to load dictionary.json: \(error.localizedDescription, privacy: .public)")
            StorageQuarantine.quarantine(fileURL, reason: "decode_failed")
            entries = []
        }
    }

    private static func defaultEntries() -> [DictionaryEntry] {
        [
            DictionaryEntry(term: "John Doe", category: "name"),
            DictionaryEntry(term: "Dictify", category: "brand"),
            DictionaryEntry(term: "macOS", category: "brand"),
            DictionaryEntry(term: "GitHub", category: "brand"),
            DictionaryEntry(term: "Kubernetes", category: "tech"),
            DictionaryEntry(term: "Groq", category: "brand")
        ]
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let file = DictionaryFile(terms: entries)

        do {
            let data = try encoder.encode(file)
            try data.write(to: fileURL, options: .atomic)
            lastSaveError = nil
        } catch {
            Log.storage.error("Failed to save dictionary.json (attempt 1): \(error.localizedDescription, privacy: .public)")
            do {
                let data = try encoder.encode(file)
                try data.write(to: fileURL, options: .atomic)
                lastSaveError = nil
            } catch {
                Log.storage.error("Failed to save dictionary.json (retry): \(error.localizedDescription, privacy: .public)")
                lastSaveError = error
            }
        }
    }
}
