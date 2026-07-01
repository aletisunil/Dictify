import Foundation

struct DictionaryEntry: Codable, Identifiable, Hashable {
    var id: UUID
    var term: String
    var category: String
    var addedAt: Date

    init(id: UUID = UUID(), term: String, category: String = "general") {
        self.id = id
        self.term = term
        self.category = category
        self.addedAt = Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id, term, category, addedAt
    }

    // Custom decode so older dictionary.json files still load cleanly — missing
    // fields fall back to sensible defaults rather than throwing and quarantining
    // the whole file. Any legacy `source`/`phoneticHint` keys are simply ignored.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        term = try c.decode(String.self, forKey: .term)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "general"
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
    }
}

struct DictionaryFile: Codable {
    var version: Int = 2
    var terms: [DictionaryEntry]
}
