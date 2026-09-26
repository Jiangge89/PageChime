import Foundation

final class StoryEventEngine {
    private let triggers: [TriggerEntry]
    private var cooldowns: [String: Date] = [:]
    private let maxEffectsPerSentence = 10

    var currentTime: () -> Date = { Date() }

    init(triggers: [TriggerEntry] = TriggerLibrary.defaultTriggers) {
        self.triggers = triggers
    }

    func analyze(text: String, language: ReadingLanguage) -> [StoryEvent] {
        let sentences = splitSentences(text)
        var allEvents: [StoryEvent] = []
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let events = analyzeSentence(trimmed, language: language)
            allEvents.append(contentsOf: events)
        }
        return allEvents
    }

    func reset() {
        cooldowns.removeAll()
    }

    // MARK: - Sentence Analysis

    private func analyzeSentence(_ sentence: String, language: ReadingLanguage) -> [StoryEvent] {
        let lower = sentence.lowercased()
        let isQuestion = isQuestionSentence(lower, language: language)

        let sortedTriggers = triggers.sorted { a, b in
            if a.isAmbience != b.isAmbience { return !a.isAmbience }
            return false
        }

        var events: [StoryEvent] = []
        var seenSounds: Set<String> = []

        for trigger in sortedTriggers {
            guard events.count < maxEffectsPerSentence else { break }
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

            let now = currentTime()
            if let lastFired = cooldowns[trigger.soundID],
               now.timeIntervalSince(lastFired) < trigger.cooldownSeconds {
                continue
            }

            let delay = isQuestion ? 1500 : 0

            let event = StoryEvent(
                id: UUID(),
                type: trigger.eventType,
                entity: trigger.entity,
                soundID: trigger.soundID,
                intensity: trigger.intensity,
                delayMilliseconds: delay,
                cooldownSeconds: trigger.cooldownSeconds,
                sourceText: sentence
            )

            events.append(event)
            seenSounds.insert(trigger.soundID)
            cooldowns[trigger.soundID] = now
        }

        return events
    }

    // MARK: - Sentence Splitting

    private func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let terminators: Set<Character> = [".", "!", "?", "。", "！", "？"]

        for char in text {
            current.append(char)
            if terminators.contains(char) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sentences.append(current)
        }
        return sentences
    }

    // MARK: - Question Detection

    private func isQuestionSentence(_ text: String, language: ReadingLanguage) -> Bool {
        switch language {
        case .english:
            if text.contains("?") { return true }
            let starters = ["what ", "how ", "does ", "do ", "can ", "is ", "where ", "why ", "who "]
            return starters.contains { text.hasPrefix($0) }
        case .chinese:
            let markers = ["？", "吗", "呢", "怎么", "什么"]
            return markers.contains { text.contains($0) }
        }
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

}
