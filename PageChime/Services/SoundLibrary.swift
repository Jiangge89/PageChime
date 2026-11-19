import Foundation

enum SoundKind: String, Codable {
    case oneShot
    case ambience
}

struct LibraryVariant: Codable, Hashable {
    let file: String
    let duration: Double
    let bytes: Int
}

struct LibrarySound: Codable {
    let id: String
    let kind: SoundKind
    let name: String
    let description: String
    let category: String
    let variants: [LibraryVariant]
}

struct LibraryManifest: Codable {
    let version: Int
    let sounds: [LibrarySound]

    static let empty = LibraryManifest(version: 0, sounds: [])
}

/// What the app needs to know to play a sound ID.
struct SoundInfo: Equatable {
    let isAmbience: Bool
    let type: StoryEventType
    let entity: String
    let intensity: EffectIntensity
}

protocol SoundCatalogProviding: AnyObject {
    /// Nil for sound IDs neither bundled nor in the cloud library.
    func info(for soundID: String) -> SoundInfo?
    /// Lowercased names of cloud one-shots ("wolf", "dragon"): words worth
    /// sending to the LLM straight away, since only it can pick those sounds.
    func cloudSoundNames() -> Set<String>
}

extension SoundCatalogProviding {
    func cloudSoundNames() -> Set<String> { [] }
}

/// Audio files for sounds in the cloud library.
protocol CloudSoundSource: AnyObject {
    /// A downloaded variant, picked at random but not the one played last.
    /// Nil if none is downloaded yet.
    func localFile(for soundID: String) -> URL?
    /// Downloads a variant (one not yet on disk, if any) and returns its file.
    func fetchFile(for soundID: String) async throws -> URL
    /// Whether the sound is in the cloud library at all.
    func hasCloudVariants(_ soundID: String) -> Bool
}

protocol SoundPrefetching: AnyObject {
    /// Downloads, in the background, one variant of each cloud sound that has
    /// none on disk yet, so it can play the moment the story reaches it.
    /// Returns the IDs newly queued.
    @discardableResult
    func prefetch(_ soundIDs: [String]) -> [String]
}

/// Bundled sounds only (from `TriggerLibrary`).
final class BundledSoundCatalog: SoundCatalogProviding {
    static let shared = BundledSoundCatalog()

    private let triggers: [String: TriggerEntry] = Dictionary(
        uniqueKeysWithValues: TriggerLibrary.defaultTriggers.map { ($0.soundID, $0) }
    )

    func info(for soundID: String) -> SoundInfo? {
        guard let trigger = triggers[soundID] else { return nil }
        return SoundInfo(
            isAmbience: trigger.isAmbience, type: trigger.eventType,
            entity: trigger.entity, intensity: trigger.intensity
        )
    }
}

/// The cloud sound library: the manifest from `/v1/library` plus audio files
/// downloaded on demand into a size-capped disk cache.
///
/// The manifest is kept on disk so the library works offline with whatever
/// was downloaded before. Files are content-addressed and never change, so a
/// file on disk is always valid.
final class SoundLibrary: SoundCatalogProviding, CloudSoundSource, SoundPrefetching {
    static let shared = SoundLibrary(backend: .shared)

    private let backend: Backend?
    private let manifestURL: URL
    private let cacheDirectory: URL
    private let maxCacheBytes: Int
    private let fileManager = FileManager.default
    private let bundled = BundledSoundCatalog.shared

    private let lock = NSLock()
    private var manifest: LibraryManifest = .empty
    private var etag: String?
    private var soundsByID: [String: LibrarySound] = [:]
    private var oneShotNames: Set<String> = []
    private var lastFile: [String: String] = [:]
    private var inFlight: [String: Task<URL, Error>] = [:]

    /// Prefetches wait here and run a few at a time, so they don't compete
    /// with downloads for sounds that are about to play.
    private var prefetchQueue: [String] = []
    private var prefetchPending: Set<String> = []
    private var activePrefetches = 0
    private let maxConcurrentPrefetches = 2
    private let maxQueuedPrefetches = 12

    private struct Stored: Codable {
        let etag: String?
        let manifest: LibraryManifest
    }

