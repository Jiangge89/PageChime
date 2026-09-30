import Foundation

struct LLMSoundMatch {
    let id: String
    let trigger: String
}

enum LLMError: Error {
    case noAPIKey
    case apiError(Int)
    case parseError
}

final class LLMService {
    private let apiKey: String
    private let systemPrompt: String
    private let session: URLSession

    init() {
        self.apiKey = Secrets.openAIKey

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        self.session = URLSession(configuration: config)

        self.systemPrompt = """
        You are a children's story sound effect assistant. Given text from a story being read aloud, determine which sound effects should play.

        Available sounds:
        \(Self.soundCatalog)

        Rules:
        - Only return sounds directly related to what's happening in the text
        - For negated events (e.g. "没有狗", "not a dog"), do NOT include that sound
        - Return JSON: {"sounds": [{"id": "sound_id", "trigger": "shortest phrase from the text that identifies this sound"}]}
        - "trigger" must be a short substring copied from the input text (not invented), just enough to unambiguously identify the sound
        - If nothing matches, return {"sounds": []}
        - At most 5 sounds per response
        """
    }

    func analyze(text: String) async throws -> [LLMSoundMatch] {
        guard !apiKey.isEmpty else { throw LLMError.noAPIKey }

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
            "temperature": 0,
            "max_tokens": 100,
            "response_format": ["type": "json_object"],
        ]

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw LLMError.apiError(code)
        }

        return try parseSoundMatches(from: data)
    }

    private func parseSoundMatches(from data: Data) throws -> [LLMSoundMatch] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let contentData = content.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: contentData) as? [String: Any],
              let sounds = parsed["sounds"] as? [[String: String]]
        else {
            throw LLMError.parseError
        }
        return sounds.compactMap { dict in
            guard let id = dict["id"], let trigger = dict["trigger"] else { return nil }
            return LLMSoundMatch(id: id, trigger: trigger)
        }
    }

    private static let soundCatalog: String = {
        let descriptions: [(String, String)] = [
            ("dog_bark", "dog barking"),
            ("cat_meow", "cat meowing"),
            ("frog_croak", "frog croaking"),
            ("cow_moo", "cow mooing"),
            ("sheep_baa", "sheep or goat bleating"),
            ("lion_roar", "lion roaring"),
            ("elephant_trumpet", "elephant trumpeting"),
            ("bird_chirp", "bird chirping or singing"),
            ("owl_hoot", "owl hooting"),
            ("duck_quack", "duck quacking"),
            ("chicken_cluck", "chicken or rooster"),
            ("horse_neigh", "horse neighing or galloping"),
            ("squirrel_chirp", "squirrel chirping"),
            ("dinosaur_roar", "dinosaur roaring"),
            ("whale_call", "whale singing"),
            ("tiger_roar", "tiger roaring or growling"),
            ("monkey_call", "monkey calling"),
            ("fox_bark", "fox barking"),
            ("zebra_call", "zebra calling"),
            ("giraffe_hum", "giraffe humming"),
            ("mouse_squeak", "mouse squeaking"),
            ("rain_light", "rain falling"),
            ("thunder", "thunder rumbling"),
            ("wind", "wind blowing"),
            ("storm", "thunderstorm"),
            ("door_knock", "knocking on door"),
            ("door_open", "door opening"),
            ("door_slam", "door slamming shut"),
            ("footsteps", "footsteps or walking"),
            ("running", "running footsteps"),
            ("water_splash", "water splashing"),
            ("bell", "bell ringing"),
            ("clock_tick", "clock ticking"),
            ("laughter", "laughing"),
            ("child_crying", "child crying or sobbing"),
            ("waves_crashing", "ocean waves crashing"),
            ("children_playing", "children playing and laughing"),
            ("car", "car engine or driving"),
            ("train", "train moving or whistle"),
            ("airplane", "airplane flying"),
            ("helicopter", "helicopter flying"),
            ("boat", "small boat on water"),
            ("ship_horn", "ship horn or foghorn"),
            ("bus", "bus engine"),
            ("subway", "subway or metro train"),
            ("tractor", "tractor engine"),
            ("bulldozer", "bulldozer working"),
            ("harvester", "harvester or combine"),
            ("drill", "electric drill"),
            ("excavator", "excavator or digger"),
            ("police_siren", "police car siren"),
            ("ambulance_siren", "ambulance siren"),
            ("fire_truck_siren", "fire truck siren"),
            ("forest_ambience", "forest atmosphere with birds and insects"),
            ("ocean_waves", "ocean or sea atmosphere"),
            ("night_ambience", "nighttime crickets and quiet"),
            ("farm_ambience", "farm atmosphere with animals"),
            ("wind_trees", "wind rustling through trees and leaves"),
        ]
        return descriptions.map { "- \($0.0): \($0.1)" }.joined(separator: "\n")
    }()
}
