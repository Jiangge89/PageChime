import Combine
import Foundation
import SwiftUI

/// When newly read text is sent for LLM analysis. Each call repeats the
/// whole sound catalog, so fewer, longer segments cost less; sending early
/// when a cloud sound is named keeps those sounds on time.
struct SegmentPolicy {
    /// Send at once when this much new text has built up.
    var maxChars: Int
    /// Send at once when the new text names a cloud sound and is at least
    /// this long (a few words after the name help the LLM).
    var hotWordMinChars: Int
    /// After the reader pauses this long, send if at least this much is new.
    /// Short pauses are often mid-sentence; longer ones end a sentence.
    var pauseTiers: [(delay: TimeInterval, minChars: Int)]

    static func standard(for language: ReadingLanguage) -> SegmentPolicy {
        switch language {
        case .chinese:
            // Chinese recognition has no punctuation and no spaces, and
            // sound names are English, so pauses and length decide.
            return SegmentPolicy(maxChars: 20, hotWordMinChars: .max, pauseTiers: [(0.6, 10), (1.2, 4), (2.5, 1)])
        default:
            return SegmentPolicy(maxChars: 60, hotWordMinChars: 12, pauseTiers: [(0.6, 30), (1.2, 12), (2.5, 1)])
        }
    }
}

/// A scanned book page and how far its analysis has got.
enum PageStatus: Equatable {
    case none
    case reading
    case analyzing
    case ready(cues: Int)
    case failed(String)
}

/// A sound on the scanned page, set off when the reader says its phrase.
private struct PageCue {
    let soundID: String
    /// Normalized phrases, any of which fires the cue: the whole trigger and,
    /// for long ones, its end, in case recognition garbles the start.
    let patterns: [String]
    var fired = false
}

@MainActor
final class ReadingSessionViewModel: ObservableObject {
    @Published var language: ReadingLanguage = .english
    @Published var state: ListeningState = .ready
    @Published var transcript: String = ""
    @Published var recentEffects: [StoryEvent] = []
    @Published var volume: Float = 0.4
    @Published var analysisLogs: [AnalysisLog] = []
    @Published private(set) var pageStatus: PageStatus = .none

    var currentTime: () -> Date = { Date() }
    var segmentPolicy: (ReadingLanguage) -> SegmentPolicy = SegmentPolicy.standard

    private let speechService: SpeechRecognizing
    private let eventEngine: StoryEventEngine
    private let soundPlayer: SoundEffectPlaying
    private let llmService: SoundMatching
    private let soundCache: SoundCache
    private let catalog: SoundCatalogProviding
    private let prefetcher: SoundPrefetching?
    private let pageAnalyzer: PageAnalyzing?
    private let textRecognizer: PageTextRecognizing
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
    /// Ambience beds the LLM last chose for the scene.
    private var currentScene: Set<String> = []

    private var pageCues: [PageCue] = []
    private var pageAmbience: [String]?
    /// Bumped per scan, so a slow analysis can't overwrite a newer page.
    private var pageGeneration = 0

    private let cooldownInterval: TimeInterval = 3
    /// One-shot sounds from an LLM result older than this are dropped:
    /// by then the reader has moved on. Ambience is still applied.
    private let staleResultThreshold: TimeInterval = 4
    /// Characters of earlier story sent along with each segment.
    private let contextLength = 300

    var isListening: Bool { state == .listening }
    private var isStartingOrListening: Bool { state == .starting || state == .listening }

