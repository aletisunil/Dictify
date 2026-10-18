import AppKit
import Foundation

/// Finds the misheard words a user corrected in text Dictify inserted, by a
/// word-level diff of the field right after insertion against a later read.
///
/// Only substitutions inside the inserted span count, each side 1-4 words,
/// and the corrected side must look like a name or term (a capital letter or
/// a digit, not only stopwords). Grammar fixes, rewrites, and new text typed
/// after the dictation are not corrections of a misheard word.
enum CorrectionLearner {
    struct Correction: Sendable, Equatable {
        /// As Dictify inserted it.
        let heard: String
        /// As the user fixed it.
        let corrected: String
    }

    static let maxWordsPerSide = 4
    static let maxCorrectionsPerDictation = 3
    /// LCS cost cap (words x words) after trimming the common ends: a larger
    /// difference is a rewrite, not a correction.
    private static let maxDiffCells = 1_000_000

    /// Words without surrounding punctuation ("Friday," -> "Friday"), so a
    /// punctuation fix is not a word change. Case is kept: "groq" -> "Groq"
    /// is a correction.
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            let word = raw.trimmingCharacters(in: .punctuationCharacters)
            return word.isEmpty ? nil : word
        }
    }

    /// Word range of `inserted` inside `value`. Paste leaves the caret right
    /// after the inserted text, so the occurrence ending closest to the caret
    /// wins when the same words appear twice.
    static func locate(_ inserted: [String], in value: [String], caretWord: Int?) -> Range<Int>? {
        guard !inserted.isEmpty, inserted.count <= value.count else { return nil }
        var best: Range<Int>?
        for start in 0...(value.count - inserted.count) where value[start] == inserted[0] {
            guard value[start..<(start + inserted.count)].elementsEqual(inserted) else { continue }
            let range = start..<(start + inserted.count)
            guard let caretWord else { return range }
            if best.map({ abs($0.upperBound - caretWord) > abs(range.upperBound - caretWord) }) ?? true {
                best = range
            }
        }
        return best
    }

    /// Corrections made inside `span` of `original`, or nil when the inserted
    /// text no longer survives in `edited` (deleted, or the field was cleared
    /// or sent) - the caller then keeps what an earlier read found.
    static func corrections(original: [String], span: Range<Int>, edited: [String]) -> [Correction]? {
        var prefix = 0
        while prefix < original.count, prefix < edited.count, original[prefix] == edited[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < original.count - prefix, suffix < edited.count - prefix,
              original[original.count - 1 - suffix] == edited[edited.count - 1 - suffix] {
            suffix += 1
        }
        let a = Array(original[prefix..<(original.count - suffix)])
        let b = Array(edited[prefix..<(edited.count - suffix)])
        if a.isEmpty { return [] }
        guard a.count * max(b.count, 1) <= maxDiffCells else { return nil }

        // LCS over the changed middle, then walk it into hunks of
        // (original words, edited words) between matches.
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var hunks: [(original: Range<Int>, edited: [String])] = []
        var matchedInSpan = (span.clamped(to: 0..<prefix).count) + (span.clamped(to: (original.count - suffix)..<original.count).count)
        var i = 0, j = 0
        var hunkStart: Int?
        var hunkEdited: [String] = []
        func closeHunk() {
            if let start = hunkStart {
                hunks.append((prefix + start..<prefix + i, hunkEdited))
            }
            hunkStart = nil
            hunkEdited = []
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                closeHunk()
                if span.contains(prefix + i) { matchedInSpan += 1 }
                i += 1
                j += 1
            } else if j < b.count, i == a.count || table[i][j + 1] >= table[i + 1][j] {
                if hunkStart == nil { hunkStart = i }
                hunkEdited.append(b[j])
                j += 1
            } else {
                if hunkStart == nil { hunkStart = i }
                i += 1
            }
        }
        closeHunk()

        // Most of the dictation must still be there; otherwise this read shows
        // a cleared, sent, or rewritten field.
        guard matchedInSpan * 2 >= span.count else { return nil }

        var result: [Correction] = []
        for hunk in hunks {
            guard !hunk.original.isEmpty, !hunk.edited.isEmpty,
                  hunk.original.lowerBound >= span.lowerBound, hunk.original.upperBound <= span.upperBound else {
                continue
            }
            result += split(heard: Array(original[hunk.original]), corrected: hunk.edited)
        }
        return Array(result.prefix(maxCorrectionsPerDictation))
    }

    /// Corrections inside one diff hunk. Fixes to neighbouring words land in
    /// one hunk ("Luke, Shivon" -> "loop in Siobhan"), and learning the whole
    /// hunk would store "loop in Siobhan" as a term. So each run of term-like
    /// corrected words is paired with the run of heard words that is most
    /// similar to it ("Cuber Netties" as a whole for "Kubernetes", "Shivon"
    /// alone for "Siobhan"), and the rest of the hunk is ignored.
    private static func split(heard: [String], corrected: [String]) -> [Correction] {
        var result: [Correction] = []
        for run in termRuns(corrected) where run.count <= maxWordsPerSide {
            let term = corrected[run]
            guard looksLikeTerm(Array(term)) else { continue }
            let termText = term.joined(separator: " ")
            var best: (text: String, similarity: Double)?
            for start in heard.indices {
                for end in (start + 1)...min(heard.count, start + maxWordsPerSide) {
                    let candidate = heard[start..<end].joined(separator: " ")
                    let similarity = letterSimilarity(candidate, termText)
                    if similarity > (best?.similarity ?? 0) {
                        best = (candidate, similarity)
                    }
                }
            }
            if let best, best.text != termText {
                result.append(Correction(heard: best.text, corrected: termText))
            }
        }
        return result
    }

    /// Maximal runs of words that carry a capital letter or a digit.
    private static func termRuns(_ words: [String]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for (index, word) in words.enumerated() {
            if word.contains(where: { $0.isUppercase || $0.isNumber }) {
                if start == nil { start = index }
            } else if let runStart = start {
                runs.append(runStart..<index)
                start = nil
            }
        }
        if let runStart = start { runs.append(runStart..<words.count) }
        return runs
    }

    private static func looksLikeTerm(_ words: [String]) -> Bool {
        let hasCapitalOrDigit = words.contains { word in word.contains { $0.isUppercase || $0.isNumber } }
        let onlyStopwords = words.allSatisfy { stopwords.contains($0.lowercased()) }
        return hasCapitalOrDigit && !onlyStopwords
    }

    private static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "if", "of", "to", "in", "on", "at", "by", "for",
        "with", "from", "as", "is", "are", "was", "were", "be", "it", "its", "this", "that", "these",
        "those", "i", "you", "he", "she", "we", "they", "me", "him", "her", "us", "them", "my", "your",
        "his", "our", "their", "not", "no", "yes", "do", "does", "did", "have", "has", "had", "will",
        "would", "can", "could", "should", "just", "then", "there", "here", "what", "when", "who",
    ]

    // MARK: - Acceptance

    enum Decision: Equatable {
        case reject
        /// Learn it now.
        case learn(autoReplace: Bool)
        /// Learn it only when the user makes the same correction again; see
        /// `DictionaryStore.learnWhenConfirmed`.
        case confirmFirst(autoReplace: Bool)
    }

    /// Final gate, on the main actor because NSSpellChecker is not thread
    /// safe.
    /// - Recapitalizing a real word ("make" -> "Make" after splitting a
    ///   sentence, "please" -> "Please") is sentence editing, not a term.
    /// - A similar spelling is a mishearing ("cloud" -> "Claude",
    ///   "Cuber Netties" -> "Kubernetes"), learned at once.
    /// - A dissimilar one may be a mishearing too ("Chivon" -> "Siobhan"),
    ///   or the user picking another word ("Versil" -> "Netlify" when the
    ///   plan changed). Only a repeat tells them apart, so it is learned the
    ///   second time. Between real words it is always a rewrite
    ///   ("Sarah" -> "John"), unless the corrected side is an unusual term
    ///   that still looks a little like the heard one.
    /// `autoReplace` is true only when the heard form is not a real word.
    @MainActor
    static func assess(_ correction: Correction) -> Decision {
        let heardMisspelled = containsMisspelling(correction.heard)
        if isCapitalizationOnly(correction), !heardMisspelled {
            return .reject
        }
        let similarity = letterSimilarity(correction.heard, correction.corrected)
        if similarity >= 0.5 {
            return .learn(autoReplace: heardMisspelled)
        }
        if heardMisspelled || (similarity >= 0.25 && containsMisspelling(correction.corrected)) {
            return .confirmFirst(autoReplace: heardMisspelled)
        }
        return .reject
    }

    /// True when only the first letter of words changed case. Changes inside
    /// a word ("Github" -> "GitHub", "macos" -> "macOS") are spelling.
    static func isCapitalizationOnly(_ correction: Correction) -> Bool {
        func firstLettersUppercased(_ text: String) -> String {
            text.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        return firstLettersUppercased(correction.heard) == firstLettersUppercased(correction.corrected)
    }

    @MainActor
    private static func containsMisspelling(_ text: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: text, startingAt: 0).location != NSNotFound
    }

    /// 1 - normalized edit distance over lowercase letters and digits, so word
    /// splits ("Cuber Netties" vs "Kubernetes") do not count against it.
    static func letterSimilarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.lowercased().filter { $0.isLetter || $0.isNumber })
        let y = Array(b.lowercased().filter { $0.isLetter || $0.isNumber })
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }
}
