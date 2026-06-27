import Foundation

/// How a dictionary entry came to exist. `learned` entries are auto-added by the
/// correction monitor when the user fixes a mis-transcribed word in another app.
enum DictionarySource: String, Codable {
    case manual
    case learned
}

struct DictionaryEntry: Codable, Identifiable, Hashable {
    var id: UUID
    var term: String
    var category: String
    var phoneticHint: String?
    var addedAt: Date
    var source: DictionarySource

    init(id: UUID = UUID(), term: String, category: String = "general", phoneticHint: String? = nil, source: DictionarySource = .manual) {
        self.id = id
        self.term = term
        self.category = category
        self.phoneticHint = phoneticHint
        self.addedAt = Date()
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, term, category, phoneticHint, addedAt, source
    }

    // Custom decode so dictionary.json written before `source` existed still
    // loads cleanly — missing fields fall back to sensible defaults rather than
    // throwing and quarantining the whole file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        term = try c.decode(String.self, forKey: .term)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "general"
        phoneticHint = try c.decodeIfPresent(String.self, forKey: .phoneticHint)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        source = try c.decodeIfPresent(DictionarySource.self, forKey: .source) ?? .manual
    }
}

struct DictionaryFile: Codable {
    var version: Int = 2
    var terms: [DictionaryEntry]
}