    init(
        speechService: SpeechRecognizing = SpeechRecognizerService(),
        eventEngine: StoryEventEngine = StoryEventEngine(),
        soundPlayer: SoundEffectPlaying = SoundEffectPlayer(),
        llmService: SoundMatching = BackendSoundMatcher(),
        soundCache: SoundCache = SoundCache(),
        catalog: SoundCatalogProviding = SoundLibrary.shared,
        prefetcher: SoundPrefetching? = SoundLibrary.shared,
        pageAnalyzer: PageAnalyzing? = Backend.shared == nil ? nil : BackendSoundMatcher(),
        textRecognizer: PageTextRecognizing = VisionTextRecognizer()
    ) {
        self.speechService = speechService
        self.eventEngine = eventEngine
        self.soundPlayer = soundPlayer
        self.llmService = llmService
        self.soundCache = soundCache
        self.catalog = catalog
        self.prefetcher = prefetcher
        self.pageAnalyzer = pageAnalyzer
        self.textRecognizer = textRecognizer
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
        // Cue phrases are normalized per language.
        if pageStatus != .none { clearPage() }
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

    // MARK: - Scanned Page

    var canScanPages: Bool { pageAnalyzer != nil }

    /// Reads the text on photographed pages, then finds their sound cues.
    func scanPage(_ images: [UIImage]) async {
        pageGeneration += 1
        let generation = pageGeneration
        pageStatus = .reading
        do {
            let text = try await textRecognizer.recognizeText(in: images, language: language)
            guard generation == pageGeneration else { return }
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
                pageStatus = .failed(language == .chinese ? "没有在照片里找到文字" : "No text found in the photo")
                return
            }
            await loadPage(text: text, generation: generation)
        } catch {
            guard generation == pageGeneration else { return }
            pageStatus = .failed(error.localizedDescription)
        }
    }

    /// Sends a page's text for analysis and arms its cues.
    func loadPage(text: String) async {
        pageGeneration += 1
        await loadPage(text: text, generation: pageGeneration)
    }

    private func loadPage(text: String, generation: Int) async {
        guard let pageAnalyzer else {
            pageStatus = .failed("Page scanning needs the PageChime server")
            return
        }
        pageStatus = .analyzing
        let pageLanguage = language
        let started = currentTime()
        let analysis: PageAnalysis
        do {
            analysis = try await pageAnalyzer.analyzePage(text: text, context: String(transcript.suffix(contextLength)))
        } catch {
            guard generation == pageGeneration else { return }
            pageStatus = .failed(language == .chinese ? "这一页没能分析成功" : "Couldn't analyze the page")
            appendLog(text: text, method: .error, waitMs: 0, analysisMs: 0, soundIDs: [], note: "page: \(error)")
            return
        }
        guard generation == pageGeneration else { return }

        let cues = analysis.cues.filter { catalog.info(for: $0.id) != nil }
        pageCues = cues.compactMap { Self.makeCue($0, language: pageLanguage) }
        let isAmbience = { (id: String) in self.catalog.info(for: id)?.isAmbience == true }
        pageAmbience = analysis.ambience?.filter(isAmbience)

        // Everything this page and the next ones need, downloaded before it's read.
        let upcoming = analysis.upcoming.filter { catalog.info(for: $0) != nil }
        prefetcher?.prefetch(cues.map(\.id) + (pageAmbience ?? []) + upcoming)
        // Help recognition with the page's own phrases (used from the next restart).
        speechService.contextualStrings = Array(
            (cues.map(\.trigger) + TriggerLibrary.contextualStrings(for: pageLanguage)).prefix(100)
        )
        if isListening, let ambience = pageAmbience {
            applyScene(Set(ambience), sourceText: text)
        }

        pageStatus = .ready(cues: pageCues.count)
        let analysisMs = Int(currentTime().timeIntervalSince(started) * 1000)
        appendLog(
            text: text, method: .page, waitMs: 0, analysisMs: analysisMs, soundIDs: cues.map(\.id),
            note: "page: \(pageCues.count) cues" + (pageAmbience.map { $0.isEmpty ? "" : ", scene: " + $0.joined(separator: ", ") } ?? "")
        )
    }

    func clearPage() {
        pageGeneration += 1
        pageCues = []
        pageAmbience = nil
        pageStatus = .none
        speechService.contextualStrings = TriggerLibrary.contextualStrings(for: language)
    }

    private static func makeCue(_ match: LLMSoundMatch, language: ReadingLanguage) -> PageCue? {
        let whole = SoundCache.normalize(match.trigger, language: language)
        guard whole.count >= 2 else { return nil }
        var patterns = [whole]
        if language == .chinese {
            if whole.count >= 6 { patterns.append(String(whole.suffix(4))) }
        } else {
            let words = match.trigger.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            if words.count >= 4 {
                patterns.append(SoundCache.normalize(words.suffix(3).joined(separator: " "), language: language))
            }
        }
        return PageCue(soundID: match.id, patterns: patterns)
    }

