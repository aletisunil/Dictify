import Foundation

/// Pure text-diff logic that extracts corrected words from a user's manual edits
/// to previously-inserted transcription text. Ported from OpenWhispr's
/// `correctionLearner.js`. No AppKit / Accessibility dependencies, so it can be
/// reasoned about and unit-tested in isolation.
///
/// Strategy: locate the region of the field that corresponds to what we inserted,
/// align it to the original word-by-word (LCS), pull out single-word
/// substitutions, and keep only those that look like genuine transcription fixes
/// (near-miss, single token) rather than editorial rewordings.
enum CorrectionLearner {

    /// - Parameters:
    ///   - originalText: the text Dictify inserted.
    ///   - fieldValue: the field's current value after the user edited it.
    ///   - existingDictionary: terms already known (skipped, case-insensitive).
    /// - Returns: corrected words to add to the dictionary (original casing preserved).
    static func extractCorrections(originalText: String, fieldValue: String, existingDictionary: [String]) -> [String] {
        guard !originalText.isEmpty, !fieldValue.isEmpty, originalText != fieldValue else { return [] }

        let editedRegion = findEditedRegion(originalText: originalText, fieldValue: fieldValue)
        if editedRegion == originalText { return [] }

        let origWords = tokenize(originalText)
        let editedWords = tokenize(editedRegion)
        guard !origWords.isEmpty, !editedWords.isEmpty else { return [] }

        let subs = findSubstitutions(origWords: origWords, editedWords: editedWords)
        // More than half the words changed ⇒ this is a rewrite, not a correction.
        if Double(subs.count) > Double(origWords.count) * 0.5 { return [] }

        let dictSet = Set(existingDictionary.map { $0.lowercased() })
        var seen = Set<String>()
        var results: [String] = []

        for (original, corrected) in subs {
            let lower = corrected.lowercased()
            if dictSet.contains(lower) || seen.contains(lower) { continue }
            guard isLearnableCorrection(original: original, corrected: corrected) else { continue }
            seen.insert(lower)
            results.append(corrected)
            if results.count >= Constants.AutoLearn.maxCorrectionsPerCapture { break }
        }
        return results
    }

    // MARK: - Guards

    /// Accept only near-miss, single-word fixes (homophones / misspellings),
    /// not unrelated rewordings.
    static func isLearnableCorrection(original: String, corrected: String) -> Bool {
        guard corrected.count >= Constants.AutoLearn.minWordLength else { return false }
        guard isWordLike(corrected) else { return false }
        // The corrected word should resemble the original — a transcription slip,
        // not a completely different word swapped in.
        let distance = editDistance(original.lowercased(), corrected.lowercased())
        let bound = max(Constants.AutoLearn.minEditDistanceBound, corrected.count / 2)
        return distance > 0 && distance <= bound
    }

    /// A single token of letters, allowing internal apostrophes/hyphens
    /// (e.g. "O'Brien", "real-time"). Rejects numbers, symbols, multi-word noise.
    static func isWordLike(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let chars = Array(s)
        for (i, ch) in chars.enumerated() {
            if ch.isLetter { continue }
            if (ch == "'" || ch == "-"), i > 0, i < chars.count - 1 { continue }
            return false
        }
        return chars.contains { $0.isLetter }
    }

    // MARK: - Tokenize

    static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .map { trimEdgePunctuation(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func trimEdgePunctuation(_ word: String) -> String {
        func keep(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        var chars = Array(word)
        while let first = chars.first, !keep(first) { chars.removeFirst() }
        while let last = chars.last, !keep(last) { chars.removeLast() }
        return String(chars)
    }

    // MARK: - Edited region (sliding window, ≥30% overlap)

    static func findEditedRegion(originalText: String, fieldValue: String) -> String {
        // Field is roughly the size of what we pasted ⇒ treat the whole thing.
        if Double(fieldValue.count) <= Double(originalText.count) * 1.5 {
            return fieldValue
        }
        // Our text survives verbatim somewhere ⇒ no edits to our region.
        if fieldValue.contains(originalText) {
            return originalText
        }

        let origWords = tokenize(originalText)
        let fieldWords = tokenize(fieldValue)
        let windowSize = origWords.count
        if windowSize == 0 || fieldWords.count <= windowSize { return fieldValue }

        var bestStart = 0
        var bestScore = -1
        var i = 0
        while i <= fieldWords.count - windowSize {
            var matches = 0
            for j in 0..<windowSize where fieldWords[i + j].lowercased() == origWords[j].lowercased() {
                matches += 1
            }
            if matches > bestScore {
                bestScore = matches
                bestStart = i
            }
            i += 1
        }

        // Require at least 30% word overlap to consider it our region.
        if Double(bestScore) < Double(windowSize) * 0.3 { return fieldValue }
        return fieldWords[bestStart..<(bestStart + windowSize)].joined(separator: " ")
    }

    // MARK: - Word-level LCS substitutions

    /// Aligns the two word sequences via LCS and returns consecutive
    /// `[origWord → nil] + [nil → editedWord]` pairs as `(original, edited)` subs.
    static func findSubstitutions(origWords: [String], editedWords: [String]) -> [(String, String)] {
        let m = origWords.count
        let n = editedWords.count
        guard m > 0, n > 0 else { return [] }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if origWords[i - 1].lowercased() == editedWords[j - 1].lowercased() {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        var aligned: [(String?, String?)] = []
        var i = m
        var j = n
        while i > 0 || j > 0 {
            if i > 0, j > 0, origWords[i - 1].lowercased() == editedWords[j - 1].lowercased() {
                aligned.insert((origWords[i - 1], editedWords[j - 1]), at: 0)
                i -= 1
                j -= 1
            } else if j > 0, i == 0 || dp[i][j - 1] >= dp[i - 1][j] {
                aligned.insert((nil, editedWords[j - 1]), at: 0)
                j -= 1
            } else {
                aligned.insert((origWords[i - 1], nil), at: 0)
                i -= 1
            }
        }

        var subs: [(String, String)] = []
        var k = 0
        while k < aligned.count - 1 {
            let (origW, editW) = aligned[k]
            let (nextOrigW, nextEditW) = aligned[k + 1]
            if let origW, editW == nil, nextOrigW == nil, let nextEditW {
                subs.append((origW, nextEditW))
            }
            k += 1
        }
        return subs
    }

    // MARK: - Levenshtein

    static func editDistance(_ a: String, _ b: String) -> Int {
        let aa = Array(a)
        let bb = Array(b)
        let m = aa.count
        let n = bb.count
        if m == 0 { return n }
        if n == 0 { return m }

        var dp = Array(0...n)
        for i in 1...m {
            var prev = dp[0]
            dp[0] = i
            for j in 1...n {
                let temp = dp[j]
                dp[j] = aa[i - 1] == bb[j - 1] ? prev : 1 + Swift.min(dp[j], dp[j - 1], prev)
                prev = temp
            }
        }
        return dp[n]
    }
}
