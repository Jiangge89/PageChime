import Foundation

/// Shared connection to the PageChime API: one session provider for the
/// analysis client and the sound library, so they share a session token.
final class Backend {
    /// Nil when no backend URL is configured (keyword matching only).
    static let shared: Backend? = AppConfig.backendURL.map { Backend(baseURL: $0) }

    /// Short timeout: analysis results are useless after a few seconds.
    let api: BackendHTTP
    /// Longer timeout for library and audio downloads.
    let downloads: BackendHTTP
    let sessions: SessionProviding

    init(
        baseURL: URL,
        apiSession: URLSession? = nil,
        downloadSession: URLSession? = nil,
        sessions: SessionProviding? = nil
    ) {
        api = BackendHTTP(baseURL: baseURL, session: apiSession ?? Self.makeSession(timeout: 6))
        downloads = BackendHTTP(baseURL: baseURL, session: downloadSession ?? Self.makeSession(timeout: 30))
        self.sessions = sessions ?? AppAttestSessionProvider(http: api)
    }

    private static func makeSession(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.default
        // The server gives the model 5s; the API timeout allows for the extra hop.
        config.timeoutIntervalForRequest = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    /// Runs an authorized request, getting a fresh token once if the server
    /// rejects the current one.
    func authorized<T>(_ request: (String) async throws -> (Int, T)) async throws -> (Int, T) {
        let token = try await sessions.token()
        let result = try await request(token)
        guard result.0 == 401 else { return result }
        await sessions.invalidate(token)
        return try await request(try await sessions.token())
    }
}
