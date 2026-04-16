import Foundation

final class GroqClient: @unchecked Sendable {
    private let session: URLSession
    private let keychainManager: KeychainManager
    private let maxRetries = 2
    private let backoffIntervals: [TimeInterval] = [1.0, 3.0]

    init(keychainManager: KeychainManager) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
        self.keychainManager = keychainManager
    }

    func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let apiKey = keychainManager.getAPIKey(), !apiKey.isEmpty else {
            throw APIError.noAPIKey
        }

        var mutableRequest = request
        mutableRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var lastError: Error = APIError.invalidResponse

        for attempt in 0...maxRetries {
            do {
                let (data, response) = try await session.data(for: mutableRequest)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw APIError.invalidResponse
                }

                switch httpResponse.statusCode {
                case 200...299:
                    return (data, httpResponse)
                case 401:
                    throw APIError.unauthorized
                case 429:
                    let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                        .flatMap { TimeInterval($0) }
                    if attempt < maxRetries {
                        let delay = retryAfter ?? backoffIntervals[min(attempt, backoffIntervals.count - 1)]
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }
                    throw APIError.rateLimited(retryAfter: retryAfter)
                case 500, 502, 503:
                    if attempt < maxRetries {
                        let delay = backoffIntervals[min(attempt, backoffIntervals.count - 1)]
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }
                    throw APIError.serverError(statusCode: httpResponse.statusCode)
                default:
                    throw APIError.serverError(statusCode: httpResponse.statusCode)
                }
            } catch let error as APIError {
                throw error
            } catch {
                if attempt < maxRetries {
                    let delay = backoffIntervals[min(attempt, backoffIntervals.count - 1)]
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    lastError = error
                    continue
                }
                throw APIError.networkError(error)
            }
        }

        throw APIError.networkError(lastError)
    }
}
