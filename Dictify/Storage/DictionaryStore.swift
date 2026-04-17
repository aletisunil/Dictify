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
        let formatted: [String] = sorted.map { entry in
            if let hint = entry.phoneticHint {
                return "\(entry.term) (\(hint))"
            }
            return entry.term
        }
        return TokenBudget.fit(formatted, joiner: ", ", maxTokens: maxTokens)
    }

    func add(_ entry: DictionaryEntry) {
        entries.append(entry)
        save()
    }

    func update(_ entry: DictionaryEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
            save()
        }
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
