import Foundation

struct TriggerEntry {
    let entity: String
    let soundID: String
    let eventType: StoryEventType
    let intensity: EffectIntensity
    let cooldownSeconds: TimeInterval
    let isAmbience: Bool
    let keywords: [String: [String]]
}
