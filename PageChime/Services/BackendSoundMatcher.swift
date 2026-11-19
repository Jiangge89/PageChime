import Foundation

/// Sends newly read text to the PageChime API, which asks the LLM for
/// one-shot sounds and the scene's ambience. The OpenAI key stays on the
/// server.
final class BackendSoundMatcher: SoundMatching {
    private let http: BackendHTTP?
    private let sessions: SessionProviding?

    init(baseURL: URL? = AppConfig.backendURL, session: URLSession? = nil, sessions: SessionProviding? = nil) {
        guard let baseURL else {
            http = nil
            self.sessions = nil
            return
        }
        let http = BackendHTTP(baseURL: baseURL, session: session ?? Self.makeSession())
        self.http = http
        self.sessions = sessions ?? AppAttestSessionProvider(http: http)
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        // The server gives the model 5s; allow for the extra hop.
        config.timeoutIntervalForRequest = 6
        return URLSession(configuration: config)
    }

    func analyze(text: String, context: String) async throws -> SoundAnalysis {
        guard let http, let sessions else { throw BackendError.notConfigured }

        let body: [String: Any] = ["text": text, "context": context]
        var token = try await sessions.token()
        var (status, json) = try await http.post("/v1/analyze", body: body, bearer: token)

        if status == 401 {
            // Token expired or the server's secret changed: get a new one once.
            await sessions.invalidate(token)
            token = try await sessions.token()
            (status, json) = try await http.post("/v1/analyze", body: body, bearer: token)
        }
        guard status == 200 else { throw BackendError.http(status) }
        return try Self.parse(json)
    }

    static func parse(_ json: [String: Any]) throws -> SoundAnalysis {
        guard let sounds = json["sounds"] as? [[String: Any]] else { throw BackendError.invalidResponse }
        let matches = sounds.compactMap { item -> LLMSoundMatch? in
            guard let id = item["id"] as? String, let trigger = item["trigger"] as? String else { return nil }
            return LLMSoundMatch(id: id, trigger: trigger)
        }
        // Ignore ambience ids this app version doesn't have.
        let ambience = (json["ambience"] as? [String])?.filter { ambienceIDs.contains($0) }
        return SoundAnalysis(sounds: matches, ambience: ambience)
    }

    private static let ambienceIDs: Set<String> = Set(
        TriggerLibrary.defaultTriggers.filter(\.isAmbience).map(\.soundID)
    )
}
