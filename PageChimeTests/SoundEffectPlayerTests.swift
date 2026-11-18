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
        let player = SoundEffectPlayer(buffers: AudioBufferCache(preload: false))
        defer { player.stopAll() }

        player.setAmbience([event("forest_ambience"), event("night_ambience")])
        XCTAssertEqual(player.activeAmbienceIDs, ["forest_ambience", "night_ambience"])

        player.setAmbience([event("ocean_waves")])
        XCTAssertEqual(player.activeAmbienceIDs, ["ocean_waves"], "Old beds should be fading out")
    }

    func testAmbienceIsCappedAtMaxBeds() {
        let player = SoundEffectPlayer(buffers: AudioBufferCache(preload: false))
        defer { player.stopAll() }

        for id in ["forest_ambience", "night_ambience", "ocean_waves", "farm_ambience"] {
            player.play(event: event(id))
        }
        XCTAssertEqual(player.activeAmbienceIDs.count, SoundEffectPlayer.maxBeds)
        XCTAssertTrue(player.activeAmbienceIDs.contains("farm_ambience"), "Newest bed should replace the oldest")
    }

    func testStopAllClearsAmbience() {
        let player = SoundEffectPlayer(buffers: AudioBufferCache(preload: false))
        player.setAmbience([event("rain_light")])
        player.play(event: event("thunder"))
        player.stopAll()
        XCTAssertTrue(player.activeAmbienceIDs.isEmpty)
    }

    private func event(_ soundID: String) -> StoryEvent {
        StoryEvent(
            id: UUID(), type: .environment, entity: soundID, soundID: soundID,
            intensity: .soft, delayMilliseconds: 0, cooldownSeconds: 3, sourceText: ""
        )
    }
}
