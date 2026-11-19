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

/// What the reader is shown about a scanned page: its text and its sounds.
struct PageSummary: Equatable {
    struct Cue: Equatable, Identifiable {
        let soundID: String
        /// The words on the page that start the sound.
        let trigger: String
        let isAmbience: Bool
        let type: StoryEventType
        var id: String { soundID + "|" + trigger }
    }

    let number: Int
    let text: String
    let cues: [Cue]
}

/// One story, from the first page to "The end".
struct StoryProgress: Equatable {
    var startedAt: Date
    var endedAt: Date?
    var pages = 0
    var soundCount = 0
    /// Each sound once, in the order it first played.
    var soundIDs: [String] = []
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
    @Published private(set) var page: PageSummary?
    /// How many of the page's cues have played in this reading.
    @Published private(set) var firedCueCount = 0
    @Published private(set) var isPaused = false
    @Published private(set) var story: StoryProgress?
    /// Ambience beds playing now.
    @Published private(set) var sceneIDs: [String] = []
    /// The latest one-shot sound (ambience shows in `sceneIDs` instead).
    @Published private(set) var lastOneShot: StoryEvent?

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

    /// Keyword occurrences already handled, by sound and where the keyword
    /// ends in the transcript, so a word plays once however often the
    /// transcript tail is re-scanned or revised.
    private var heardKeywords: [(soundID: String, end: Int)] = []
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

    // MARK: - Story

    func beginStory() {
        if story == nil { story = StoryProgress(startedAt: currentTime()) }
    }

    /// Starts reading the current page from its beginning.
    func startReading() {
        beginStory()
        isPaused = false
        Task { await startSession(resetCues: true) }
    }

    /// Stops listening but keeps the story and which cues already played.
    func pauseReading() {
        guard isStartingOrListening else { return }
        stopSession()
        isPaused = true
    }

    func resumeReading() {
        isPaused = false
        Task { await startSession(resetCues: false) }
    }

    func endStory() {
        if isStartingOrListening { stopSession() }
        isPaused = false
        story?.endedAt = currentTime()
    }

    /// Back to a blank slate for the next story.
    func resetStory() {
        if isStartingOrListening { stopSession() }
        isPaused = false
        story = nil
        clearPage()
    }

    // MARK: - Scanned Page

    var canScanPages: Bool { pageAnalyzer != nil }

