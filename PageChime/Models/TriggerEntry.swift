import Foundation

struct TriggerEntry {
    let entity: String
    let soundID: String
    let eventType: StoryEventType
    let intensity: EffectIntensity
    let cooldownSeconds: TimeInterval
    let isAmbience: Bool
    let keywords: [String: [String]]
    let excludePatterns: [String: [String]]

    init(
        entity: String, soundID: String, eventType: StoryEventType,
        intensity: EffectIntensity, cooldownSeconds: TimeInterval,
        isAmbience: Bool, keywords: [String: [String]],
        excludePatterns: [String: [String]] = [:]
    ) {
        self.entity = entity
        self.soundID = soundID
        self.eventType = eventType
        self.intensity = intensity
        self.cooldownSeconds = cooldownSeconds
        self.isAmbience = isAmbience
        self.keywords = keywords
        self.excludePatterns = excludePatterns
    }
}
