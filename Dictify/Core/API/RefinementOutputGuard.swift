import Foundation

/// Rejects refinement output that behaves like a chat response instead of a
/// faithful cleanup. This is deliberately local and deterministic: the model
/// never gets a second chance to judge its own output.
///
/// Prompt hardening alone is not sufficient. Measured against the shipping
/// prompt on GPT-OSS, answer-prone dictations ("can you write a short email to
/// my manager saying I'll be out on Friday") produce net-new content - a
/// drafted email, a bullet list, a subject line - in roughly 10% of Fast-mode
/// requests, and almost none of it carries an assistant preamble or runs long
/// enough for a length check to notice. The structural checks below are what
/// actually catch it.
///
/// Every check compares vocabulary in both directions: words the speaker said
/// must survive (retention) and words the speaker never said must not appear
/// (novelty). Each direction has to tolerate what the cleanup rules explicitly
/// allow - filler removal, backtracking, dictionary corrections, numeric
/// rewrites, spoken punctuation - or it rejects correct cleanups.
enum RefinementOutputGuard {
    enum Rejection: String {
        case assistantPreamble = "assistant preamble"
        case runawayExpansion = "runaway expansion"
        case destructiveContraction = "destructive contraction"
        case questionWasAnswered = "question was answered"
        case contentWasReplaced = "source content was replaced"
        case contentWasAdded = "content was added"
    }

    /// - Parameters:
    ///   - refined: the model's output.
    ///   - raw: the transcript that was sent for refinement.
    ///   - snippetExpandedRaw: `raw` with locally matched snippet cues expanded
    ///     (clipboard placeholder left literal), or nil when no cue matched.
    ///     The model may or may not expand a cue, so output is accepted when it
    ///     is a faithful cleanup of either form.
    ///   - dictionaryTerms: the user's dictionary. Rule 7 rewrites sound-alikes
    ///     into these terms, so they never count as invented vocabulary.
    static func rejection(
        for refined: String,
        raw: String,
        snippetExpandedRaw: String? = nil,
        dictionaryTerms: [String] = []
    ) -> Rejection? {
        let dictionary = MatchIndex(tokens: dictionaryTerms.flatMap { lexicalTokens(in: $0) + [lexicalTokens(in: $0).joined()] })
        guard let rawRejection = rejection(for: refined, reference: raw, dictionary: dictionary) else {
            return nil
        }
        if let expanded = snippetExpandedRaw, expanded != raw,
           rejection(for: refined, reference: expanded, dictionary: dictionary) == nil {
            return nil
        }
        return rawRejection
    }

    private static func rejection(for refined: String, reference raw: String, dictionary: MatchIndex) -> Rejection? {
        let rawTokens = lexicalTokens(in: raw)
        let refinedTokens = lexicalTokens(in: refined)

        if startsWithAssistantPreamble(refined, rawTokens: rawTokens) {
            return .assistantPreamble
        }

        // Cleanup can remove fillers, but it must not turn one sentence into an
        // essay or collapse a paragraph into a summary. The absolute floors
        // avoid overreacting to harmless changes in very short utterances.
        let rawLength = max(raw.count, 1)
        if refined.count > 200, Double(refined.count) > 2.5 * Double(rawLength) {
            return .runawayExpansion
        }
        // A backtrack ("...no wait, scratch that...") legitimately discards
        // everything before it, so contraction is only meaningful without one.
        let correctionEnd = endOfLastCorrection(in: rawTokens)
        if correctionEnd == nil, raw.count > 240, Double(refined.count) < 0.4 * Double(raw.count) {
            return .destructiveContraction
        }

        let comparison = Comparison(raw: rawTokens, refined: refinedTokens, dictionary: dictionary)
        let rawIsQuestion = looksLikeQuestion(raw)

        // Question followed by an answer: "What's the capital of France?
        // Paris." keeps the question intact, so only the sentences after the
        // question mark reveal it. Each must be mostly the speaker's own words;
        // judging them one at a time keeps a long, faithful sentence (or an
        // expanded snippet body) from diluting a short invented one.
        if rawIsQuestion, let firstMark = refined.firstIndex(of: "?") {
            let tail = refined[refined.index(after: firstMark)...]
            for sentence in sentences(in: tail) {
                let content = lexicalTokens(in: sentence).filter(isContent)
                let novel = content.filter { !comparison.rawIndex.contains($0) && !dictionary.contains($0) }
                if !novel.isEmpty, novel.count * 2 >= content.count {
                    return .questionWasAnswered
                }
            }
        }

        // Question replaced by a declarative response. Whisper normally
        // supplies question marks; the structural fallback covers unpunctuated
        // "what is..." and "can you..." transcriptions. A faithful copy that
        // merely lost a question mark Whisper put on a statement is not an
        // answer.
        if rawIsQuestion, !looksLikeQuestion(refined) {
            let faithful = comparison.novelCount <= 1 && comparison.retention(from: 0) >= 0.8
            if !faithful {
                return .questionWasAnswered
            }
        }

        // Refinement is allowed to remove filler and fix spelling, not replace
        // the speaker's meaningful vocabulary. Low content-word retention catches
        // concise answers and summaries that length-only checks cannot detect.
        // After a backtrack only the corrected tail has to survive.
        if comparison.retentionFails(from: 0),
           correctionEnd.map({ comparison.retentionFails(from: $0) }) ?? true {
            return .contentWasReplaced
        }

        // Answers and drafted content usually keep every word of the request
        // ("write an email to my manager...") and append a body, so retention
        // alone never sees them. Tone matching and grammar tidying add a few
        // words; generated content adds many.
        if comparison.novelCount >= 4,
           Double(comparison.novelCount) > 0.35 * Double(comparison.rawContentCount) {
            return .contentWasAdded
        }

        return nil
    }

