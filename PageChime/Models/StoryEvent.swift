import Foundation

struct StoryEvent: Identifiable, Equatable {
    let id: UUID
    let type: StoryEventType
    let entity: String
    let soundID: String
    let intensity: EffectIntensity
    let delayMilliseconds: Int
    let cooldownSeconds: TimeInterval
    let sourceText: String

    static func == (lhs: StoryEvent, rhs: StoryEvent) -> Bool {
        lhs.id == rhs.id
    }
}
