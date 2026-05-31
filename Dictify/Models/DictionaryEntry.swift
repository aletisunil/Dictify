import Foundation

struct DictionaryEntry: Codable, Identifiable, Hashable {
    var id: UUID
    var term: String
    var category: String
    var phoneticHint: String?
    var addedAt: Date

    init(id: UUID = UUID(), term: String, category: String = "general", phoneticHint: String? = nil) {
        self.id = id
        self.term = term
        self.category = category
        self.phoneticHint = phoneticHint
        self.addedAt = Date()
    }
}

struct DictionaryFile: Codable {
    var version: Int = 1
    var terms: [DictionaryEntry]
}