    // MARK: - Preamble

    /// Chat-assistant openers with the tokens a speaker would have to say for
    /// the opener to be theirs. "Sure, I can do that tomorrow" is a normal
    /// reply to dictate; it is only a preamble when the speaker didn't say it.
    private static let preambles: [(prefix: String, spoken: [String])] = [
        ("sure, ", ["sure"]),
        ("sure! ", ["sure"]),
        ("of course, ", ["of", "course"]),
        ("of course! ", ["of", "course"]),
        ("here is ", ["here", "is"]),
        ("here's ", ["here", "is"]),
        ("here are ", ["here", "are"]),
        ("i'd be happy to", ["i", "would", "be", "happy", "to"]),
        ("i would be happy to", ["i", "would", "be", "happy", "to"]),
        ("as an ai", ["as", "an", "ai"]),
        ("certainly, ", ["certainly"]),
        ("certainly! ", ["certainly"]),
        ("absolutely, ", ["absolutely"])
    ]

    private static func startsWithAssistantPreamble(_ refined: String, rawTokens: [String]) -> Bool {
        let lower = refined.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        guard let marker = preambles.first(where: { lower.hasPrefix($0.prefix) }) else { return false }

        let spoken = rawTokens
            .drop(while: leadingFillers.contains)
            .flatMap { contractionExpansions[$0] ?? [$0] }
        return !spoken.starts(with: marker.spoken)
    }

    /// Only the contractions the preamble list needs to compare against the
    /// spelled-out forms a speaker might use.
    private static let contractionExpansions: [String: [String]] = [
        "heres": ["here", "is"],
        "id": ["i", "would"]
    ]

    // MARK: - Question detection

    private static let leadingFillers: Set<String> = [
        "ah", "er", "hey", "hmm", "like", "ok", "okay", "oh", "so", "uh", "um", "well", "yeah"
    ]

    private static func looksLikeQuestion(_ text: String) -> Bool {
        if text.contains("?") { return true }

        let words = Array(lexicalTokens(in: text).drop(while: leadingFillers.contains))
        guard words.count >= 2 else { return false }

        let auxiliaries: Set<String> = [
            "am", "are", "can", "could", "did", "do", "does", "had", "has",
            "have", "is", "may", "might", "must", "should", "was", "were",
            "will", "would"
        ]
        let pronouns: Set<String> = [
            "he", "i", "it", "she", "that", "they", "this", "we", "who", "you"
        ]
        if auxiliaries.contains(words[0]), pronouns.contains(words[1]) {
            return true
        }

        // "what's" / "how's" already carry their auxiliary.
        let contractedInterrogatives: Set<String> = ["hows", "whats", "whens", "wheres", "whos", "whys"]
        if contractedInterrogatives.contains(words[0]) { return true }

        let interrogatives: Set<String> = ["how", "what", "when", "where", "which", "who", "why"]
        guard interrogatives.contains(words[0]) else { return false }
        return words.dropFirst().prefix(3).contains(where: auxiliaries.contains)
    }

