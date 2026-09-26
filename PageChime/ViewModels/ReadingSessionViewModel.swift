import Combine
import Foundation
import SwiftUI

@MainActor
final class ReadingSessionViewModel: ObservableObject {
    @Published var language: ReadingLanguage = .english
    @Published var state: ListeningState = .ready
    @Published var transcript: String = ""
    @Published var recentEffects: [StoryEvent] = []
    @Published var volume: Float = 0.4

    private let speechService: SpeechRecognizing
    private let eventEngine: StoryEventEngine
    private let soundPlayer: SoundEffectPlaying
    private var lastAnalyzedTranscript: String = ""

    var isListening: Bool { state == .listening }

    init(
        speechService: SpeechRecognizing = SpeechRecognizerService(),
        eventEngine: StoryEventEngine = StoryEventEngine(),
        soundPlayer: SoundEffectPlaying = SoundEffectPlayer()
    ) {
        self.speechService = speechService
        self.eventEngine = eventEngine
        self.soundPlayer = soundPlayer
        setupCallbacks()
    }

    // MARK: - User Actions

    func toggleListening() {
        if isListening {
            stopSession()
        } else {
            Task { await startSession() }
        }
    }

    func changeLanguage(_ newLanguage: ReadingLanguage) {
        let wasListening = isListening
        if wasListening { stopSession() }
        language = newLanguage
        if wasListening {
            Task { await startSession() }
        }
    }

    func updateVolume(_ newVolume: Float) {
        volume = newVolume
        soundPlayer.setVolume(newVolume)
    }

    // MARK: - Session Lifecycle

    private func startSession() async {
        let granted = await speechService.requestPermissions()
        guard granted else {
            state = .permissionRequired
            return
        }

        do {
            try await speechService.start(language: language)
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func stopSession() {
        speechService.stop()
        soundPlayer.stopAll()
        eventEngine.reset()
        transcript = ""
        recentEffects = []
        lastAnalyzedTranscript = ""
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Callbacks

    private func setupCallbacks() {
        speechService.onTranscriptUpdate = { [weak self] newTranscript in
            Task { @MainActor in
                self?.onTranscriptUpdated(newTranscript)
            }
        }

        speechService.onStateChange = { [weak self] newState in
            Task { @MainActor in
                self?.state = newState
            }
        }
    }

    private func onTranscriptUpdated(_ newTranscript: String) {
        transcript = newTranscript
        guard newTranscript != lastAnalyzedTranscript else { return }
        lastAnalyzedTranscript = newTranscript

        let windowSize = min(newTranscript.count, 200)
        let window = String(newTranscript.suffix(windowSize))

        let events = eventEngine.analyze(text: window, language: language)
        for event in events {
            soundPlayer.play(event: event)
            addRecentEffect(event)
        }
    }

    private func addRecentEffect(_ event: StoryEvent) {
        recentEffects.insert(event, at: 0)
        if recentEffects.count > 3 {
            recentEffects = Array(recentEffects.prefix(3))
        }
    }
}
