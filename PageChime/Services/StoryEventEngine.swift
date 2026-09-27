import Foundation

final class StoryEventEngine {
    private let triggers: [TriggerEntry]
    private var cooldowns: [String: Date] = [:]
    private let cooldownInterval: TimeInterval = 3

    var currentTime: () -> Date = { Date() }

    init(triggers: [TriggerEntry] = TriggerLibrary.defaultTriggers) {
        self.triggers = triggers
    }

    func analyze(text: String, language: ReadingLanguage) -> [StoryEvent] {
        let lower = text.lowercased()
        let now = currentTime()
        var events: [StoryEvent] = []
        var seenSounds: Set<String> = []

        for trigger in triggers {
            guard !seenSounds.contains(trigger.soundID) else { continue }

            let langKey = language.rawValue
            guard let keywords = trigger.keywords[langKey] else { continue }
            let excludes = trigger.excludePatterns[langKey]?.map { $0.lowercased() } ?? []

            var matched = false
            for keyword in keywords {
                let keyLower = keyword.lowercased()
                if matchesKeyword(keyLower, in: lower, excludes: excludes) {
                    if isNegated(keyword: keyLower, in: lower, language: language) {
                        continue
                    }
                    matched = true
                    break
                }
            }

            guard matched else { continue }

            if let lastFired = cooldowns[trigger.soundID],
               now.timeIntervalSince(lastFired) < cooldownInterval {
                continue
            }

            events.append(StoryEvent(
                id: UUID(),
                type: trigger.eventType,
                entity: trigger.entity,
                soundID: trigger.soundID,
                intensity: trigger.intensity,
                delayMilliseconds: 0,
                cooldownSeconds: cooldownInterval,
                sourceText: text
            ))
            seenSounds.insert(trigger.soundID)
            cooldowns[trigger.soundID] = now
        }

        return events
    }

    func reset() {
        cooldowns.removeAll()
    }

    // MARK: - Keyword Matching

    private func matchesKeyword(_ keyword: String, in text: String, excludes: [String]) -> Bool {
        guard !excludes.isEmpty else { return text.contains(keyword) }

        var excludedRanges: [Range<String.Index>] = []
        for exclude in excludes {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(of: exclude, range: searchStart..<text.endIndex) {
                excludedRanges.append(range)
                searchStart = range.upperBound
            }
        }

        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: keyword, range: searchStart..<text.endIndex) {
            let isExcluded = excludedRanges.contains { excludeRange in
                range.lowerBound >= excludeRange.lowerBound && range.upperBound <= excludeRange.upperBound
            }
            if !isExcluded { return true }
            searchStart = range.upperBound
        }
        return false
    }

    // MARK: - Negation Detection

    private func isNegated(keyword: String, in text: String, language: ReadingLanguage) -> Bool {
        guard let keyRange = text.range(of: keyword) else { return false }

        switch language {
        case .english:
            let negations = ["not ", " not", "n't ", "never ", "without ", "no "]
            let start = text.index(keyRange.lowerBound, offsetBy: -15, limitedBy: text.startIndex) ?? text.startIndex
            let prefix = String(text[start..<keyRange.lowerBound])
            return negations.contains { prefix.contains($0) }
        case .chinese:
            let negations = ["没有", "不会", "不是", "不", "没", "别", "无"]
            let start = text.index(keyRange.lowerBound, offsetBy: -5, limitedBy: text.startIndex) ?? text.startIndex
            let prefix = String(text[start..<keyRange.lowerBound])
            return negations.contains { prefix.contains($0) }
        }
    }
}
