import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var records: [TranscriptionRecord] = []
    @Published private(set) var lastSaveError: Error?
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

    func update(_ record: TranscriptionRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = record
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
        } catch {
            Log.storage.error("Failed to load history.json: \(error.localizedDescription, privacy: .public)")
            StorageQuarantine.quarantine(fileURL, reason: "decode_failed")
            records = []
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        do {
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: .atomic)
            lastSaveError = nil
        } catch {
            Log.storage.error("Failed to save history.json (attempt 1): \(error.localizedDescription, privacy: .public)")
            do {
                let data = try encoder.encode(records)
                try data.write(to: fileURL, options: .atomic)
                lastSaveError = nil
            } catch {
                Log.storage.error("Failed to save history.json (retry): \(error.localizedDescription, privacy: .public)")
                lastSaveError = error
            }
        }
    }
}
