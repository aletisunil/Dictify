import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var records: [TranscriptionRecord] = []
    private let fileURL = Constants.Storage.historyFileURL
    private let maxItems = Constants.UI.maxHistoryItems

    init() {
        load()
    }

    func add(_ record: TranscriptionRecord) {
        records.insert(record, at: 0)
        if records.count > maxItems {
            records = Array(records.prefix(maxItems))
        }
        save()
    }

    func clear() {
        records.removeAll()
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
            records = try decoder.decode([TranscriptionRecord].self, from: data)
        } catch {}
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {}
    }
}
