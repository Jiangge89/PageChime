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
    @Published var analysisLogs: [AnalysisLog] = []

    var currentTime: () -> Date = { Date() }

    private let speechService: SpeechRecognizing
    private let eventEngine: StoryEventEngine
    private let soundPlayer: SoundEffectPlaying
    private let llmService: SoundMatching
    private let soundCache: SoundCache
    private var sessionID: UInt = 0

    /// Transcript length already scanned by the instant keyword path.
    private var keywordScannedLength = 0
    /// Transcript length already handed to cache/LLM analysis.
    private var dispatchedLength = 0
    private var segmentWorkItem: DispatchWorkItem?
    private var llmTasks: [UUID: Task<Void, Never>] = [:]

    private var cooldowns: [String: Date] = [:]
    /// Transcript position at which each sound last played, so a late LLM
    /// result doesn't replay a sound the keyword path already covered.
    private var lastPlayedPosition: [String: Int] = [:]

    private let cooldownInterval: TimeInterval = 3
    /// One-shot sounds from an LLM result older than this are dropped:
    /// by then the reader has moved on. Ambience is still applied.
    private let staleResultThreshold: TimeInterval = 4
    private let segmentDebounce: TimeInterval = 0.6

    private static let triggerLookup: [String: TriggerEntry] = {
        Dictionary(uniqueKeysWithValues: TriggerLibrary.defaultTriggers.map { ($0.soundID, $0) })
    }()

    var isListening: Bool { state == .listening }
    private var isStartingOrListening: Bool { state == .starting || state == .listening }

    init(
        speechService: SpeechRecognizing = SpeechRecognizerService(),
        eventEngine: StoryEventEngine = StoryEventEngine(),
        soundPlayer: SoundEffectPlaying = SoundEffectPlayer(),
        llmService: SoundMatching = LLMService(),
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

    func clearLogs() {
        analysisLogs.removeAll()
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
        segmentWorkItem?.cancel()
        segmentWorkItem = nil
        llmTasks.values.forEach { $0.cancel() }
        llmTasks.removeAll()
        speechService.stop()
        soundPlayer.stopAll()
        eventEngine.reset()
        soundCache.flush()
        cooldowns.removeAll()
        lastPlayedPosition.removeAll()
        transcript = ""
        recentEffects = []
        keywordScannedLength = 0
        dispatchedLength = 0
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

        // Partial results can be revised shorter; never point past the end.
        keywordScannedLength = min(keywordScannedLength, newTranscript.count)
        dispatchedLength = min(dispatchedLength, newTranscript.count)

        runKeywordPath(newTranscript)
        scheduleSegmentAnalysis(newTranscript)
    }

    // MARK: - Instant Keyword Path

    /// Runs on every partial result so obvious sounds fire immediately,
    /// without waiting for debounce or the network.
    private func runKeywordPath(_ text: String) {
        guard text.count > keywordScannedLength else { return }

        // Re-scan a short tail so keywords and negations split across
        // updates are still seen; cooldowns prevent double playback.
        let overlap = language == .chinese ? 10 : 24
        let start = max(0, keywordScannedLength - overlap)
        let window = String(text.dropFirst(start))
        keywordScannedLength = text.count

        let analysisStart = currentTime()
        let events = eventEngine.analyze(text: window, language: language)
        let played = events.map(\.soundID).filter {
            playSound($0, sourceText: window, position: text.count)
        }
        guard !played.isEmpty else { return }

        let analysisMs = Int(currentTime().timeIntervalSince(analysisStart) * 1000)
        appendLog(text: window, method: .keyword, waitMs: 0, analysisMs: analysisMs, soundIDs: played)
    }

    // MARK: - Cache / LLM Path

    private func scheduleSegmentAnalysis(_ text: String) {
        let newChars = text.count - dispatchedLength
        let threshold = language == .chinese ? 10 : 30
        let triggerTime = currentTime()

        segmentWorkItem?.cancel()
        segmentWorkItem = nil

        if newChars >= threshold {
            dispatchSegment(text, triggeredAt: triggerTime)
            return
        }

        let capturedSession = sessionID
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == capturedSession else { return }
                self.dispatchSegment(text, triggeredAt: triggerTime)
            }
        }
        segmentWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + segmentDebounce, execute: workItem)
    }

    /// Hands the not-yet-analyzed tail of the transcript to the cache, or to
    /// the LLM on a cache miss. Requests run concurrently and are never
    /// cancelled by newer speech, so continuous reading can't starve them.
    private func dispatchSegment(_ text: String, triggeredAt: Date) {
        guard text.count > dispatchedLength else { return }

        let segmentStart = dispatchedLength
        let segment = String(text.dropFirst(segmentStart))
        dispatchedLength = text.count

        let analysisStart = currentTime()
        let waitMs = Int(analysisStart.timeIntervalSince(triggeredAt) * 1000)
        let segmentLanguage = language

        let cachedSounds = soundCache.lookup(text: segment, language: segmentLanguage)
        if !cachedSounds.isEmpty {
            let played = cachedSounds.filter {
                playAnalyzedSound($0, segment: segment, segmentStart: segmentStart, position: text.count)
            }
            let analysisMs = Int(currentTime().timeIntervalSince(analysisStart) * 1000)
            appendLog(text: segment, method: .cache, waitMs: waitMs, analysisMs: analysisMs, soundIDs: played)
            return
        }

        let taskID = UUID()
        let capturedSession = sessionID
        let llm = llmService
        llmTasks[taskID] = Task { [weak self] in
            let result: Result<[LLMSoundMatch], Error>
            do {
                result = .success(try await llm.analyze(text: segment))
            } catch {
                result = .failure(error)
            }

            guard let self, !Task.isCancelled, self.sessionID == capturedSession else { return }
            self.llmTasks[taskID] = nil
            self.handleLLMResult(
                result, segment: segment, segmentStart: segmentStart, position: text.count,
                language: segmentLanguage, waitMs: waitMs, analysisStart: analysisStart
            )
        }
    }

    private func handleLLMResult(
        _ result: Result<[LLMSoundMatch], Error>,
        segment: String, segmentStart: Int, position: Int,
        language: ReadingLanguage, waitMs: Int, analysisStart: Date
    ) {
        let elapsed = currentTime().timeIntervalSince(analysisStart)
        let analysisMs = Int(elapsed * 1000)

        switch result {
        case .failure(let error):
            appendLog(
                text: segment, method: .error, waitMs: waitMs, analysisMs: analysisMs,
                soundIDs: [], note: String(describing: error)
            )

        case .success(let matches):
            soundCache.store(triggers: matches, language: language)

            let isStale = elapsed > staleResultThreshold
            var played: [String] = []
            var dropped: [String] = []
            for soundID in matches.map(\.id) {
                let isAmbience = Self.triggerLookup[soundID]?.isAmbience ?? false
                if isStale && !isAmbience {
                    dropped.append(soundID)
                } else if playAnalyzedSound(soundID, segment: segment, segmentStart: segmentStart, position: position) {
                    played.append(soundID)
                }
            }

            appendLog(
                text: segment, method: matches.isEmpty ? .noMatch : .llm,
                waitMs: waitMs, analysisMs: analysisMs, soundIDs: played,
                note: dropped.isEmpty ? nil : "late, skipped: " + dropped.joined(separator: ", ")
            )
        }
    }

    /// Plays a sound found by cache/LLM unless the keyword path already
    /// played it for this stretch of text.
    private func playAnalyzedSound(_ soundID: String, segment: String, segmentStart: Int, position: Int) -> Bool {
        if let lastPosition = lastPlayedPosition[soundID], lastPosition > segmentStart {
            return false
        }
        return playSound(soundID, sourceText: segment, position: position)
    }

    // MARK: - Playback

    @discardableResult
    private func playSound(_ soundID: String, sourceText: String, position: Int) -> Bool {
        let now = currentTime()
        if let lastFired = cooldowns[soundID], now.timeIntervalSince(lastFired) < cooldownInterval {
            return false
        }
        guard let trigger = Self.triggerLookup[soundID] else { return false }

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
        lastPlayedPosition[soundID] = position
        return true
    }

    private func appendLog(
        text: String, method: AnalysisLog.Method, waitMs: Int, analysisMs: Int,
        soundIDs: [String], note: String? = nil
    ) {
        let log = AnalysisLog(
            timestamp: currentTime(),
            inputText: text,
            method: method,
            waitMs: waitMs,
            analysisMs: analysisMs,
            soundIDs: soundIDs,
            note: note
        )
        analysisLogs.insert(log, at: 0)
        if analysisLogs.count > 50 {
            analysisLogs = Array(analysisLogs.prefix(50))
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
