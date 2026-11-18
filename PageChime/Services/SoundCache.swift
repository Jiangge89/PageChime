import Foundation

struct CacheEntry: Codable {
    let trigger: String
    let soundIDs: [String]
    var lastUsed: Date
}

final class SoundCache {
    private var buckets: [String: [CacheEntry]] = [:]
    private let fileURL: URL
    private let maxEntriesPerLanguage = 5_000
    private let saveDelay: TimeInterval = 2
    private let ioQueue = DispatchQueue(label: "com.pagechime.soundcache.io", qos: .utility)
    private var pendingSave: DispatchWorkItem?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sound_cache.json")
        load()
    }

    func lookup(text: String, language: ReadingLanguage) -> [String] {
        let normalized = Self.normalize(text, language: language)
        guard !normalized.isEmpty else { return [] }

        let key = language.rawValue
        guard var bucket = buckets[key] else { return [] }

        var matchedSounds: [String] = []
        var seen = Set<String>()
        let now = Date()
        var touched = false

        for i in bucket.indices {
            if normalized.contains(bucket[i].trigger) {
                for soundID in bucket[i].soundIDs where !seen.contains(soundID) {
                    matchedSounds.append(soundID)
                    seen.insert(soundID)
                }
                bucket[i].lastUsed = now
                touched = true
            }
        }

        if touched {
            buckets[key] = bucket
            scheduleSave()
        }
        return matchedSounds
    }

    func store(triggers: [LLMSoundMatch], language: ReadingLanguage) {
        let key = language.rawValue
        var bucket = buckets[key] ?? []
        var changed = false
        let now = Date()

        for match in triggers {
            let normalized = Self.normalize(match.trigger, language: language)
            guard normalized.count >= 2 else { continue }

            if let idx = bucket.firstIndex(where: { $0.trigger == normalized }) {
                if bucket[idx].soundIDs != [match.id] {
                    bucket[idx] = CacheEntry(trigger: normalized, soundIDs: [match.id], lastUsed: now)
                    changed = true
                }
            } else {
                bucket.append(CacheEntry(trigger: normalized, soundIDs: [match.id], lastUsed: now))
                changed = true
            }
        }

        if changed {
            if bucket.count > maxEntriesPerLanguage {
                bucket.sort { $0.lastUsed > $1.lastUsed }
                bucket = Array(bucket.prefix(maxEntriesPerLanguage))
            }
            buckets[key] = bucket
            scheduleSave()
        }
    }

    func reset() {
        buckets.removeAll()
        flush()
    }

    var count: Int { buckets.values.reduce(0) { $0 + $1.count } }

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

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: [CacheEntry]].self, from: data) else { return }
        buckets = decoded
    }

    /// Coalesces writes: usage timestamps change on every hit, so saving
    /// immediately would encode and write the whole cache on the main thread.
    private func scheduleSave() {
        guard pendingSave == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingSave = nil
            self?.flush()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    /// Writes the current state in the background.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = buckets
        let url = fileURL
        ioQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
