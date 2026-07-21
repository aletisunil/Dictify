import Foundation

/// Rejects refinement output that behaves like a chat response instead of a
/// faithful cleanup. This is deliberately local and deterministic: the model
/// never gets a second chance to judge its own output.
enum RefinementOutputGuard {
    enum Rejection: String {
        case assistantPreamble = "assistant preamble"
        case runawayExpansion = "runaway expansion"
        case destructiveContraction = "destructive contraction"
        case questionWasAnswered = "question was answered"
        case contentWasReplaced = "source content was replaced"
    }

    static func rejection(
        for refined: String,
        raw: String,
        allowsSnippetExpansion: Bool
    ) -> Rejection? {
        // A matched snippet cue is intentionally allowed to replace a tiny cue
        // with an unrelated, potentially very long body. The pipeline only sets
        // this flag after its local whole-word cue matcher finds a real cue in
        // the transcript; merely having snippets configured is not sufficient.
        guard !allowsSnippetExpansion else { return nil }

        let lower = refined.lowercased()
        let preambles = [
            "sure, ",
            "sure! ",
            "of course, ",
            "of course! ",
            "here is ",
            "here's ",
            "here are ",
            "i'd be happy to",
            "i would be happy to",
            "as an ai",
            "certainly, ",
            "certainly! ",
            "absolutely, "
        ]
        if preambles.contains(where: { lower.hasPrefix($0) }),
           lexicalTokens(in: raw) != lexicalTokens(in: refined) {
            return .assistantPreamble
        }

        // Cleanup can remove fillers, but it must not turn one sentence into an
        // essay or collapse a paragraph into a summary. The absolute floors
        // avoid overreacting to harmless changes in very short utterances.
        let rawLength = max(raw.count, 1)
        if refined.count > 200, Double(refined.count) > 2.5 * Double(rawLength) {
            return .runawayExpansion
        }
        if raw.count > 240, Double(refined.count) < 0.4 * Double(raw.count) {
            return .destructiveContraction
        }

        // The clearest answer signature: the source is a question, but the
        // result is a declarative response. Whisper normally supplies question
        // marks; the structural fallback covers unpunctuated "what is..." and
        // "can you..." transcriptions without treating phrases such as "when
        // I'm working..." as questions.
        if looksLikeQuestion(raw), !looksLikeQuestion(refined) {
            return .questionWasAnswered
        }

        // Refinement is allowed to remove filler and fix spelling, not replace
        // the speaker's meaningful vocabulary. Low content-word retention catches
        // concise answers and summaries that length-only checks cannot detect.
        let rawContent = contentTokens(in: raw)
        if rawContent.count >= 3 {
            let refinedContent = Set(contentTokens(in: refined))
            let retained = rawContent.reduce(into: 0) { count, token in
                if refinedContent.contains(token) { count += 1 }
            }
            if Double(retained) / Double(rawContent.count) < 0.5 {
                return .contentWasReplaced
            }
        }

        return nil
    }

    private static func looksLikeQuestion(_ text: String) -> Bool {
        if text.contains("?") { return true }

        let words = lexicalTokens(in: text)
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

        let interrogatives: Set<String> = ["how", "what", "when", "where", "which", "who", "why"]
        guard interrogatives.contains(words[0]) else { return false }
        return words.dropFirst().prefix(3).contains(where: auxiliaries.contains)
    }

    private static func contentTokens(in text: String) -> [String] {
        let stopWords: Set<String> = [
            "a", "am", "an", "and", "are", "as", "at", "be", "been", "but",
            "by", "can", "could", "did", "do", "does", "for", "from", "had",
            "has", "have", "he", "her", "him", "his", "how", "i", "if", "in",
            "is", "it", "its", "may", "me", "might", "must", "my", "of", "on",
            "or", "our", "she", "should", "so", "that", "the", "their", "them",
            "they", "this", "those", "to", "uh", "um", "was", "we", "were",
            "what", "when", "where", "which", "who", "why", "will", "with",
            "would", "you", "your"
        ]
        return lexicalTokens(in: text).filter { !stopWords.contains($0) }
    }

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
            } else if scalar == "'" || scalar == "’" {
                continue
            } else {
                finishToken()
            }
        }
        finishToken()
        return tokens
    }
}
