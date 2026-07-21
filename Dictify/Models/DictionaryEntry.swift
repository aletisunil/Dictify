import Foundation

struct DictionaryEntry: Codable, Identifiable, Hashable {
    var id: UUID
    var term: String
    var category: String
    var addedAt: Date
    var aliases: [String]
    var useCount: Int
    var lastUsedAt: Date?

    init(
        id: UUID = UUID(),
        term: String,
        category: String = "general",
        addedAt: Date = Date(),
        aliases: [String] = [],
        useCount: Int = 0,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.term = term
        self.category = category
        self.addedAt = addedAt
        self.aliases = aliases
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, term, category, addedAt, aliases, useCount, lastUsedAt
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
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        useCount = try c.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }
}

struct DictionaryFile: Codable {
    var version: Int = 3
    var terms: [DictionaryEntry]
}
