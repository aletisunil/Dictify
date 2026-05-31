import Foundation

final class WhisperService: @unchecked Sendable {
    private let client: GroqClient

    init(client: GroqClient) {
        self.client = client
    }

    func transcribe(wavData: Data, dictionaryPrompt: String = "") async throws -> String {
        var formData = MultipartFormData()
        formData.append(file: wavData, name: "file", fileName: "recording.wav", mimeType: "audio/wav")
        formData.append(field: "model", value: Constants.API.whisperModel)
        formData.append(field: "response_format", value: "verbose_json")
        formData.append(field: "temperature", value: "0.0")

        if !dictionaryPrompt.isEmpty {
            formData.append(field: "prompt", value: dictionaryPrompt)
        }

        guard let url = URL(string: Constants.API.transcriptionEndpoint) else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(formData.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = formData.finalized

        let (data, _) = try await client.performRequest(request)

        let response = try JSONDecoder().decode(WhisperResponse.self, from: data)

        // Detect silence: if all segments have high no_speech_prob, Whisper is hallucinating
        if let segments = response.segments, !segments.isEmpty {
            let allSilent = segments.allSatisfy { ($0.no_speech_prob ?? 0) > 0.6 }
            if allSilent {
                throw APIError.emptyTranscription
            }
        }

        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            throw APIError.emptyTranscription
        }

        // Whisper can echo its `prompt` (our dictionary terms) into the output
        // on very short or ambiguous audio — e.g. saying "there" comes back as
        // the entire comma-separated dictionary. Strip that leakage so we only
        // insert the real word (or nothing, if the word was lost entirely).
        let cleaned = Self.stripPromptEcho(from: text, prompt: dictionaryPrompt)
        if cleaned.isEmpty {
            throw APIError.emptyTranscription
        }

        return cleaned
    }

    // MARK: - Prompt-echo stripping

    /// Removes leaked dictionary terms from a transcription. Only fires when the
    /// output is *dominated* by prompt terms (the leakage signature); a normal
    /// sentence that merely mentions a term or two is returned unchanged.
    static func stripPromptEcho(from text: String, prompt: String) -> String {
        guard !prompt.isEmpty else { return text }

        // Reconstruct individual terms from the prompt ("term (hint), term, …").
        let terms = prompt
            .components(separatedBy: ",")
            .map { component -> String in
                var t = component
                if let paren = t.firstIndex(of: "(") {
                    t = String(t[..<paren])
                }
                return t.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { $0.count >= 2 }
        guard !terms.isEmpty else { return text }

        let lowerText = text.lowercased()
        let matched = terms.filter { lowerText.contains($0.lowercased()) }
        guard matched.count >= 2 else { return text }

        // Strip the matched terms (whole-word, case-insensitive) and see what's
        // left. If the remainder is just a word or two, the output was leakage
        // and we keep the remainder; otherwise the terms were used naturally.
        let pattern = matched
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: "\\b(\(pattern))\\b", options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        let stripped = regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")

        let remainderWords = stripped
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)

        // Leakage signature: little to nothing survives once terms are removed.
        guard remainderWords.count <= 2 else { return text }
        return remainderWords.joined(separator: " ")
    }
}

private struct WhisperResponse: Decodable {
    let text: String
    let language: String?
    let duration: Double?
    let segments: [WhisperSegment]?
}

private struct WhisperSegment: Decodable {
    let id: Int
    let start: Double
    let end: Double
    let text: String
    let no_speech_prob: Double?
}