    /// Plays page cues whose phrase was just read. Each fires once per reading.
    private func runPageCues(_ text: String) {
        guard pageCues.contains(where: { !$0.fired }) else { return }
        // The longest trigger is 80 characters; look a little further back.
        let tail = SoundCache.normalize(String(text.suffix(120)), language: language)
        var played: [String] = []
        for index in pageCues.indices where !pageCues[index].fired {
            guard pageCues[index].patterns.contains(where: { tail.contains($0) }) else { continue }
            pageCues[index].fired = true
            let soundID = pageCues[index].soundID
            if catalog.info(for: soundID)?.isAmbience == true {
                applyScene([soundID], sourceText: text)
                played.append(soundID)
            } else if playSound(soundID, sourceText: text, position: text.count) {
                played.append(soundID)
            }
        }
        if !played.isEmpty {
            appendLog(text: String(text.suffix(60)), method: .page, waitMs: 0, analysisMs: 0, soundIDs: played)
        }
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

        // Reading the page again plays its cues again.
        for index in pageCues.indices { pageCues[index].fired = false }

        do {
            if pageCues.isEmpty {
                speechService.contextualStrings = TriggerLibrary.contextualStrings(for: language)
            }
            try await speechService.start(language: language)
            if let ambience = pageAmbience, !ambience.isEmpty {
                applyScene(Set(ambience), sourceText: "")
            }
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
        currentScene.removeAll()
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
        soundPlayer.noteSpeechActivity()

        // Partial results can be revised shorter; never point past the end.
        keywordScannedLength = min(keywordScannedLength, newTranscript.count)
        dispatchedLength = min(dispatchedLength, newTranscript.count)

        runPageCues(newTranscript)
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
        var start = text.index(text.startIndex, offsetBy: max(0, keywordScannedLength - overlap))
        // Don't start mid-word, or "then" could be scanned as "hen".
        while start > text.startIndex, text[text.index(before: start)].isLetter {
            start = text.index(before: start)
        }
        let window = String(text[start...])
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
        let policy = segmentPolicy(language)
        let newText = text.dropFirst(dispatchedLength)
        let triggerTime = currentTime()

        segmentWorkItem?.cancel()
        segmentWorkItem = nil

        if newText.count >= policy.maxChars
            || (newText.count >= policy.hotWordMinChars && namesCloudSound(newText)) {
            dispatchSegment(text, triggeredAt: triggerTime)
            return
        }
        schedulePauseTier(0, text: text, policy: policy, triggeredAt: triggerTime)
    }

    /// Waits for the next pause tier; sends the text if enough is new by then,
    /// otherwise waits for the next, longer tier.
    private func schedulePauseTier(_ index: Int, text: String, policy: SegmentPolicy, triggeredAt: Date) {
        guard index < policy.pauseTiers.count else { return }
        let tier = policy.pauseTiers[index]
        let previousDelay = index > 0 ? policy.pauseTiers[index - 1].delay : 0
        let capturedSession = sessionID
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == capturedSession else { return }
                if text.count - self.dispatchedLength >= tier.minChars {
                    self.dispatchSegment(text, triggeredAt: triggeredAt)
                } else {
                    self.schedulePauseTier(index + 1, text: text, policy: policy, triggeredAt: triggeredAt)
                }
            }
        }
        segmentWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + (tier.delay - previousDelay), execute: workItem)
    }

    private func namesCloudSound(_ text: Substring) -> Bool {
        let names = catalog.cloudSoundNames()
        guard !names.isEmpty else { return false }
        return text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .contains { names.contains(String($0)) }
    }

    /// Hands the not-yet-analyzed tail of the transcript to the cache and the
    /// LLM. Cache hits play instantly; the LLM still runs to follow the scene.
    /// Requests run concurrently and are never cancelled by newer speech, so
    /// continuous reading can't starve them.
    private func dispatchSegment(_ text: String, triggeredAt: Date) {
        guard text.count > dispatchedLength else { return }

        let segmentStart = dispatchedLength
        let segment = String(text.dropFirst(segmentStart))
        dispatchedLength = text.count

        let analysisStart = currentTime()
        let waitMs = Int(analysisStart.timeIntervalSince(triggeredAt) * 1000)
        let segmentLanguage = language
        let context = String(text.prefix(segmentStart).suffix(contextLength))

        let cachedSounds = soundCache.lookup(text: segment, language: segmentLanguage)
        if !cachedSounds.isEmpty {
            let played = cachedSounds.filter {
                playAnalyzedSound($0, segment: segment, segmentStart: segmentStart, position: text.count)
            }
            let analysisMs = Int(currentTime().timeIntervalSince(analysisStart) * 1000)
            appendLog(text: segment, method: .cache, waitMs: waitMs, analysisMs: analysisMs, soundIDs: played)
        }

        let taskID = UUID()
        let capturedSession = sessionID
        let llm = llmService
        llmTasks[taskID] = Task { [weak self] in
            let result: Result<SoundAnalysis, Error>
            do {
                result = .success(try await llm.analyze(text: segment, context: context))
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
        _ result: Result<SoundAnalysis, Error>,
        segment: String, segmentStart: Int, position: Int,
        language: ReadingLanguage, waitMs: Int, analysisStart: Date
    ) {
        let elapsed = currentTime().timeIntervalSince(analysisStart)
        let analysisMs = Int(elapsed * 1000)

        guard case .success(let analysis) = result else {
            if case .failure(let error) = result {
                appendLog(
                    text: segment, method: .error, waitMs: waitMs, analysisMs: analysisMs,
                    soundIDs: [], note: String(describing: error)
                )
            }
            return
        }

        // Ignore sounds neither bundled nor in the cloud library (e.g. ones
        // added to the server after this app version's library was fetched).
        let known = analysis.sounds.filter { catalog.info(for: $0.id) != nil }
        let isAmbience = { (id: String) in self.catalog.info(for: id)?.isAmbience ?? false }
        let oneShots = known.filter { !isAmbience($0.id) }
        let inlineAmbience = known.map(\.id).filter(isAmbience)
        soundCache.store(triggers: oneShots, language: language)

        // Late one-shots would no longer match what is being read.
        let isStale = elapsed > staleResultThreshold
        var played: [String] = []
        var dropped: [String] = []
        for soundID in oneShots.map(\.id) {
            if isStale {
                dropped.append(soundID)
            } else if playAnalyzedSound(soundID, segment: segment, segmentStart: segmentStart, position: position) {
                played.append(soundID)
            }
        }

        // Ambience follows the scene, so it's applied even when late.
        var notes: [String] = []
        if let sceneAmbience = analysis.ambience {
            let scene = Set(sceneAmbience.filter(isAmbience) + inlineAmbience)
            applyScene(scene, sourceText: segment)
            notes.append("scene: " + (scene.isEmpty ? "quiet" : scene.sorted().joined(separator: ", ")))
        } else {
            played += inlineAmbience.filter { playSound($0, sourceText: segment, position: position) }
        }
        if !dropped.isEmpty {
            notes.append("late, skipped: " + dropped.joined(separator: ", "))
        }

        // Download what the story is heading towards, so it plays instantly.
        let queued = prefetcher?.prefetch(analysis.upcoming.filter { catalog.info(for: $0) != nil }) ?? []
        if !queued.isEmpty {
            notes.append("prefetch: " + queued.joined(separator: ", "))
        }

        let foundAnything = !analysis.sounds.isEmpty || analysis.ambience != nil
        appendLog(
            text: segment, method: foundAnything ? .llm : .noMatch,
            waitMs: waitMs, analysisMs: analysisMs, soundIDs: played,
            note: notes.isEmpty ? nil : notes.joined(separator: " · ")
        )
    }

    private func applyScene(_ soundIDs: Set<String>, sourceText: String) {
        let events = soundIDs.sorted().compactMap { makeEvent($0, sourceText: sourceText) }
        soundPlayer.setAmbience(events)
        for event in events where !currentScene.contains(event.soundID) {
            addRecentEffect(event)
        }
        currentScene = soundIDs
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
        guard let event = makeEvent(soundID, sourceText: sourceText) else { return false }

        soundPlayer.play(event: event)
        addRecentEffect(event)
        cooldowns[soundID] = now
        lastPlayedPosition[soundID] = position
        return true
    }

    private func makeEvent(_ soundID: String, sourceText: String) -> StoryEvent? {
        guard let info = catalog.info(for: soundID) else { return nil }
        return StoryEvent(
            id: UUID(),
            type: info.type,
            entity: info.entity,
            soundID: soundID,
            intensity: info.intensity,
            delayMilliseconds: 0,
            cooldownSeconds: cooldownInterval,
            sourceText: sourceText
        )
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
