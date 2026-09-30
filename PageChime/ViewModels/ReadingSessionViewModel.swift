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
    private let llmService: LLMService
    private let soundCache: SoundCache
    private var sessionID: UInt = 0
    private var analysisWorkItem: DispatchWorkItem?
    private var lastAnalyzedLength: Int = 0
    private var currentAnalysisTask: Task<Void, Never>?
    private var cooldowns: [String: Date] = [:]
    private let cooldownInterval: TimeInterval = 3

    private static let triggerLookup: [String: TriggerEntry] = {
        Dictionary(uniqueKeysWithValues: TriggerLibrary.defaultTriggers.map { ($0.soundID, $0) })
    }()

    var isListening: Bool { state == .listening }
    private var isStartingOrListening: Bool { state == .starting || state == .listening }

    init(
        speechService: SpeechRecognizing = SpeechRecognizerService(),
        eventEngine: StoryEventEngine = StoryEventEngine(),
        soundPlayer: SoundEffectPlaying = SoundEffectPlayer(),
        llmService: LLMService = LLMService(),
        soundCache: SoundCache = SoundCache()
    ) {
        self.speechService = speechService
        self.eventEngine = eventEngine
        self.soundPlayer = soundPlayer
        self.llmService = llmService
        self.soundCache = soundCache
        setupCallbacks()
    }

    // MARK: - User Actions

    func toggleListening() {
        if isStartingOrListening {
            stopSession()
        } else {
            Task { await startSession() }
        }
    }

    func changeLanguage(_ newLanguage: ReadingLanguage) {
        let wasListening = isStartingOrListening
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
        guard state == .ready || state == .permissionRequired || state.isError else { return }
        state = .starting
        sessionID &+= 1

        let granted = await speechService.requestPermissions()
        guard granted else {
            state = .permissionRequired
            return
        }

        do {
            speechService.contextualStrings = TriggerLibrary.contextualStrings(for: language)
            try await speechService.start(language: language)
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func stopSession() {
        sessionID &+= 1
        analysisWorkItem?.cancel()
        analysisWorkItem = nil
        currentAnalysisTask?.cancel()
        currentAnalysisTask = nil
        speechService.stop()
        soundPlayer.stopAll()
        eventEngine.reset()
        cooldowns.removeAll()
        transcript = ""
        recentEffects = []
        lastAnalyzedLength = 0
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Callbacks

    private func setupCallbacks() {
        speechService.onTranscriptUpdate = { [weak self] newTranscript in
            guard let self else { return }
            let capturedSession = self.sessionID
            Task { @MainActor in
                guard self.sessionID == capturedSession else { return }
                self.onTranscriptUpdated(newTranscript)
            }
        }

        speechService.onStateChange = { [weak self] newState in
            guard let self else { return }
            let capturedSession = self.sessionID
            Task { @MainActor in
                guard self.sessionID == capturedSession else { return }
                self.state = newState
            }
        }
    }

    private func onTranscriptUpdated(_ newTranscript: String) {
        transcript = newTranscript

        let newChars = newTranscript.count - lastAnalyzedLength
        let threshold = language == .chinese ? 12 : 40

        if newChars >= threshold {
            analysisWorkItem?.cancel()
            analysisWorkItem = nil
            analyzeTranscript(newTranscript)
            return
        }

        analysisWorkItem?.cancel()
        let capturedSession = sessionID
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == capturedSession else { return }
                self.analyzeTranscript(newTranscript)
            }
        }
        analysisWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }

    // MARK: - Analysis

    private func analyzeTranscript(_ text: String) {
        guard !text.isEmpty, text.count > lastAnalyzedLength else { return }

        let newText = String(text.suffix(text.count - lastAnalyzedLength))
        let targetLength = text.count

        let cachedSounds = soundCache.lookup(text: newText, language: language)
        if !cachedSounds.isEmpty {
            playMatchedSounds(cachedSounds, sourceText: newText)
            lastAnalyzedLength = targetLength
            return
        }

        currentAnalysisTask?.cancel()
        currentAnalysisTask = Task {
            do {
                let matches = try await llmService.analyze(text: newText)
                guard !Task.isCancelled else { return }
                let soundIDs = matches.map(\.id)
                playMatchedSounds(soundIDs, sourceText: newText)
                soundCache.store(triggers: matches, language: language)
                lastAnalyzedLength = targetLength
            } catch {
                guard !Task.isCancelled else { return }
                let events = eventEngine.analyze(text: newText, language: language)
                for event in events {
                    soundPlayer.play(event: event)
                    addRecentEffect(event)
                }
                lastAnalyzedLength = targetLength
            }
        }
    }

    private func playMatchedSounds(_ soundIDs: [String], sourceText: String) {
        let now = Date()
        for soundID in soundIDs {
            if let lastFired = cooldowns[soundID],
               now.timeIntervalSince(lastFired) < cooldownInterval {
                continue
            }

            guard let trigger = Self.triggerLookup[soundID] else { continue }

            let event = StoryEvent(
                id: UUID(),
                type: trigger.eventType,
                entity: trigger.entity,
                soundID: soundID,
                intensity: trigger.intensity,
                delayMilliseconds: 0,
                cooldownSeconds: cooldownInterval,
                sourceText: sourceText
            )

            soundPlayer.play(event: event)
            addRecentEffect(event)
            cooldowns[soundID] = now
        }
    }

    private func addRecentEffect(_ event: StoryEvent) {
        recentEffects.insert(event, at: 0)
        if recentEffects.count > 3 {
            recentEffects = Array(recentEffects.prefix(3))
        }
    }
}

private extension ListeningState {
    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}
