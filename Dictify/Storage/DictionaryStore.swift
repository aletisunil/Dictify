import Foundation

@MainActor
final class DictionaryStore: ObservableObject {
    @Published private(set) var entries: [DictionaryEntry] = []
    private let fileURL = Constants.Storage.dictionaryFileURL

    init() {
        load()
    }

    var promptString: String {
        entries.prefix(50).map { entry in
            if let hint = entry.phoneticHint {
                return "\(entry.term) (\(hint))"
            }
            return entry.term
        }.joined(separator: ", ")
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
        } catch {}
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let file = DictionaryFile(terms: entries)
            let data = try encoder.encode(file)
            try data.write(to: fileURL, options: .atomic)
        } catch {}
    }
}
