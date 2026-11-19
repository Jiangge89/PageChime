import AVFoundation
import XCTest
@testable import PageChime

final class SoundEffectPlayerTests: XCTestCase {
    func testEveryTriggerSoundLoadsIntoEngineFormat() {
        let cache = AudioBufferCache(preload: false)
        for trigger in TriggerLibrary.defaultTriggers {
            let buffer = cache.buffer(for: trigger.soundID)
            XCTAssertNotNil(buffer, "\(trigger.soundID) failed to load")
            XCTAssertGreaterThan(buffer?.frameLength ?? 0, 0, trigger.soundID)
            XCTAssertEqual(buffer?.format, cache.format, trigger.soundID)
        }
    }

    func testBuffersAreConvertedToRequestedFormat() throws {
        let stereo = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let native = AudioBufferCache(preload: false).buffer(for: "dog_bark")
        let converted = AudioBufferCache(format: stereo, preload: false).buffer(for: "dog_bark")

        XCTAssertEqual(converted?.format, stereo)
        let ratio = Double(converted?.frameLength ?? 0) / Double(native?.frameLength ?? 1)
        XCTAssertEqual(ratio, 2, accuracy: 0.05)
    }

    func testSceneReplacesAmbienceBeds() {
        let player = SoundEffectPlayer(buffers: AudioBufferCache(preload: false), catalog: BundledSoundCatalog.shared, cloud: nil)
        defer { player.stopAll() }

        player.setAmbience([event("forest_ambience"), event("night_ambience")])
        XCTAssertEqual(player.activeAmbienceIDs, ["forest_ambience", "night_ambience"])

        player.setAmbience([event("ocean_waves")])
        XCTAssertEqual(player.activeAmbienceIDs, ["ocean_waves"], "Old beds should be fading out")
    }

    func testAmbienceIsCappedAtMaxBeds() {
        let player = SoundEffectPlayer(buffers: AudioBufferCache(preload: false), catalog: BundledSoundCatalog.shared, cloud: nil)
        defer { player.stopAll() }

        for id in ["forest_ambience", "night_ambience", "ocean_waves", "farm_ambience"] {
            player.play(event: event(id))
        }
        XCTAssertEqual(player.activeAmbienceIDs.count, SoundEffectPlayer.maxBeds)
        XCTAssertTrue(player.activeAmbienceIDs.contains("farm_ambience"), "Newest bed should replace the oldest")
    }

    /// Background sounds don't expire on a timer: they hold while reading
    /// goes on and fade only once the reader has been quiet for a while.
    func testBackgroundSoundHoldsWhileReadingAndFadesWhenQuiet() {
        let player = SoundEffectPlayer(buffers: AudioBufferCache(preload: false), catalog: BundledSoundCatalog.shared, cloud: nil)
        defer { player.stopAll() }
        player.quietTimeout = 0.5
        player.setAmbience([event("rain_light")])

        // Reading continues well past the quiet timeout.
        for _ in 0..<8 {
            player.noteSpeechActivity()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(player.activeAmbienceIDs, ["rain_light"], "Still the same scene, still reading")

        // The book is put down.
        RunLoop.main.run(until: Date().addingTimeInterval(0.9))
        XCTAssertTrue(player.activeAmbienceIDs.isEmpty, "Fades once nobody has read for the quiet timeout")
    }

    func testStopAllClearsAmbience() {
        let player = SoundEffectPlayer(buffers: AudioBufferCache(preload: false), catalog: BundledSoundCatalog.shared, cloud: nil)
        player.setAmbience([event("rain_light")])
        player.play(event: event("thunder"))
        player.stopAll()
        XCTAssertTrue(player.activeAmbienceIDs.isEmpty)
    }

    // MARK: - Cloud sounds

    private func cloudPlayer(_ cloud: FakeCloud) -> SoundEffectPlayer {
        SoundEffectPlayer(buffers: AudioBufferCache(preload: false), catalog: cloud, cloud: cloud)
    }

    private func toneFile(seconds: Double, sampleRate: Double = 44100, channels: AVAudioChannelCount = 2) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID().uuidString).m4a")
        try writeTestTone(to: url, seconds: seconds, sampleRate: sampleRate, channels: channels)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testDownloadedCloudAmbienceStreamsAndLoopsWithCrossfade() async throws {
        let cloud = FakeCloud()
        cloud.add("cave_drips", ambience: true, file: try toneFile(seconds: 1.2), downloaded: true)
        let player = cloudPlayer(cloud)
        defer { player.stopAll() }

        player.play(event: event("cave_drips"))
        XCTAssertEqual(player.streamedAmbienceIDs, ["cave_drips"])

        // A 1.2s file crossfades into itself every ~0.9s.
        try await waitUntil(timeout: 5) { player.completedLoops >= 2 }
        XCTAssertEqual(player.activeAmbienceIDs, ["cave_drips"])
    }

