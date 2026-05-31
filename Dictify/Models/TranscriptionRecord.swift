import Foundation

struct TranscriptionRecord: Codable, Identifiable {
    var id: UUID
    var rawText: String
    var refinedText: String
    var date: Date
    var durationSeconds: Double
    /// True once the user has corrected this transcription in the History view.
    var edited: Bool

    init(rawText: String, refinedText: String, durationSeconds: Double) {
        self.id = UUID()
        self.rawText = rawText
        self.refinedText = refinedText
        self.date = Date()
        self.durationSeconds = durationSeconds
        self.edited = false
    }

    // Resilient decoding so that history written by an older app version (which
    // may be missing newer fields) always loads instead of being quarantined.
    // This is what keeps your history intact across upgrades.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        rawText = try c.decodeIfPresent(String.self, forKey: .rawText) ?? ""
        refinedText = try c.decodeIfPresent(String.self, forKey: .refinedText) ?? ""
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        edited = try c.decodeIfPresent(Bool.self, forKey: .edited) ?? false
    }
}
