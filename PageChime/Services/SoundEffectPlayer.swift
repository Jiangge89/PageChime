import AVFoundation
import Foundation

final class SoundEffectPlayer: NSObject, SoundEffectPlaying, AVAudioPlayerDelegate {
    private var players: [String: AVAudioPlayer] = [:]
    private var ambiencePlayer: AVAudioPlayer?
    private var currentAmbienceSoundID: String?
    private var currentAmbienceIntensity: EffectIntensity = .soft
    private var fadingPlayers: [AVAudioPlayer] = []
    private var ambienceFadeOutItem: DispatchWorkItem?
    private var volume: Float = 0.4

    private let audioData = AudioDataCache()

    private let ambienceSounds: Set<String> = Set(
        TriggerLibrary.defaultTriggers.filter(\.isAmbience).map(\.soundID)
    )

    /// How long an ambience bed keeps playing after its last mention.
    private let ambienceHoldDuration: TimeInterval = 20
    private let fadeInDuration: TimeInterval = 1.5
    private let fadeOutDuration: TimeInterval = 2

    func play(event: StoryEvent) {
        let isAmbience = ambienceSounds.contains(event.soundID)

        if isAmbience, currentAmbienceSoundID == event.soundID {
            // Mentioned again: keep the bed going instead of restarting it.
            scheduleAmbienceFadeOut()
            return
        }
        if !isAmbience, let existing = players[event.soundID], existing.isPlaying {
            return
        }

        guard let data = audioData.data(for: event.soundID),
              let player = try? AVAudioPlayer(data: data) else { return }
        player.delegate = self
        player.prepareToPlay()

        if isAmbience {
            startAmbience(player, soundID: event.soundID, intensity: event.intensity)
        } else {
            player.volume = volume * intensityMultiplier(event.intensity)
            player.play()
            players[event.soundID] = player
        }
    }

    func stopAll() {
        ambienceFadeOutItem?.cancel()
        ambienceFadeOutItem = nil
        players.values.forEach { $0.stop() }
        players.removeAll()
        fadingPlayers.forEach { $0.stop() }
        fadingPlayers.removeAll()
        ambiencePlayer?.stop()
        ambiencePlayer = nil
        currentAmbienceSoundID = nil
    }

    func setVolume(_ newVolume: Float) {
        volume = newVolume
        for player in players.values where player.isPlaying {
            player.volume = newVolume * intensityMultiplier(.normal)
        }
        ambiencePlayer?.volume = newVolume * intensityMultiplier(currentAmbienceIntensity)
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        players = players.filter { $0.value !== player }
    }

    // MARK: - Ambience

    private func startAmbience(_ player: AVAudioPlayer, soundID: String, intensity: EffectIntensity) {
        if let previous = ambiencePlayer {
            fadeOutAndStop(previous)
        }

        player.numberOfLoops = -1
        player.volume = 0
        player.play()
        player.setVolume(volume * intensityMultiplier(intensity), fadeDuration: fadeInDuration)

        ambiencePlayer = player
        currentAmbienceSoundID = soundID
        currentAmbienceIntensity = intensity
        scheduleAmbienceFadeOut()
    }

    private func scheduleAmbienceFadeOut() {
        ambienceFadeOutItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let player = self.ambiencePlayer else { return }
            self.ambiencePlayer = nil
            self.currentAmbienceSoundID = nil
            self.fadeOutAndStop(player)
        }
        ambienceFadeOutItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + ambienceHoldDuration, execute: workItem)
    }

    private func fadeOutAndStop(_ player: AVAudioPlayer) {
        fadingPlayers.append(player)
        player.setVolume(0, fadeDuration: fadeOutDuration)
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeOutDuration) { [weak self] in
            player.stop()
            self?.fadingPlayers.removeAll { $0 === player }
        }
    }

    private func intensityMultiplier(_ intensity: EffectIntensity) -> Float {
        switch intensity {
        case .soft: return 0.6
        case .normal: return 1.0
        case .strong: return 1.3
        }
    }
}

/// Keeps bundled sound files in memory so playback never touches the disk.
final class AudioDataCache {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    init(preload: Bool = true) {
        guard preload else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.preloadAll()
        }
    }

    func data(for soundID: String) -> Data? {
        if let cached = lock.withLock({ storage[soundID] }) {
            return cached
        }
        guard let url = Self.url(for: soundID), let data = try? Data(contentsOf: url) else { return nil }
        lock.withLock { storage[soundID] = data }
        return data
    }

    private func preloadAll() {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "wav", subdirectory: "Sounds") ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "wav", subdirectory: nil) ?? [])
        for url in urls {
            let soundID = url.deletingPathExtension().lastPathComponent
            guard lock.withLock({ storage[soundID] }) == nil,
                  let data = try? Data(contentsOf: url) else { continue }
            lock.withLock { storage[soundID] = data }
        }
    }

    private static func url(for soundID: String) -> URL? {
        Bundle.main.url(forResource: soundID, withExtension: "wav", subdirectory: "Sounds")
            ?? Bundle.main.url(forResource: soundID, withExtension: "wav")
    }
}