    func testCloudAmbienceStartsAfterDownload() async throws {
        let cloud = FakeCloud()
        cloud.add("cave_drips", ambience: true, file: try toneFile(seconds: 3), downloaded: false)
        cloud.fetchDelay = 0.2
        let player = cloudPlayer(cloud)
        defer { player.stopAll() }

        player.setAmbience([event("cave_drips")])
        XCTAssertTrue(player.activeAmbienceIDs.isEmpty)
        try await waitUntil { player.streamedAmbienceIDs == ["cave_drips"] }
    }

    func testAmbienceLeftTheSceneWhileDownloadingDoesNotStart() async throws {
        let cloud = FakeCloud()
        cloud.add("cave_drips", ambience: true, file: try toneFile(seconds: 3), downloaded: false)
        cloud.fetchDelay = 0.3
        let player = cloudPlayer(cloud)
        defer { player.stopAll() }

        player.setAmbience([event("cave_drips")])
        player.setAmbience([])
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertTrue(player.activeAmbienceIDs.isEmpty)
    }

    func testMonoLowRateCloudFileStillStreams() async throws {
        let cloud = FakeCloud()
        cloud.add("cave_drips", ambience: true, file: try toneFile(seconds: 2, sampleRate: 22050, channels: 1), downloaded: true)
        let player = cloudPlayer(cloud)
        defer { player.stopAll() }

        player.play(event: event("cave_drips"))
        XCTAssertEqual(player.streamedAmbienceIDs, ["cave_drips"])
    }

    func testCloudOneShotPlaysWhenDownloadIsQuick() async throws {
        let cloud = FakeCloud()
        cloud.add("wolf_howl", ambience: false, file: try toneFile(seconds: 0.5), downloaded: false)
        cloud.fetchDelay = 0.1
        let player = cloudPlayer(cloud)
        defer { player.stopAll() }

        player.play(event: event("wolf_howl"))
        try await waitUntil { player.recentOneShots == ["wolf_howl"] }
    }

    func testCloudOneShotIsSkippedWhenDownloadIsTooSlow() async throws {
        let cloud = FakeCloud()
        cloud.add("wolf_howl", ambience: false, file: try toneFile(seconds: 0.5), downloaded: false)
        cloud.fetchDelay = 1.8
        let player = cloudPlayer(cloud)
        defer { player.stopAll() }

        player.play(event: event("wolf_howl"))
        try await waitUntil(timeout: 4) { cloud.fetches == 1 && cloud.downloaded.contains("wolf_howl") }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(player.recentOneShots.isEmpty)
    }

    func testBundledSoundPlaysAtOnceAndFetchesCloudVariantForNextTime() async throws {
        let cloud = FakeCloud()
        cloud.add("thunder", ambience: false, file: try toneFile(seconds: 0.5), downloaded: false)
        let player = cloudPlayer(cloud)
        defer { player.stopAll() }

        player.play(event: event("thunder"))
        XCTAssertEqual(player.recentOneShots, ["thunder"], "Bundled version plays immediately")
        try await waitUntil { cloud.downloaded.contains("thunder") }
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await MainActor.run(body: { !condition() }) {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func event(_ soundID: String) -> StoryEvent {
        StoryEvent(
            id: UUID(), type: .environment, entity: soundID, soundID: soundID,
            intensity: .soft, delayMilliseconds: 0, cooldownSeconds: 3, sourceText: ""
        )
    }
}

/// Cloud library stand-in serving local files, with an optional download delay.
private final class FakeCloud: SoundCatalogProviding, CloudSoundSource, @unchecked Sendable {
    private var sounds: [String: (ambience: Bool, file: URL)] = [:]
    var downloaded: Set<String> = []
    var fetchDelay: TimeInterval = 0
    private(set) var fetches = 0

    func add(_ id: String, ambience: Bool, file: URL, downloaded isDownloaded: Bool) {
        sounds[id] = (ambience, file)
        if isDownloaded { downloaded.insert(id) }
    }

    func info(for soundID: String) -> SoundInfo? {
        if let bundled = BundledSoundCatalog.shared.info(for: soundID) { return bundled }
        guard let sound = sounds[soundID] else { return nil }
        return SoundInfo(isAmbience: sound.ambience, type: .environment, entity: soundID, intensity: .normal)
    }

    func hasCloudVariants(_ soundID: String) -> Bool { sounds[soundID] != nil }

    func localFile(for soundID: String) -> URL? {
        downloaded.contains(soundID) ? sounds[soundID]?.file : nil
    }

    func fetchFile(for soundID: String) async throws -> URL {
        fetches += 1
        try await Task.sleep(nanoseconds: UInt64(fetchDelay * 1_000_000_000))
        guard let file = sounds[soundID]?.file else { throw BackendError.invalidResponse }
        await MainActor.run { _ = downloaded.insert(soundID) }
        return file
    }
}
