import Foundation

enum APIError: Error, LocalizedError {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(statusCode: Int)
    case networkError(Error)
    case decodingError(Error)
    case noAPIKey
    case emptyTranscription
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Invalid API key. Please check your Groq API key in Settings."
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Retrying in \(Int(seconds))s..."
            }
            return "Rate limited. Please try again shortly."
        case .serverError(let code):
            return "Server error (\(code)). Please try again."
        case .networkError:
            return "No internet connection."
        case .decodingError:
            return "Failed to parse API response."
        case .noAPIKey:
            return "No API key configured. Open Settings to add your Groq API key."
        case .emptyTranscription:
            return "Couldn't detect speech. Try again."
        case .invalidResponse:
            return "Invalid response from API."
        }
    }
}