    /// Splits at sentence-ending punctuation followed by whitespace (or the
    /// end), so URLs and decimals like "cal.com" or "2.5" stay intact.
    private static func sentences(in text: Substring) -> [String] {
        var sentences: [String] = []
        var current = ""
        var pendingBoundary = false
        for character in text {
            if pendingBoundary, character.isWhitespace {
                sentences.append(current)
                current = ""
            }
            pendingBoundary = ".!?".contains(character)
            current.append(character)
        }
        sentences.append(current)
        return sentences
    }

    // MARK: - Backtracking

    /// Phrases after which rule 2 keeps only what follows.
    private static let correctionCues: [[String]] = [
        ["scratch", "that"], ["strike", "that"], ["delete", "that"],
        ["no", "wait"], ["wait", "no"], ["never", "mind"], ["or", "rather"],
        ["let", "me", "rephrase"], ["i", "mean"], ["actually"], ["sorry"],
        ["correction"]
    ]

    /// Token index just past the last correction cue, or nil when the
    /// transcript never backtracks.
    private static func endOfLastCorrection(in tokens: [String]) -> Int? {
        var end: Int?
        for start in tokens.indices {
            for cue in correctionCues where tokens[start...].starts(with: cue) {
                end = max(end ?? 0, start + cue.count)
            }
        }
        return end
    }

    // MARK: - Vocabulary comparison

    private struct Comparison {
        let rawIndex: MatchIndex
        /// Per raw token: whether the refined text still carries it.
        let retained: [Bool]
        /// Raw positions that count toward retention.
        let contentPositions: [Int]
        /// Refined content words found neither in the transcript nor the dictionary.
        let novelCount: Int
        /// Lost raw words that dictionary corrections can account for: each
        /// introduced term may replace up to two misheard words ("get hub" → "GitHub").
        let dictionaryAllowance: Int

        var rawContentCount: Int { contentPositions.count }

        init(raw: [String], refined: [String], dictionary: MatchIndex) {
            let rawIndex = MatchIndex(tokens: raw)
            self.rawIndex = rawIndex
            let refinedIndex = MatchIndex(tokens: refined)

            var retained = raw.map(refinedIndex.contains)
            // Words the model joined: "e mail" → "email", "get hub" → "GitHub".
            for length in 2...3 where raw.count >= length {
                for start in 0...(raw.count - length) {
                    let joined = raw[start..<(start + length)].joined()
                    if refinedIndex.contains(joined) {
                        for position in start..<(start + length) { retained[position] = true }
                    }
                }
            }
            self.retained = retained

            let spokenPunctuation = RefinementOutputGuard.spokenPunctuationPositions(in: raw)
            contentPositions = raw.indices.filter {
                !spokenPunctuation.contains($0) && RefinementOutputGuard.isContent(raw[$0])
            }

            let refinedContent = refined.filter(RefinementOutputGuard.isContent)
            novelCount = refinedContent.filter { !rawIndex.contains($0) && !dictionary.contains($0) }.count
            dictionaryAllowance = 2 * refinedContent.filter { !rawIndex.contains($0) && dictionary.contains($0) }.count
        }

        /// Share of the raw content words from `start` onward that survived.
        func retention(from start: Int) -> Double {
            let positions = contentPositions.filter { $0 >= start }
            guard !positions.isEmpty else { return 1 }
            let kept = positions.filter { retained[$0] }.count
            let explained = min(positions.count - kept, dictionaryAllowance)
            return Double(kept + explained) / Double(positions.count)
        }

        /// Needs at least three content words: below that, one legitimate
        /// correction swings the ratio past any threshold.
        func retentionFails(from start: Int) -> Bool {
            contentPositions.filter { $0 >= start }.count >= 3 && retention(from: start) < 0.5
        }
    }

    /// Stemmed token lookup, including adjacent-token joins so compounds the
    /// model splits or merges still match.
    private struct MatchIndex {
        private let stems: Set<String>

        init(tokens: [String]) {
            var stems = Set(tokens.map(RefinementOutputGuard.stem))
            for length in 2...3 where tokens.count >= length {
                for start in 0...(tokens.count - length) {
                    stems.insert(RefinementOutputGuard.stem(tokens[start..<(start + length)].joined()))
                }
            }
            self.stems = stems
        }

        func contains(_ token: String) -> Bool {
            stems.contains(RefinementOutputGuard.stem(token))
        }
    }

