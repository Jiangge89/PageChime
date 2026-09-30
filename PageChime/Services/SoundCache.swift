import Foundation

struct CacheEntry: Codable {
    let trigger: String
    let soundIDs: [String]
    let language: String
    var lastUsed: Date
}

final class SoundCache {
    private var entries: [CacheEntry] = []
    private let fileURL: URL
    private let maxEntries = 500_000

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("sound_cache.json")
        load()
    }

    func lookup(text: String, language: ReadingLanguage) -> [String] {
        let normalized = Self.normalize(text, language: language)
        guard !normalized.isEmpty else { return [] }

        var matchedSounds: [String] = []
        var seen = Set<String>()
        let now = Date()
        var touched = false

        for i in entries.indices where entries[i].language == language.rawValue {
            if normalized.contains(entries[i].trigger) {
                for soundID in entries[i].soundIDs where !seen.contains(soundID) {
                    matchedSounds.append(soundID)
                    seen.insert(soundID)
                }
                entries[i].lastUsed = now
                touched = true
            }
        }

        if touched { save() }
        return matchedSounds
    }

    func store(triggers: [LLMSoundMatch], language: ReadingLanguage) {
        var changed = false
        let now = Date()

        for match in triggers {
            let normalized = Self.normalize(match.trigger, language: language)
            guard normalized.count >= 2 else { continue }

            if let idx = entries.firstIndex(where: { $0.trigger == normalized && $0.language == language.rawValue }) {
                if entries[idx].soundIDs != [match.id] {
                    entries[idx] = CacheEntry(trigger: normalized, soundIDs: [match.id], language: language.rawValue, lastUsed: now)
                    changed = true
                }
            } else {
                entries.append(CacheEntry(trigger: normalized, soundIDs: [match.id], language: language.rawValue, lastUsed: now))
                changed = true
            }
        }

        if changed {
            evictIfNeeded()
            save()
        }
    }

    func reset() {
        entries.removeAll()
        save()
    }

    var count: Int { entries.count }

    static func normalize(_ text: String, language: ReadingLanguage) -> String {
        var result = text
        let remove = CharacterSet.punctuationCharacters
            .union(.whitespaces)
            .union(.newlines)
        result = String(result.unicodeScalars.filter { !remove.contains($0) })
        if language == .english {
            result = result.lowercased()
        }
        return result
    }

    // MARK: - LRU Eviction

    private func evictIfNeeded() {
        guard entries.count > maxEntries else { return }
        entries.sort { $0.lastUsed > $1.lastUsed }
        entries = Array(entries.prefix(maxEntries))
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([CacheEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
