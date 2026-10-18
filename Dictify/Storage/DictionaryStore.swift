import Foundation

@MainActor
final class DictionaryStore: ObservableObject {
    @Published private(set) var entries: [DictionaryEntry] = []
    @Published private(set) var lastSaveError: Error?
    /// Not published: usage changes on most dictations and no view shows it.
    private var usage: [UUID: TermUsage] = [:]
    private var pending: [PendingCorrection] = []
    /// Usage-only changes are written in batches; see `recordUse`.
    private var usageSaveTask: Task<Void, Never>?
    private let fileURL = Constants.Storage.dictionaryFileURL

    private static let usageSaveDelay: UInt64 = 30_000_000_000
    private static let maxPending = 50
    private static let pendingLifetime: TimeInterval = 30 * 24 * 60 * 60

    init() {
        load()
    }

    /// Whisper prompt, truncated to a rough token budget. Entries are ordered
    /// by last use (or addition), so terms in use survive truncation.
    var promptString: String {
        promptString(maxTokens: Constants.API.whisperPromptMaxTokens)
    }

    func promptString(maxTokens: Int) -> String {
        TokenBudget.fit(rankedEntries.map(\.term), joiner: ", ", maxTokens: maxTokens)
    }

    /// The refinement model's DICTIONARY block: like the Whisper prompt, plus
    /// how each term was misheard before, so the model can fix forms that are
    /// real words and therefore never replaced automatically ("cloud").
    var refinementContext: String {
        let lines = rankedEntries.map { entry -> String in
            guard !entry.heardAs.isEmpty else { return entry.term }
            let heard = entry.heardAs.map { "\"\($0.text)\"" }.joined(separator: ", ")
            return "\(entry.term) (misheard before as \(heard))"
        }
        return TokenBudget.fit(lines, joiner: "\n", maxTokens: Constants.API.whisperPromptMaxTokens * 2)
    }

    private var rankedEntries: [DictionaryEntry] {
        func rank(_ entry: DictionaryEntry) -> (date: Date, count: Int) {
            let use = usage[entry.id]
            return (max(use?.lastUsed ?? entry.addedAt, entry.addedAt), use?.count ?? 0)
        }
        return entries.sorted { lhs, rhs in
            let l = rank(lhs), r = rank(rhs)
            return l.date != r.date ? l.date > r.date : l.count > r.count
        }
    }

    // MARK: - Learning from corrections

    /// Records that the user corrected `heard` into `term`. An existing term
    /// (any case) gains the misheard form; otherwise a learned entry is added.
    /// Returns false when nothing changed.
    @discardableResult
    func learn(term: String, heard: String, autoReplace: Bool) -> Bool {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !heard.isEmpty, term != heard else { return false }
        let form = DictionaryEntry.HeardAs(text: heard, autoReplace: autoReplace)

        if let index = entries.firstIndex(where: { $0.term.lowercased() == term.lowercased() }) {
            guard !entries[index].heardAs.contains(where: { $0.text.lowercased() == heard.lowercased() }) else {
                return false
            }
            entries[index].heardAs.append(form)
            entries[index].heardAs = Array(entries[index].heardAs.suffix(DictionaryEntry.maxHeardAs))
        } else {
            entries.append(DictionaryEntry(term: term, source: .learned, heardAs: [form]))
        }
        save()
        return true
    }

    /// Learns a correction the second time the user makes it (see
    /// `CorrectionLearner.Decision.confirmFirst`); the first time it is only
    /// remembered. Returns true when it was learned.
    @discardableResult
    func learnWhenConfirmed(term: String, heard: String, autoReplace: Bool) -> Bool {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !heard.isEmpty, term != heard else { return false }
        let now = Date()
        pending.removeAll { now.timeIntervalSince($0.seenAt) > Self.pendingLifetime }
        let matches: (PendingCorrection) -> Bool = {
            $0.term.lowercased() == term.lowercased() && $0.heard.lowercased() == heard.lowercased()
        }
        if pending.contains(where: matches) {
            pending.removeAll(where: matches)
            if learn(term: term, heard: heard, autoReplace: autoReplace) { return true }
            save()
            return false
        }
        pending.append(PendingCorrection(term: term, heard: heard, autoReplace: autoReplace, seenAt: now))
        pending = Array(pending.suffix(Self.maxPending))
        save()
        return false
    }