    /// Crude suffix folding so tidied inflections ("ship" → "shipping") and
    /// possessives ("John's" → "johns") still match.
    private static func stem(_ token: String) -> String {
        for suffix in ["ing", "ed", "s"] where token.count > suffix.count + 2 && token.hasSuffix(suffix) {
            return String(token.dropLast(suffix.count))
        }
        return token
    }

    /// Rule 4 cues ("question mark", "new line") become symbols, so their words
    /// are expected to disappear.
    private static func spokenPunctuationPositions(in tokens: [String]) -> Set<Int> {
        let phrases: [[String]] = [
            ["question", "mark"], ["exclamation", "point"], ["exclamation", "mark"],
            ["new", "line"], ["new", "paragraph"], ["full", "stop"],
            ["comma"], ["period"], ["colon"], ["semicolon"]
        ]
        var positions = Set<Int>()
        for start in tokens.indices {
            for phrase in phrases where tokens[start...].starts(with: phrase) {
                positions.formUnion(start..<(start + phrase.count))
            }
        }
        return positions
    }

    private static func isContent(_ token: String) -> Bool {
        token.count > 1
            && !ignoredWords.contains(token)
            && !numericRewriteWords.contains(token)
            && !token.contains(where: \.isNumber)
    }

    /// Function words, rule 1 fillers, and contractions (apostrophes folded).
    /// Fillers must be here: the model is told to delete "like", "you know",
    /// "I mean", so counting them as content rejects correct cleanups of
    /// filler-heavy speech.
    private static let ignoredWords: Set<String> = [
        // Function words
        "am", "an", "and", "are", "as", "at", "be", "been", "being", "but",
        "by", "can", "could", "did", "do", "does", "for", "from", "had", "has",
        "have", "he", "her", "him", "his", "how", "if", "in", "into", "is",
        "it", "its", "may", "me", "might", "must", "my", "no", "not", "of",
        "on", "or", "our", "she", "should", "so", "than", "that", "the",
        "their", "them", "then", "there", "these", "they", "this", "those",
        "to", "up", "was", "we", "were", "what", "when", "where", "which",
        "who", "why", "will", "with", "would", "you", "your",
        // Fillers
        "ah", "actually", "basically", "eh", "er", "hmm", "just", "kind",
        "know", "like", "literally", "mean", "mhm", "oh", "ok", "okay",
        "nope", "really", "right", "sort", "uh", "um", "well", "yeah", "yep",
        "yes", "yup",
        // Contractions and their tidied forms
        "arent", "because", "cant", "cause", "couldnt", "cuz", "didnt",
        "doesnt", "dont", "going", "gonna", "got", "gotta", "hadnt", "hasnt",
        "havent", "hes", "id", "ill", "im", "isnt", "ive", "lets", "shes",
        "shouldnt", "thats", "theres", "theyre", "theyve", "wanna", "want",
        "wasnt", "weve", "werent", "whats", "wont", "wouldnt", "youd",
        "youll", "youre", "youve"
    ]

    /// Words cleanup rule 8 is explicitly allowed to rewrite into numerals -
    /// "three hundred dollars" → "$300", "january fifteenth twenty twenty six"
    /// → "January 15, 2026". Counting these as content made the retention check
    /// reject correct cleanups of any utterance carrying a price, date, or time;
    /// that false-positive (~6% of ordinary dictation) is what made an earlier
    /// version of this guard unusable in the field. Tokens containing a digit
    /// are dropped for the same reason: they are the other half of the rewrite.
    private static let numericRewriteWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
        "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred",
        "thousand", "million", "billion",
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh",
        "eighth", "ninth", "tenth", "eleventh", "twelfth", "thirteenth",
        "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth",
        "nineteenth", "twentieth", "thirtieth", "fortieth", "fiftieth",
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
        "sunday",
        "dollar", "dollars", "cent", "cents", "pound", "pounds", "euro",
        "euros", "percent", "am", "pm", "oclock", "quarter", "half"
    ]

    /// Words with apostrophes folded out so "don't" and curly-apostrophe forms
    /// normalize identically. Punctuation otherwise acts as a separator.
    private static func lexicalTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = ""

        func finishToken() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }

        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if scalar == "'" || scalar == "\u{2019}" {
                continue
            } else {
                finishToken()
            }
        }
        finishToken()
        return tokens
    }
}
