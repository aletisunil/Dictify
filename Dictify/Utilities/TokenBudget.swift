import Foundation

/// Approximate token budgeting to keep prompts bounded.
///
/// Uses a rough chars/4 heuristic, matching the OpenAI tokenizer rule-of-thumb.
/// Never meant to be exact — just a cheap bound before we hit the wire.
enum TokenBudget {
    static func estimateTokens(_ text: String) -> Int {
        max(1, (text.count + 3) / 4)
    }

    /// Truncates a list of strings to fit under `maxTokens`, preserving earlier
    /// entries. Caller is responsible for sorting by recency/priority first.
    static func fit(_ items: [String], joiner: String = ", ", maxTokens: Int) -> String {
        var accumulated = ""
        var tokensUsed = 0
        for (index, item) in items.enumerated() {
            let separator = index == 0 ? "" : joiner
            let addition = separator + item
            let additionTokens = estimateTokens(addition)
            if tokensUsed + additionTokens > maxTokens {
                break
            }
            accumulated += addition
            tokensUsed += additionTokens
        }
        return accumulated
    }
}
