import Foundation

struct TranscriptionRecord: Codable, Identifiable {
    var id: UUID
    var rawText: String
    var refinedText: String
    var date: Date
    var durationSeconds: Double

    init(rawText: String, refinedText: String, durationSeconds: Double) {
        self.id = UUID()
        self.rawText = rawText
        self.refinedText = refinedText
        self.date = Date()
        self.durationSeconds = durationSeconds
    }
}
