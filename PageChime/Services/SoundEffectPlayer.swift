import AVFoundation
import Foundation

final class SoundEffectPlayer: NSObject, SoundEffectPlaying, AVAudioPlayerDelegate {
    private var players: [String: AVAudioPlayer] = [:]
    private var ambiencePlayer: AVAudioPlayer?
    private var currentAmbienceSoundID: String?
    private var volume: Float = 0.4
    private var pendingWorkItems: [DispatchWorkItem] = []
    private var ambienceFadeOutItem: DispatchWorkItem?

    private let ambienceSounds: Set<String> = [
        "rain_light", "wind", "storm",
        "forest_ambience", "ocean_waves", "night_ambience", "farm_ambience",
        "wind_trees",
    ]

    private let ambienceDuration: TimeInterval = 5
    private let fadeDuration: TimeInterval = 2

    func play(event: StoryEvent) {
        let isAmbience = ambienceSounds.contains(event.soundID)

        if let existing = players[event.soundID], existing.isPlaying {
            if isAmbience { scheduleAmbienceFadeOut() }
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
                let workItem = DispatchWorkItem { [weak self] in
                    self?.startPlaying(player: player, soundID: soundID, isAmbience: isAmbience)
                }
                pendingWorkItems.append(workItem)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            } else {
                startPlaying(player: player, soundID: event.soundID, isAmbience: isAmbience)
            }
        } catch {
            // Missing or corrupt sound file
        }
    }

    func stopAll() {
        for item in pendingWorkItems {
            item.cancel()
        }
        pendingWorkItems.removeAll()
        ambienceFadeOutItem?.cancel()
        ambienceFadeOutItem = nil
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
            ambienceFadeOutItem?.cancel()
            player.numberOfLoops = -1
            ambiencePlayer = player
            currentAmbienceSoundID = soundID
            scheduleAmbienceFadeOut()
        }

        player.play()
        players[soundID] = player
    }

    private func scheduleAmbienceFadeOut() {
        ambienceFadeOutItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.fadeOutAmbience()
        }
        ambienceFadeOutItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + ambienceDuration, execute: workItem)
    }

    private func fadeOutAmbience() {
        guard let player = ambiencePlayer else { return }
        let steps = 10
        let interval = fadeDuration / Double(steps)
        let volumeStep = player.volume / Float(steps)

        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(i)) { [weak self] in
                guard let self else { return }
                if i < steps {
                    player.volume = max(0, player.volume - volumeStep)
                } else {
                    player.stop()
                    if self.ambiencePlayer === player {
                        self.ambiencePlayer = nil
                        if let sid = self.currentAmbienceSoundID {
                            self.players.removeValue(forKey: sid)
                        }
                        self.currentAmbienceSoundID = nil
                    }
                }
            }
        }
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
