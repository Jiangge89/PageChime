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
                if let range = firstMatch(of: keyLower, in: lower, excludes: excludes, language: language) {
                    if isNegated(at: range, in: lower, language: language) {
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

    /// A keyword found in the text: the sound it sets off and where the
    /// keyword ends (in characters from the start of the text).
    struct Match {
        let soundID: String
        let end: Int
    }

    /// Every non-negated keyword occurrence, in text order. Unlike
    /// `analyze`, there's no cooldown: the caller tracks which occurrences
    /// it already played.
    func matches(in text: String, language: ReadingLanguage) -> [Match] {
        let lower = text.lowercased()
        var found: [(match: Match, start: Int)] = []
        for trigger in triggers {
            guard let keywords = trigger.keywords[language.rawValue] else { continue }
            let excludes = trigger.excludePatterns[language.rawValue]?.map { $0.lowercased() } ?? []
            var ends = Set<Int>()
            for keyword in keywords {
                for range in allMatches(of: keyword.lowercased(), in: lower, excludes: excludes, language: language)
                where !isNegated(at: range, in: lower, language: language) {
                    let end = lower.distance(from: lower.startIndex, to: range.upperBound)
                    // "dog" and "doggy" style overlaps count once.
                    guard ends.insert(end).inserted else { continue }
                    found.append((Match(soundID: trigger.soundID, end: end), lower.distance(from: lower.startIndex, to: range.lowerBound)))
                }
            }
        }
        return found.sorted { $0.start < $1.start }.map(\.match)
    }

    // MARK: - Keyword Matching

    private func firstMatch(
        of keyword: String, in text: String, excludes: [String], language: ReadingLanguage
    ) -> Range<String.Index>? {
        allMatches(of: keyword, in: text, excludes: excludes, language: language, limit: 1).first
    }

    /// Occurrences of `keyword` that aren't inside an exclude pattern.
    /// English keywords must start at a word boundary, so "then" doesn't
    /// match "hen" and "attic" doesn't match "tic".
    private func allMatches(
        of keyword: String, in text: String, excludes: [String], language: ReadingLanguage, limit: Int = .max
    ) -> [Range<String.Index>] {
        var results: [Range<String.Index>] = []
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
            if !isExcluded, language != .english || startsWord(range, in: text) {
                results.append(range)
                if results.count >= limit { break }
            }
            searchStart = text.index(after: range.lowerBound)
        }
        return results
    }

    private func startsWord(_ range: Range<String.Index>, in text: String) -> Bool {
        guard range.lowerBound > text.startIndex else { return true }
        return !text[text.index(before: range.lowerBound)].isLetter
    }

    // MARK: - Negation Detection

    private func isNegated(at keyRange: Range<String.Index>, in text: String, language: ReadingLanguage) -> Bool {
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
