import Foundation

@MainActor
final class DictionaryStore: ObservableObject {
    @Published private(set) var entries: [DictionaryEntry] = []
    @Published private(set) var lastSaveError: Error?
    private let fileURL = Constants.Storage.dictionaryFileURL

    init() {
        load()
    }

    /// Whisper prompt, truncated to a rough token budget. Entries are ordered
    /// by recency (newest first) so the most-used terms survive truncation.
    var promptString: String {
        promptString(maxTokens: Constants.API.whisperPromptMaxTokens)
    }

    func promptString(maxTokens: Int) -> String {
        let sorted = entries.sorted { $0.addedAt > $1.addedAt }
        let formatted = sorted.map { $0.term }
        return TokenBudget.fit(formatted, joiner: ", ", maxTokens: maxTokens)
    }

    /// True when a *different* entry already uses this term (case-insensitive,
    /// trimmed). Drives editor validation and the add/update guards.
    func termExists(_ term: String, excluding id: UUID? = nil) -> Bool {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }
        return entries.contains {
            $0.id != id && $0.term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
        }
    }

    /// Appends unless the term already exists. Returns true when added.
    @discardableResult
    func add(_ entry: DictionaryEntry) -> Bool {
        guard !termExists(entry.term, excluding: entry.id) else { return false }
        var entry = entry
        entry.term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
        entries.append(entry)
        save()
        return true
    }

    @discardableResult
    func update(_ entry: DictionaryEntry) -> Bool {
        guard !termExists(entry.term, excluding: entry.id) else { return false }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            var entry = entry
            entry.term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
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
