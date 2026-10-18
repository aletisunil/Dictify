import Foundation

struct DictionaryEntry: Codable, Identifiable, Hashable {
    enum Source: String, Codable {
        case manual
        /// Added because the user corrected a dictation into this term.
        case learned
    }

    /// A transcription the user corrected into `term` ("Cuber Netties" for
    /// "Kubernetes"), so the next dictation can be fixed before it is shown.
    struct HeardAs: Codable, Hashable {
        var text: String
        /// Safe to replace automatically wherever it appears: it contains a
        /// word the spell checker rejects, so it is not a real word that could
        /// mean something else ("cloud" must stay a hint for "Claude").
        var autoReplace: Bool
    }

    var id: UUID
    var term: String
    var category: String
    var addedAt: Date
    var source: Source
    var heardAs: [HeardAs]

    static let maxHeardAs = 5

    init(id: UUID = UUID(), term: String, category: String = "general", source: Source = .manual, heardAs: [HeardAs] = []) {
        self.id = id
        self.term = term
        self.category = category
        self.addedAt = Date()
        self.source = source
        self.heardAs = heardAs
    }

    private enum CodingKeys: String, CodingKey {
        case id, term, category, addedAt, source, heardAs
    }

    // Custom decode so older dictionary.json files still load cleanly — missing
    // fields fall back to sensible defaults rather than throwing and quarantining
    // the whole file. A legacy `phoneticHint` key is simply ignored.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        term = try c.decode(String.self, forKey: .term)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "general"
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        // A legacy free-form `source` string decodes as manual.
        source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? .manual
        heardAs = (try? c.decodeIfPresent([HeardAs].self, forKey: .heardAs)) ?? []
    }
}

/// How often a term shows up in inserted text. Ranks the size-limited Whisper
/// prompt, so terms in use are not pushed out by new ones. Kept apart from
/// `DictionaryEntry` because it changes on most dictations, while an entry
/// changes only when the user or learning edits it.
struct TermUsage: Codable, Hashable {
    var lastUsed: Date
    var count: Int
}

/// A dissimilar correction seen once, waiting for the user to make it again
/// (see `CorrectionLearner.assess`). Never used for transcription or
/// refinement, and not shown in the dictionary.
struct PendingCorrection: Codable, Hashable {
    var term: String
    var heard: String
    var autoReplace: Bool
    var seenAt: Date
}

struct DictionaryFile: Codable {
    var version: Int = 3
    var terms: [DictionaryEntry]
    /// Keyed by entry ID (`uuidString`).
    var usage: [String: TermUsage] = [:]
    var pending: [PendingCorrection] = []

    init(terms: [DictionaryEntry], usage: [String: TermUsage], pending: [PendingCorrection]) {
        self.terms = terms
        self.usage = usage
        self.pending = pending
    }

    private enum CodingKeys: String, CodingKey {
        case version, terms, usage, pending
    }

    // Files from before learning have only `version` and `terms`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 3
        terms = try c.decode([DictionaryEntry].self, forKey: .terms)
        usage = (try? c.decodeIfPresent([String: TermUsage].self, forKey: .usage)) ?? [:]
        pending = (try? c.decodeIfPresent([PendingCorrection].self, forKey: .pending)) ?? []
    }
}