    init(
        backend: Backend?,
        directory: URL? = nil,
        cacheDirectory: URL? = nil,
        maxCacheBytes: Int = 200 * 1024 * 1024
    ) {
        self.backend = backend
        let support = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SoundLibrary", isDirectory: true)
        manifestURL = support.appendingPathComponent("library.json")
        self.cacheDirectory = cacheDirectory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SoundLibrary", isDirectory: true)
        self.maxCacheBytes = maxCacheBytes

        try? fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: manifestURL),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            apply(stored.manifest, etag: stored.etag)
        }
    }

    var version: Int { lock.withLock { manifest.version } }

    func sound(_ soundID: String) -> LibrarySound? {
        lock.withLock { soundsByID[soundID] }
    }

    // MARK: - Manifest

    /// Fetches the latest manifest. Errors are ignored: the stored manifest
    /// keeps working.
    func refresh() async {
        guard let backend else { return }
        let currentEtag = lock.withLock { etag }
        guard let (status, result) = try? await backend.authorized({ token in
            try await backend.downloads.get(
                "/v1/library", bearer: token,
                headers: currentEtag.map { ["If-None-Match": $0] } ?? [:]
            )
        }) else { return }
        guard status == 200,
              let manifest = try? JSONDecoder().decode(LibraryManifest.self, from: result.data)
        else { return }

        let newEtag = result.response.value(forHTTPHeaderField: "ETag")
        apply(manifest, etag: newEtag)
        if let data = try? JSONEncoder().encode(Stored(etag: newEtag, manifest: manifest)) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    private func apply(_ manifest: LibraryManifest, etag: String?) {
        lock.withLock {
            self.manifest = manifest
            self.etag = etag
            soundsByID = Dictionary(manifest.sounds.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            oneShotNames = Set(manifest.sounds.filter { $0.kind == .oneShot }.flatMap {
                $0.name.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            })
        }
    }

    // MARK: - SoundCatalogProviding

    func info(for soundID: String) -> SoundInfo? {
        if let info = bundled.info(for: soundID) { return info }
        guard let sound = sound(soundID) else { return nil }
        return SoundInfo(
            isAmbience: sound.kind == .ambience,
            type: StoryEventType(rawValue: sound.category) ?? .environment,
            entity: sound.name,
            intensity: .normal
        )
    }

    func cloudSoundNames() -> Set<String> {
        lock.withLock { oneShotNames }
    }

    // MARK: - CloudSoundSource

    func hasCloudVariants(_ soundID: String) -> Bool {
        !(sound(soundID)?.variants.isEmpty ?? true)
    }

    func localFile(for soundID: String) -> URL? {
        guard let sound = sound(soundID) else { return nil }
        let downloaded = sound.variants.filter { fileManager.fileExists(atPath: fileURL($0.file).path) }
        guard !downloaded.isEmpty else { return nil }

        let previous = lock.withLock { lastFile[soundID] }
        let choices = downloaded.count > 1 ? downloaded.filter { $0.file != previous } : downloaded
        let variant = choices.randomElement()!
        lock.withLock { lastFile[soundID] = variant.file }
        touch(fileURL(variant.file))

        // Variety grows with use: fetch another variant in the background.
        if downloaded.count < sound.variants.count {
            Task { _ = try? await fetchFile(for: soundID) }
        }
        return fileURL(variant.file)
    }

    func fetchFile(for soundID: String) async throws -> URL {
        guard let sound = sound(soundID), !sound.variants.isEmpty else { throw BackendError.invalidResponse }
        let missing = sound.variants.filter { !fileManager.fileExists(atPath: fileURL($0.file).path) }
        guard let variant = missing.randomElement() else {
            return localFile(for: soundID)!
        }
        return try await download(variant.file)
    }

    // MARK: - SoundPrefetching

    @discardableResult
    func prefetch(_ soundIDs: [String]) -> [String] {
        var unique: [String] = []
        for id in soundIDs where !unique.contains(id) && hasCloudVariants(id) && !hasDownloadedVariant(id) {
            unique.append(id)
        }
        let queued = lock.withLock { () -> [String] in
            let new = unique.filter { !prefetchPending.contains($0) }
            prefetchQueue += new
            prefetchPending.formUnion(new)
            // The story has moved on from the oldest requests; drop them.
            while prefetchQueue.count > maxQueuedPrefetches {
                prefetchPending.remove(prefetchQueue.removeFirst())
            }
            return new
        }
        startPrefetches()
        return queued
    }

    private func hasDownloadedVariant(_ soundID: String) -> Bool {
        sound(soundID)?.variants.contains { fileManager.fileExists(atPath: fileURL($0.file).path) } ?? false
    }

    private func startPrefetches() {
        let next = lock.withLock { () -> [String] in
            var started: [String] = []
            while activePrefetches < maxConcurrentPrefetches, !prefetchQueue.isEmpty {
                started.append(prefetchQueue.removeFirst())
                activePrefetches += 1
            }
            return started
        }
        for soundID in next {
            Task { [weak self] in
                guard let self else { return }
                if !self.hasDownloadedVariant(soundID) {
                    _ = try? await self.fetchFile(for: soundID)
                }
                self.lock.withLock {
                    self.activePrefetches -= 1
                    self.prefetchPending.remove(soundID)
                }
                self.startPrefetches()
            }
        }
    }

    // MARK: - Downloads

    private func fileURL(_ file: String) -> URL {
        cacheDirectory.appendingPathComponent(file)
    }

    /// Downloads a file once, however many callers ask for it at the same time.
    private func download(_ file: String) async throws -> URL {
        let task = lock.withLock { () -> Task<URL, Error> in
            if let existing = inFlight[file] { return existing }
            let task = makeDownloadTask(file)
            inFlight[file] = task
            return task
        }
        defer { lock.withLock { inFlight[file] = nil } }
        return try await task.value
    }

    private func makeDownloadTask(_ file: String) -> Task<URL, Error> {
        Task { [self] () throws -> URL in
            guard let backend else { throw BackendError.notConfigured }
            let (status, temp) = try await backend.authorized { token in
                try await backend.downloads.download("/v1/sounds/\(file)", bearer: token)
            }
            guard status == 200 else { throw BackendError.http(status) }

            let destination = fileURL(file)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: temp, to: destination)
            evictIfNeeded(keeping: destination)
            return destination
        }
    }

    private func touch(_ url: URL) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Deletes least recently used files until the cache fits.
    private func evictIfNeeded(keeping kept: URL) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: keys
        ) else { return }

        var entries = files.compactMap { url -> (url: URL, size: Int, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > maxCacheBytes else { return }

        entries.sort { $0.date < $1.date }
        for entry in entries where total > maxCacheBytes && entry.url.lastPathComponent != kept.lastPathComponent {
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
