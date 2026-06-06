import Foundation

final class GroqClient: @unchecked Sendable {
    private let session: URLSession
    private let keychainManager: KeychainManager
    private let maxRetries = 2
    private let backoffIntervals: [TimeInterval] = [1.0, 3.0]

    init(keychainManager: KeychainManager) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
        self.keychainManager = keychainManager
    }

    /// `URLSession.data(for:)` honours `Task.isCancelled`, so wrapping callers
    /// in a `Task` + calling `task.cancel()` cleanly aborts the request.
    func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let apiKey = keychainManager.getAPIKey(), !apiKey.isEmpty else {
            throw APIError.noAPIKey
        }

        var mutableRequest = request
        mutableRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // Non-sensitive request identity for logging: method + endpoint path only.
        // Never log the Authorization header, request body, or response payload.
        let method = request.httpMethod ?? "POST"
        let path = request.url?.path ?? "?"

        var lastError: Error = APIError.invalidResponse

        for attempt in 0...maxRetries {
            try Task.checkCancellation()
            let start = Date()
            do {
                let (data, response) = try await session.data(for: mutableRequest)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw APIError.invalidResponse
                }

                let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
                switch httpResponse.statusCode {
                case 200...299:
                    Log.api.notice("\(method, privacy: .public) \(path, privacy: .public) → \(httpResponse.statusCode, privacy: .public) in \(elapsedMs, privacy: .public)ms (attempt \(attempt + 1, privacy: .public))")
                    return (data, httpResponse)
                case 401:
                    Log.api.error("\(method, privacy: .public) \(path, privacy: .public) → 401 unauthorized (check API key)")
                    throw APIError.unauthorized
                case 429:
                    let retryAfter = Self.parseRetryAfter(httpResponse.value(forHTTPHeaderField: "Retry-After"))
                    if attempt < maxRetries {
                        let delay = retryAfter ?? backoffIntervals[min(attempt, backoffIntervals.count - 1)]
                        Log.api.notice("\(path, privacy: .public) → 429 rate limited; retrying in \(delay, privacy: .public)s")
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }
                    Log.api.error("\(path, privacy: .public) → 429 rate limited; retries exhausted")
                    throw APIError.rateLimited(retryAfter: retryAfter)
                case 500, 502, 503:
                    if attempt < maxRetries {
                        let delay = backoffIntervals[min(attempt, backoffIntervals.count - 1)]
                        Log.api.notice("\(path, privacy: .public) → \(httpResponse.statusCode, privacy: .public); retrying in \(delay, privacy: .public)s")
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }
                    Log.api.error("\(path, privacy: .public) → \(httpResponse.statusCode, privacy: .public); retries exhausted")
                    throw APIError.serverError(statusCode: httpResponse.statusCode)
                default:
                    Log.api.error("\(method, privacy: .public) \(path, privacy: .public) → \(httpResponse.statusCode, privacy: .public)")
                    throw APIError.serverError(statusCode: httpResponse.statusCode)
                }
            } catch is CancellationError {
                throw APIError.cancelled
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw APIError.cancelled
            } catch let error as APIError {
                throw error
            } catch {
                if attempt < maxRetries {
                    let delay = backoffIntervals[min(attempt, backoffIntervals.count - 1)]
                    Log.api.notice("\(path, privacy: .public) network error: \(error.localizedDescription, privacy: .public); retrying in \(delay, privacy: .public)s")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    lastError = error
                    continue
                }
                Log.api.error("\(path, privacy: .public) network error: \(error.localizedDescription, privacy: .public); retries exhausted")
                throw APIError.networkError(error)
            }
        }

        throw APIError.networkError(lastError)
    }

    /// Parses the `Retry-After` header. Supports both numeric-seconds form and
    /// the RFC 7231 HTTP-date form. Result clamped to [0, 60] seconds.
    static func parseRetryAfter(_ header: String?) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespacesAndNewlines),
              !header.isEmpty else { return nil }

        if let seconds = TimeInterval(header) {
            return max(0, min(60, seconds))
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        // RFC 7231 IMF-fixdate format
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy"
        ]
        for fmt in formats {
            formatter.dateFormat = fmt
            if let date = formatter.date(from: header) {
                let delta = date.timeIntervalSinceNow
                return max(0, min(60, delta))
            }
        }
        return nil
    }
}
