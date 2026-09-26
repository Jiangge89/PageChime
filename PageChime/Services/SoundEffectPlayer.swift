import AVFoundation
import Foundation

final class SoundEffectPlayer: NSObject, SoundEffectPlaying, AVAudioPlayerDelegate {
    private var players: [String: AVAudioPlayer] = [:]
    private var ambiencePlayer: AVAudioPlayer?
    private var currentAmbienceSoundID: String?
    private var volume: Float = 0.4
    private var isStopped = false

    private let ambienceSounds: Set<String> = [
        "rain_light", "wind", "storm",
        "forest_ambience", "ocean_waves", "night_ambience", "farm_ambience",
    ]

    func play(event: StoryEvent) {
        let isAmbience = ambienceSounds.contains(event.soundID)

        if let existing = players[event.soundID], existing.isPlaying {
            return
        }

        guard let url = soundURL(for: event.soundID) else { return }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = volume * intensityMultiplier(event.intensity)
            player.delegate = self
            player.prepareToPlay()

            if event.delayMilliseconds > 0 {
                let delay = Double(event.delayMilliseconds) / 1000.0
                let soundID = event.soundID
                isStopped = false
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, !self.isStopped else { return }
                    self.startPlaying(player: player, soundID: soundID, isAmbience: isAmbience)
                }
            } else {
                startPlaying(player: player, soundID: event.soundID, isAmbience: isAmbience)
            }
        } catch {
            // Missing or corrupt sound file
        }
    }

    func stopAll() {
        isStopped = true
        for (_, player) in players {
            player.stop()
        }
        players.removeAll()
        ambiencePlayer?.stop()
        ambiencePlayer = nil
        currentAmbienceSoundID = nil
    }

    func setVolume(_ newVolume: Float) {
        volume = newVolume
        for (soundID, player) in players where player.isPlaying {
            let isAmbience = ambienceSounds.contains(soundID)
            let intensity: EffectIntensity = isAmbience ? .soft : .normal
            player.volume = newVolume * intensityMultiplier(intensity)
        }
        ambiencePlayer?.volume = newVolume * intensityMultiplier(.soft)
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        players = players.filter { $0.value !== player }
    }

    // MARK: - Private

    private func startPlaying(player: AVAudioPlayer, soundID: String, isAmbience: Bool) {
        if isAmbience {
            if currentAmbienceSoundID == soundID { return }
            ambiencePlayer?.stop()
            player.numberOfLoops = -1
            ambiencePlayer = player
            currentAmbienceSoundID = soundID
        }

        player.play()
        players[soundID] = player
    }

    private func soundURL(for soundID: String) -> URL? {
        if let url = Bundle.main.url(forResource: soundID, withExtension: "wav", subdirectory: "Sounds") {
            return url
        }
        return Bundle.main.url(forResource: soundID, withExtension: "wav")
    }

    private func intensityMultiplier(_ intensity: EffectIntensity) -> Float {
        switch intensity {
        case .soft: return 0.6
        case .normal: return 1.0
        case .strong: return 1.3
        }
    }
}
