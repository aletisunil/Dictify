import Foundation

final class LlamaService: @unchecked Sendable {
    private let client: GroqClient

    init(client: GroqClient) {
        self.client = client
    }

    func refine(rawTranscript: String, snippetContext: String) async throws -> String {
        let systemPrompt = buildSystemPrompt(snippetContext: snippetContext)

        let body: [String: Any] = [
            "model": Constants.API.llamaModel,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": rawTranscript]
            ],
            "temperature": 0.1,
            "max_tokens": 2048
        ]

        guard let url = URL(string: Constants.API.chatCompletionEndpoint) else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await client.performRequest(request)

        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)

        guard let content = response.choices.first?.message.content else {
            throw APIError.invalidResponse
        }

        let refined = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if refined.isEmpty {
            throw APIError.emptyTranscription
        }

        return refined
    }

    private func buildSystemPrompt(snippetContext: String) -> String {
        """
        You are a voice-to-text post-processor. Your job is to clean up a raw voice \
        transcription while preserving the speaker's exact meaning and tone.

        Rules:
        1. Remove filler words (um, uh, like, you know, I mean, sort of, kind of)
        2. When the speaker backtracks or corrects themselves, keep ONLY the corrected \
        version. Example: "let's meet at 2... actually 3" → "let's meet at 3"
        3. Add proper punctuation based on sentence boundaries and context
        4. Convert dictation commands to punctuation: "comma" → , / "period" → . / \
        "question mark" → ? / "exclamation point" → ! / "new line" → line break / \
        "new paragraph" → double line break
        5. When the speaker says sequential numbers followed by items, format as a numbered list
        6. Do NOT change the speaker's word choices, add new content, summarize, or paraphrase. Only clean up.
        7. Expand any snippet cues: \(snippetContext)

        Return ONLY the cleaned text with no explanation or preamble.
        """
    }
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String
    }
}
