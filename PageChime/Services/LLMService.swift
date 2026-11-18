import Foundation

struct LLMSoundMatch {
    let id: String
    let trigger: String
}

struct SoundAnalysis {
    /// Sounds triggered by the new text.
    let sounds: [LLMSoundMatch]
    /// Ambience beds for the current scene, or nil if the scene is unchanged.
    let ambience: [String]?
}

enum LLMError: Error {
    case noAPIKey
    case apiError(Int)
    case parseError
}

protocol SoundMatching: AnyObject {
    /// - Parameters:
    ///   - text: Newly read text.
    ///   - context: The story read just before it, for understanding the scene.
    func analyze(text: String, context: String) async throws -> SoundAnalysis
}

final class LLMService: SoundMatching {
    private let apiKey: String
    private let systemPrompt: String
    private let session: URLSession

    init() {
        self.apiKey = Secrets.openAIKey

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        self.session = URLSession(configuration: config)

        self.systemPrompt = """
        You add sound effects, in real time, to a children's story that a parent is reading aloud. \
        You receive the story read so far (context) and the newly read text.

        One-shot sounds (play once when the new text describes them happening):
        \(Self.catalog(ambience: false))

        Ambience beds (looping background for the current setting):
        \(Self.catalog(ambience: true))

        Return JSON: {"sounds": [{"id": "sound_id", "trigger": "phrase"}], "ambience": ["sound_id"] or null}

        Rules:
        - "sounds": one-shots for things happening in the NEW text only, never for things only in the context. \
        Skip negated events (e.g. "not a dog", "没有狗"). At most 4.
        - "trigger": the shortest phrase copied verbatim from the new text that identifies the sound.
        - "ambience": 0-3 ambience ids for where the story is at the end of the new text. Use the context to \
        understand the setting, and keep the same set while the setting doesn't change. Return null if the new \
        text says nothing about the setting. Return [] only if the story clearly moves somewhere quiet.
        - Only use ids from the lists above.
        """
    }

    func analyze(text: String, context: String) async throws -> SoundAnalysis {
        guard !apiKey.isEmpty else { throw LLMError.noAPIKey }

        let userContent = context.isEmpty
            ? "New text: \(text)"
            : "Story so far: \(context)\n\nNew text: \(text)"

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent],
            ],
            "temperature": 0,
            "max_tokens": 150,
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

        return try parseAnalysis(from: data)
    }

    private func parseAnalysis(from data: Data) throws -> SoundAnalysis {
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
        let matches = sounds.compactMap { dict -> LLMSoundMatch? in
            guard let id = dict["id"], let trigger = dict["trigger"] else { return nil }
            return LLMSoundMatch(id: id, trigger: trigger)
        }
        let ambience = (parsed["ambience"] as? [String])?.filter { Self.ambienceIDs.contains($0) }
        return SoundAnalysis(sounds: matches, ambience: ambience)
    }

    private static let ambienceIDs: Set<String> = Set(
        TriggerLibrary.defaultTriggers.filter(\.isAmbience).map(\.soundID)
    )

    private static func catalog(ambience: Bool) -> String {
        soundDescriptions
            .filter { ambienceIDs.contains($0.0) == ambience }
            .map { "- \($0.0): \($0.1)" }
            .joined(separator: "\n")
    }

    private static let soundDescriptions: [(String, String)] = {
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
            ("rain_light", "rain falling, rainy weather"),
            ("thunder", "thunder rumbling"),
            ("wind", "wind blowing"),
            ("storm", "thunderstorm, heavy rain and wind"),
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
        return descriptions
    }()
}
