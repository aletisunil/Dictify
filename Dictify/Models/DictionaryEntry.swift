import Foundation

struct DictionaryEntry: Codable, Identifiable, Hashable {
    var id: UUID
    var term: String
    var category: String
    var phoneticHint: String?
    var addedAt: Date
    var source: EntrySource

    enum EntrySource: String, Codable {
        case manual
        case autoLearned = "auto_learned"
    }

    init(id: UUID = UUID(), term: String, category: String = "general", phoneticHint: String? = nil, source: EntrySource = .manual) {
        self.id = id
        self.term = term
        self.category = category
        self.phoneticHint = phoneticHint
        self.addedAt = Date()
        self.source = source
    }
}

struct DictionaryFile: Codable {
    var version: Int = 1
    var terms: [DictionaryEntry]
}