    /// Reads the text on photographed pages, then finds their sound cues.
    /// `replacing` rescans the current page instead of starting the next.
    func scanPage(_ images: [UIImage], replacing: Bool = false) async {
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
            await loadPage(text: text, generation: generation, replacing: replacing)
        } catch {
            guard generation == pageGeneration else { return }
            pageStatus = .failed(error.localizedDescription)
        }
    }

    /// Sends a page's text for analysis and arms its cues.
    func loadPage(text: String, replacing: Bool = false) async {
        pageGeneration += 1
        await loadPage(text: text, generation: pageGeneration, replacing: replacing)
    }

    private func loadPage(text: String, generation: Int, replacing: Bool) async {
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
        var armed: [PageCue] = []
        var shown: [PageSummary.Cue] = []
        for match in cues {
            guard let cue = Self.makeCue(match, language: pageLanguage), let info = catalog.info(for: match.id) else { continue }
            armed.append(cue)
            shown.append(PageSummary.Cue(soundID: match.id, trigger: match.trigger, isAmbience: info.isAmbience, type: info.type))
        }
        pageCues = armed
        firedCueCount = 0
        let isAmbience = { (id: String) in self.catalog.info(for: id)?.isAmbience == true }
        pageAmbience = analysis.ambience?.filter(isAmbience)

        let number: Int
        if replacing, let current = page {
            number = current.number
        } else {
            number = (story?.pages ?? 0) + 1
            story?.pages = number
        }
        page = PageSummary(number: number, text: text, cues: shown)

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
        page = nil
        firedCueCount = 0
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
        firedCueCount = pageCues.filter(\.fired).count
        if !played.isEmpty {
            appendLog(text: String(text.suffix(60)), method: .page, waitMs: 0, analysisMs: 0, soundIDs: played)
        }
    }

    // MARK: - Session Lifecycle

    private func startSession(resetCues: Bool = true) async {
        guard state == .ready || state == .permissionRequired || state.isError else { return }
        state = .starting
        sessionID &+= 1

        let granted = await speechService.requestPermissions()
        guard granted else {
            state = .permissionRequired
            return
        }

        // Reading the page again plays its cues again; resuming doesn't.
        if resetCues {
            for index in pageCues.indices { pageCues[index].fired = false }
            firedCueCount = 0
        }

        do {
            if pageCues.isEmpty {
                speechService.contextualStrings = TriggerLibrary.contextualStrings(for: language)
            }
            try await speechService.start(language: language)
            if !speechService.recognitionMode.isEmpty {
                appendLog(text: "", method: .info, waitMs: 0, analysisMs: 0, soundIDs: [], note: "speech recognition: " + speechService.recognitionMode)
            }
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
        sceneIDs = []
        lastOneShot = nil
        state = .ready
        transcript = ""
        recentEffects = []
        heardKeywords = []
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
        dispatchedLength = min(dispatchedLength, newTranscript.count)

        runPageCues(newTranscript)
        runKeywordPath(newTranscript)
        scheduleSegmentAnalysis(newTranscript)
    }

    // MARK: - Instant Keyword Path

    /// Runs on every partial result so obvious sounds fire immediately,
    /// without waiting for debounce or the network. The tail of the
    /// transcript is scanned every time, because recognition revises its
    /// last words; an occurrence already heard (same sound, about the same
    /// place) is never played again.
    private func runKeywordPath(_ text: String) {
        let window = language == .chinese ? 30 : 80
        var start = text.index(text.endIndex, offsetBy: -window, limitedBy: text.startIndex) ?? text.startIndex
        if language != .chinese {
            // Don't start mid-word, or "then" could be scanned as "hen".
            while start > text.startIndex, text[text.index(before: start)].isLetter {
                start = text.index(before: start)
            }
        }
        let offset = text.distance(from: text.startIndex, to: start)
        let tail = String(text[start...])
        // How far an occurrence may shift between partial results (a
        // revised word before it) and still count as the same one.
        let tolerance = language == .chinese ? 4 : 12

        let analysisStart = currentTime()
        var played: [String] = []
        for match in eventEngine.matches(in: tail, language: language) {
            let end = offset + match.end
            guard !heardKeywords.contains(where: { $0.soundID == match.soundID && abs($0.end - end) <= tolerance }) else { continue }
            heardKeywords.append((match.soundID, end))
            if playSound(match.soundID, sourceText: tail, position: end) {
                played.append(match.soundID)
            }
        }
        if heardKeywords.count > 100 { heardKeywords.removeFirst(heardKeywords.count - 100) }
        guard !played.isEmpty else { return }

        let analysisMs = Int(currentTime().timeIntervalSince(analysisStart) * 1000)
        appendLog(text: tail, method: .keyword, waitMs: 0, analysisMs: analysisMs, soundIDs: played)
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
                result, segment: segment, context: context, segmentStart: segmentStart, position: text.count,
                language: segmentLanguage, waitMs: waitMs, analysisStart: analysisStart
            )
        }
    }

    private func handleLLMResult(
        _ result: Result<SoundAnalysis, Error>,
        segment: String, context: String, segmentStart: Int, position: Int,
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
        // The model also sees earlier text and sometimes names its sounds
        // again; a one-shot whose phrase is only in that context was already
        // played (or deliberately not) when that text was read.
        let newText = SoundCache.normalize(segment, language: language)
        let earlierText = SoundCache.normalize(context, language: language)
        let fromContext = known.filter { match in
            let trigger = SoundCache.normalize(match.trigger, language: language)
            return !isAmbience(match.id) && !trigger.isEmpty && !newText.contains(trigger) && earlierText.contains(trigger)
        }.map(\.id)
        let oneShots = known.filter { !isAmbience($0.id) && !fromContext.contains($0.id) }
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
        if !fromContext.isEmpty {
            notes.append("earlier text, skipped: " + fromContext.joined(separator: ", "))
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
        sceneIDs = soundIDs.sorted()
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
        if catalog.info(for: soundID)?.isAmbience == true {
            // A background sound started by a keyword is part of the scene too.
            if currentScene.insert(soundID).inserted { sceneIDs = currentScene.sorted() }
        } else {
            lastOneShot = event
        }
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
        story?.soundCount += 1
        if story?.soundIDs.contains(event.soundID) == false {
            story?.soundIDs.append(event.soundID)
        }
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
