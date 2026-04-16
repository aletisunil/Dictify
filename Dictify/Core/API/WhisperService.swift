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

        return text
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