    /// Replaces misheard forms that are safe to replace (see
    /// `DictionaryEntry.HeardAs.autoReplace`) with their terms. Whole words
    /// only, case-insensitive, in one pass, so a replacement is never
    /// rescanned and one learned form cannot feed another.
    func applyLearnedReplacements(to text: String) -> String {
        guard let replacements = learnedReplacements, !text.isEmpty else { return text }
        let range = NSRange(text.startIndex..., in: text)
        var result = ""
        var cursor = text.startIndex
        for match in replacements.regex.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let key = Self.replacementKey(String(text[matchRange]))
            guard let term = replacements.terms[key] else { continue }
            result += text[cursor..<matchRange.lowerBound]
            result += term
            cursor = matchRange.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// Marks every term that appears in inserted text as used now. Written
    /// to disk at most every `usageSaveDelay`, with any other save, or by
    /// `flush` at quit: losing a few counts in a crash costs nothing.
    func recordUse(in text: String) {
        let words = Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let lowered = text.lowercased()
        let now = Date()
        var changed = false
        for entry in entries {
            let term = entry.term.lowercased()
            let parts = term.split { !$0.isLetter && !$0.isNumber }
            guard !parts.isEmpty else { continue }
            let present = parts.count == 1 ? words.contains(String(parts[0])) : lowered.contains(term)
            if present {
                usage[entry.id] = TermUsage(lastUsed: now, count: (usage[entry.id]?.count ?? 0) + 1)
                changed = true
            }
        }
        if changed, usageSaveTask == nil {
            usageSaveTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.usageSaveDelay)
                guard !Task.isCancelled else { return }
                self?.save()
            }
        }
    }

    /// Writes a pending usage save now. Call at quit.
    func flush() {
        if usageSaveTask != nil { save() }
    }

    private struct Replacements {
        let regex: NSRegularExpression
        /// replacementKey(misheard form) -> term
        let terms: [String: String]
    }

    private var learnedReplacementsCache: (entries: [DictionaryEntry], value: Replacements?)?

    private var learnedReplacements: Replacements? {
        if let cache = learnedReplacementsCache, cache.entries == entries { return cache.value }
        var terms: [String: String] = [:]
        for entry in entries {
            for form in entry.heardAs where form.autoReplace {
                let key = Self.replacementKey(form.text)
                // A form that is itself a term is never rewritten.
                guard !key.isEmpty, !entries.contains(where: { Self.replacementKey($0.term) == key }) else { continue }
                terms[key] = terms[key] ?? entry.term
            }
        }
        var value: Replacements?
        if !terms.isEmpty {
            // Longest first so "cuber netties" wins over "cuber"; words may be
            // separated by any whitespace; letters/digits may not touch either
            // end, so a form never matches inside a longer word.
            let alternatives = terms.keys.sorted { $0.count > $1.count }.map { key in
                key.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
            }
            let pattern = "(?<![\\p{L}\\p{N}])(?:" + alternatives.joined(separator: "|") + ")(?![\\p{L}\\p{N}])"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                value = Replacements(regex: regex, terms: terms)
            }
        }
        learnedReplacementsCache = (entries, value)
        return value
    }

    private static func replacementKey(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// True when a *different* entry already uses this term (case-insensitive,
    /// trimmed). Drives editor validation and the add/update guards.
    func termExists(_ term: String, excluding id: UUID? = nil) -> Bool {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }
        return entries.contains {
            $0.id != id && $0.term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
        }
    }

    /// Appends unless the term already exists. Returns true when added.
    @discardableResult
    func add(_ entry: DictionaryEntry) -> Bool {
        guard !termExists(entry.term, excluding: entry.id) else { return false }
        var entry = entry
        entry.term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
        entries.append(entry)
        save()
        return true
    }

    @discardableResult
    func update(_ entry: DictionaryEntry) -> Bool {
        guard !termExists(entry.term, excluding: entry.id) else { return false }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            var entry = entry
            entry.term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            entries[index] = entry
            save()
        }
        return true
    }

    func remove(_ entry: DictionaryEntry) {
        entries.removeAll { $0.id == entry.id }
        usage[entry.id] = nil
        save()
    }

    func removeAt(_ offsets: IndexSet) {
        for index in offsets { usage[entries[index].id] = nil }
        entries.remove(atOffsets: offsets)
        save()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            entries = Self.defaultEntries()
            save()
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(DictionaryFile.self, from: data)
            entries = file.terms
            let ids = Set(entries.map(\.id))
            usage = Dictionary(uniqueKeysWithValues: file.usage.compactMap { key, value in
                UUID(uuidString: key).flatMap { ids.contains($0) ? ($0, value) : nil }
            })
            pending = file.pending
        } catch {
            Log.storage.error("Failed to load dictionary.json: \(error.localizedDescription, privacy: .public)")
            StorageQuarantine.quarantine(fileURL, reason: "decode_failed")
            entries = []
        }
    }

    private static func defaultEntries() -> [DictionaryEntry] {
        [
            DictionaryEntry(term: "John Doe", category: "name"),
            DictionaryEntry(term: "Dictify", category: "brand"),
            DictionaryEntry(term: "macOS", category: "brand"),
            DictionaryEntry(term: "GitHub", category: "brand"),
            DictionaryEntry(term: "Kubernetes", category: "tech"),
            DictionaryEntry(term: "Groq", category: "brand")
        ]
    }

    private func save() {
        usageSaveTask?.cancel()
        usageSaveTask = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let file = DictionaryFile(
            terms: entries,
            usage: Dictionary(uniqueKeysWithValues: usage.map { ($0.key.uuidString, $0.value) }),
            pending: pending
        )

        do {
            let data = try encoder.encode(file)
            try data.write(to: fileURL, options: .atomic)
            lastSaveError = nil
        } catch {
            Log.storage.error("Failed to save dictionary.json (attempt 1): \(error.localizedDescription, privacy: .public)")
            do {
                let data = try encoder.encode(file)
                try data.write(to: fileURL, options: .atomic)
                lastSaveError = nil
            } catch {
                Log.storage.error("Failed to save dictionary.json (retry): \(error.localizedDescription, privacy: .public)")
                lastSaveError = error
            }
        }
    }
}
