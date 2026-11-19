import Foundation

/// Sends newly read text to the PageChime API, which asks the LLM for
/// one-shot sounds and the scene's ambience. The OpenAI key stays on the
/// server.
final class BackendSoundMatcher: SoundMatching, PageAnalyzing {
    private let backend: Backend?

    init(backend: Backend? = .shared) {
        self.backend = backend
    }

    func analyze(text: String, context: String) async throws -> SoundAnalysis {
        guard let backend else { throw BackendError.notConfigured }

        let body: [String: Any] = ["text": text, "context": context]
        let (status, json) = try await backend.authorized { token in
            try await backend.api.post("/v1/analyze", body: body, bearer: token)
        }
        guard status == 200 else { throw BackendError.http(status) }
        return try Self.parse(json)
    }

    func analyzePage(text: String, context: String) async throws -> PageAnalysis {
        guard let backend else { throw BackendError.notConfigured }

        let body: [String: Any] = ["text": text, "context": context]
        let (status, json) = try await backend.authorized { token in
            try await backend.pages.post("/v1/analyze-page", body: body, bearer: token)
        }
        guard status == 200 else { throw BackendError.http(status) }
        return Self.parsePage(json)
    }

    static func parsePage(_ json: [String: Any]) -> PageAnalysis {
        let cues = (json["cues"] as? [[String: Any]] ?? []).compactMap { item -> LLMSoundMatch? in
            guard let id = item["id"] as? String, let trigger = item["trigger"] as? String else { return nil }
            return LLMSoundMatch(id: id, trigger: trigger)
        }
        return PageAnalysis(
            cues: cues,
            ambience: json["ambience"] as? [String],
            upcoming: json["upcoming"] as? [String] ?? []
        )
    }

    /// Unknown ids are passed through; the view model only plays sounds the
    /// app or its sound library knows.
    static func parse(_ json: [String: Any]) throws -> SoundAnalysis {
        guard let sounds = json["sounds"] as? [[String: Any]] else { throw BackendError.invalidResponse }
        let matches = sounds.compactMap { item -> LLMSoundMatch? in
            guard let id = item["id"] as? String, let trigger = item["trigger"] as? String else { return nil }
            return LLMSoundMatch(id: id, trigger: trigger)
        }
        return SoundAnalysis(
            sounds: matches,
            ambience: json["ambience"] as? [String],
            upcoming: json["upcoming"] as? [String] ?? []
        )
    }
}
