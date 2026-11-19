import XCTest
@testable import PageChime

@MainActor
final class ReadingSessionViewModelTests: XCTestCase {
    private var speech: FakeSpeech!
    private var player: FakePlayer!
    private var llm: FakeLLM!
    private var cacheURL: URL!
    private var viewModel: ReadingSessionViewModel!
    private var catalog: FakeCatalog!
    private var prefetcher: FakePrefetcher!
    private var pages: FakePageAnalyzer!
    private var recognizer: FakeTextRecognizer!
    private var now = Date()

    override func setUp() async throws {
        speech = FakeSpeech()
        player = FakePlayer()
        llm = FakeLLM()
        catalog = FakeCatalog()
        prefetcher = FakePrefetcher()
        pages = FakePageAnalyzer()
        recognizer = FakeTextRecognizer()
        cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sound_cache_\(UUID().uuidString).json")
        viewModel = ReadingSessionViewModel(
            speechService: speech,
            soundPlayer: player,
            llmService: llm,
            soundCache: SoundCache(fileURL: cacheURL),
            catalog: catalog,
            prefetcher: prefetcher,
            pageAnalyzer: pages,
            textRecognizer: recognizer
        )
        viewModel.currentTime = { [unowned self] in self.now }

        viewModel.toggleListening()
        try await waitUntil { self.viewModel.state == .listening }
    }

    override func tearDown() async throws {
        llm.open()
        viewModel = nil
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: - Tests

    func testKeywordPlaysImmediatelyWithoutWaitingForLLM() async throws {
        llm.close()
        speech.send("The frog")

        try await waitUntil { self.player.playedIDs.contains("frog_croak") }
        XCTAssertTrue(llm.calls.isEmpty, "Short text should not have reached the LLM yet")
    }

    func testNewSpeechDoesNotCancelInFlightLLMRequest() async throws {
        let first = "Something made a strange noise up in the attic"
        let second = first + " after that everybody stayed silent for some time"
        llm.responder = { text in
            text.contains("strange noise") ? .sounds([LLMSoundMatch(id: "owl_hoot", trigger: "strange noise")]) : .none
        }
        llm.close()

        speech.send(first)
        try await waitUntil { self.llm.calls.count == 1 }
        speech.send(second)
        try await waitUntil { self.llm.calls.count == 2 }

        llm.open()
        try await waitUntil { self.player.playedIDs.contains("owl_hoot") }
        XCTAssertEqual(llm.calls.last, String(second.dropFirst(first.count)),
                       "Second request should only contain the new text")
    }

    func testLLMDoesNotReplaySoundAlreadyPlayedByKeywordPath() async throws {
        llm.responder = { _ in .sounds([LLMSoundMatch(id: "frog_croak", trigger: "frog")]) }
        llm.close()

        speech.send("The frog sat quietly by the pond all day")
        try await waitUntil { self.llm.calls.count == 1 }
        XCTAssertEqual(player.playedIDs.filter { $0 == "frog_croak" }.count, 1)

        now = now.addingTimeInterval(3.5) // past cooldown, not yet stale
        llm.open()
        try await waitUntil { self.viewModel.analysisLogs.contains { $0.method == .llm } }

        XCTAssertEqual(player.playedIDs.filter { $0 == "frog_croak" }.count, 1,
                       "LLM result must not replay a sound the keyword path already played")
    }

    func testStaleLLMResultSkipsOneShotsButKeepsAmbience() async throws {
        llm.responder = { _ in
            .sounds([LLMSoundMatch(id: "owl_hoot", trigger: "strange noise"),
                     LLMSoundMatch(id: "forest_ambience", trigger: "attic")])
        }
        llm.close()

        speech.send("Something made a strange noise up in the attic")
        try await waitUntil { self.llm.calls.count == 1 }

        now = now.addingTimeInterval(5)
        llm.open()
        try await waitUntil { self.viewModel.analysisLogs.contains { $0.method == .llm } }

        XCTAssertTrue(player.playedIDs.contains("forest_ambience"))
        XCTAssertFalse(player.playedIDs.contains("owl_hoot"))
        XCTAssertNotNil(viewModel.analysisLogs.first { $0.method == .llm }?.note)
    }

    func testLLMFailureIsLoggedAsError() async throws {
        llm.error = URLError(.timedOut)

        speech.send("Something made a strange noise up in the attic")
        try await waitUntil { self.viewModel.analysisLogs.contains { $0.method == .error } }
    }

    func testLLMSceneReplacesAmbienceAndPlaysOneShots() async throws {
        llm.responder = { _ in
            SoundAnalysis(
                sounds: [LLMSoundMatch(id: "thunder", trigger: "strange noise")],
                ambience: ["storm", "rain_light"]
            )
        }

        speech.send("Something made a strange noise up in the attic")
        try await waitUntil { self.viewModel.analysisLogs.contains { $0.method == .llm } }

        XCTAssertEqual(player.sceneCalls.last, ["rain_light", "storm"])
        XCTAssertTrue(player.playedIDs.contains("thunder"))
    }

    func testNullAmbienceKeepsCurrentScene() async throws {
        llm.responder = { _ in .sounds([LLMSoundMatch(id: "owl_hoot", trigger: "strange noise")]) }

        speech.send("Something made a strange noise up in the attic")
        try await waitUntil { self.viewModel.analysisLogs.contains { $0.method == .llm } }

        XCTAssertTrue(player.sceneCalls.isEmpty)
    }

    func testLLMReceivesEarlierStoryAsContext() async throws {
        let first = "Something made a strange noise up in the attic"
        let second = first + " after that everybody stayed silent for some time"

        speech.send(first)
        try await waitUntil { self.llm.contexts.count == 1 }
        speech.send(second)
        try await waitUntil { self.llm.contexts.count == 2 }

        XCTAssertEqual(llm.contexts, ["", first])
    }

    func testCacheHitPlaysInstantlyAndStillAsksLLMForScene() async throws {
        llm.responder = { text in
            text.contains("strange noise") ? .sounds([LLMSoundMatch(id: "owl_hoot", trigger: "strange noise")]) : .none
        }
        let first = "Something made a strange noise up in the attic"
        speech.send(first)
        try await waitUntil { self.player.playedIDs.contains("owl_hoot") }

        llm.close()
        now = now.addingTimeInterval(5)
        speech.send(first + " and later another strange noise came from the stairs")
        try await waitUntil { self.viewModel.analysisLogs.contains { $0.method == .cache } }

        XCTAssertEqual(player.playedIDs.filter { $0 == "owl_hoot" }.count, 2, "Cache should play without the LLM")
        try await waitUntil { self.llm.calls.count == 2 }
    }

    func testCloudLibrarySoundsArePlayedAndUnknownOnesIgnored() async throws {
        catalog.cloud["wolf_howl"] = SoundInfo(isAmbience: false, type: .animal, entity: "wolf", intensity: .normal)
        catalog.cloud["cave_drips"] = SoundInfo(isAmbience: true, type: .environment, entity: "cave", intensity: .normal)
        llm.responder = { _ in
            SoundAnalysis(
                sounds: [LLMSoundMatch(id: "wolf_howl", trigger: "strange noise"),
                         LLMSoundMatch(id: "not_a_sound", trigger: "attic")],
                ambience: ["cave_drips", "unknown_bed"]
            )
        }

        speech.send("Something made a strange noise up in the attic")
        try await waitUntil { self.viewModel.analysisLogs.contains { $0.method == .llm } }

        XCTAssertEqual(player.playedIDs, ["wolf_howl"])
        XCTAssertEqual(player.sceneCalls.last, ["cave_drips"])
        XCTAssertEqual(viewModel.recentEffects.first { $0.soundID == "wolf_howl" }?.entity, "wolf")
    }

    func testUpcomingSoundsArePrefetched() async throws {
        catalog.cloud["wolf_growl"] = SoundInfo(isAmbience: false, type: .animal, entity: "wolf", intensity: .normal)
        llm.responder = { _ in
            SoundAnalysis(sounds: [], ambience: nil, upcoming: ["wolf_growl", "door_knock", "not_a_sound"])
        }

        speech.send("Something made a strange noise up in the attic")
        try await waitUntil { !self.prefetcher.requested.isEmpty }

        XCTAssertEqual(prefetcher.requested, [["wolf_growl", "door_knock"]], "Unknown ids are not prefetched")
        XCTAssertTrue(player.playedIDs.isEmpty, "Upcoming sounds are not played")
        try await waitUntil { self.viewModel.analysisLogs.first?.note?.contains("prefetch: wolf_growl") == true }
    }

    func testLongTextAndCloudSoundNamesAreSentWithoutWaitingForAPause() async throws {
        catalog.names = ["wolf"]
        viewModel.segmentPolicy = { _ in SegmentPolicy(maxChars: 60, hotWordMinChars: 12, pauseTiers: [(5, 1)]) }

        speech.send("Then the fox came closer")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(llm.calls.isEmpty, "Short text without a cloud sound waits for a pause")

        speech.send("Then the fox came closer and the wolf")
        try await waitUntil(timeout: 1) { self.llm.calls.count == 1 }

        let long = "Then the fox came closer and the wolf"
            + " walked slowly all the way along the river bank to the old mill"
        speech.send(long)
        try await waitUntil(timeout: 1) { self.llm.calls.count == 2 }
        XCTAssertEqual(llm.calls.last, String(long.dropFirst("Then the fox came closer and the wolf".count)))
    }

    func testShortFragmentWaitsForALongerPause() async throws {
        viewModel.segmentPolicy = { _ in
            SegmentPolicy(maxChars: 60, hotWordMinChars: 12, pauseTiers: [(0.1, 30), (0.3, 12), (0.6, 1)])
        }
        speech.send("And then")
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertTrue(llm.calls.isEmpty, "Eight characters are too few for the first two pauses")
        try await waitUntil(timeout: 2) { self.llm.calls == ["And then"] }

        speech.send("And then the rain stopped")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(llm.calls.count, 1, "17 new characters wait past the first pause")
        try await waitUntil(timeout: 2) { self.llm.calls.count == 2 }
    }

    // MARK: - Scanned Page

    private func addCloudWolfAndCave() {
        catalog.cloud["wolf_howl"] = SoundInfo(isAmbience: false, type: .animal, entity: "wolf", intensity: .normal)
        catalog.cloud["cave_drips"] = SoundInfo(isAmbience: true, type: .environment, entity: "cave", intensity: .normal)
    }

    func testScannedPagePlaysCueTheMomentItsPhraseIsRead() async throws {
        addCloudWolfAndCave()
        pages.result = PageAnalysis(
            cues: [LLMSoundMatch(id: "wolf_howl", trigger: "the wolf howled at the moon"),
                   LLMSoundMatch(id: "cave_drips", trigger: "into the dark cave"),
                   LLMSoundMatch(id: "not_a_sound", trigger: "something")],
            ambience: ["forest_ambience"],
            upcoming: ["owl_hoot"]
        )
        await viewModel.loadPage(text: "page text")

        XCTAssertEqual(viewModel.pageStatus, .ready(cues: 2))
        XCTAssertEqual(prefetcher.requested.last, ["wolf_howl", "cave_drips", "forest_ambience", "owl_hoot"])
        XCTAssertEqual(player.sceneCalls.last, ["forest_ambience"], "The page's opening scene starts at once")
        XCTAssertTrue(speech.contextualStrings.contains("the wolf howled at the moon"))

        llm.close() // cues must not wait for the LLM
        speech.send("Far away the wolf howled at the moon")
        try await waitUntil(timeout: 0.5) { self.player.playedIDs.contains("wolf_howl") }
        XCTAssertTrue(viewModel.analysisLogs.contains { $0.method == .page && $0.soundIDs == ["wolf_howl"] })

        speech.send("Far away the wolf howled at the moon and ran into the dark cave")
        try await waitUntil(timeout: 0.5) { self.player.sceneCalls.last == ["cave_drips"] }

        now = now.addingTimeInterval(10)
        speech.send("Far away the wolf howled at the moon and ran into the dark cave. Again the wolf howled at the moon")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(player.playedIDs.filter { $0 == "wolf_howl" }.count, 1, "Each cue plays once per reading")
    }

    func testLongCueStillFiresWhenItsFirstWordIsMisheard() async throws {
        addCloudWolfAndCave()
        pages.result = PageAnalysis(
            cues: [LLMSoundMatch(id: "wolf_howl", trigger: "the grey wolf howled loudly")], ambience: nil, upcoming: []
        )
        await viewModel.loadPage(text: "page text")
        llm.close()

        speech.send("then the gray wolf howled loudly")
        try await waitUntil(timeout: 0.5) { self.player.playedIDs.contains("wolf_howl") }
    }

    func testPageFailuresAreReported() async throws {
        recognizer.text = "  "
        await viewModel.scanPage([UIImage()])
        guard case .failed = viewModel.pageStatus else { return XCTFail("Expected failure, got \(viewModel.pageStatus)") }

        recognizer.text = "The wolf howled"
        pages.error = URLError(.timedOut)
        await viewModel.scanPage([UIImage()])
        guard case .failed = viewModel.pageStatus else { return XCTFail("Expected failure, got \(viewModel.pageStatus)") }
        XCTAssertEqual(pages.texts, ["The wolf howled"])

        viewModel.clearPage()
        XCTAssertEqual(viewModel.pageStatus, .none)
    }

    func testPageSummaryNumbersPagesAndCountsTheStory() async throws {
        addCloudWolfAndCave()
        viewModel.beginStory()
        pages.result = PageAnalysis(
            cues: [LLMSoundMatch(id: "wolf_howl", trigger: "the wolf howled at the moon"),
                   LLMSoundMatch(id: "cave_drips", trigger: "into the dark cave")],
            ambience: nil, upcoming: []
        )
        await viewModel.loadPage(text: "The wolf howled at the moon.")

        XCTAssertEqual(viewModel.page?.number, 1)
        XCTAssertEqual(viewModel.page?.text, "The wolf howled at the moon.")
        XCTAssertEqual(viewModel.page?.cues.map(\.soundID), ["wolf_howl", "cave_drips"])
        XCTAssertEqual(viewModel.page?.cues.map(\.isAmbience), [false, true])
        XCTAssertEqual(viewModel.firedCueCount, 0)

        llm.close()
        speech.send("Far away the wolf howled at the moon")
        try await waitUntil(timeout: 0.5) { self.viewModel.firedCueCount == 1 }
        XCTAssertEqual(viewModel.story?.soundIDs, ["wolf_howl"])
        XCTAssertEqual(viewModel.recentEffects.first?.soundID, "wolf_howl")

        await viewModel.loadPage(text: "The wolf howled at the moon, again.", replacing: true)
        XCTAssertEqual(viewModel.page?.number, 1, "A rescan replaces the page")
        XCTAssertEqual(viewModel.firedCueCount, 0)
        await viewModel.loadPage(text: "Page two")
        XCTAssertEqual(viewModel.page?.number, 2)
        XCTAssertEqual(viewModel.story?.pages, 2)

        viewModel.resetStory()
        XCTAssertNil(viewModel.story)
        XCTAssertNil(viewModel.page)
    }

    func testPauseKeepsPlayedCuesAndResumeDoesNotReplayThem() async throws {
        addCloudWolfAndCave()
        pages.result = PageAnalysis(
            cues: [LLMSoundMatch(id: "wolf_howl", trigger: "the wolf howled at the moon")], ambience: nil, upcoming: []
        )
        await viewModel.loadPage(text: "page text")
        llm.close()
        speech.send("the wolf howled at the moon")
        try await waitUntil(timeout: 0.5) { self.player.playedIDs.contains("wolf_howl") }

        viewModel.pauseReading()
        XCTAssertTrue(viewModel.isPaused)
        XCTAssertEqual(viewModel.state, .ready)
        XCTAssertEqual(viewModel.firedCueCount, 1)

        viewModel.resumeReading()
        try await waitUntil { self.viewModel.state == .listening }
        XCTAssertFalse(viewModel.isPaused)
        speech.send("the wolf howled at the moon")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(player.playedIDs.filter { $0 == "wolf_howl" }.count, 1, "Resuming doesn't replay the page")

        viewModel.endStory()
        XCTAssertEqual(viewModel.state, .ready)
    }

    func testSceneIsPublishedAndClearedOnStop() async throws {
        llm.responder = { _ in SoundAnalysis(sounds: [], ambience: ["rain_light"]) }
        speech.send("It began to rain softly on the little house that night")
        try await waitUntil { self.viewModel.sceneIDs == ["rain_light"] }
        viewModel.pauseReading()
        XCTAssertEqual(viewModel.sceneIDs, [])
    }

    func testSpeechActivityIsReportedForDucking() async throws {
        speech.send("Once upon a time")
        try await waitUntil { self.player.speechActivityCount > 0 }
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval = 3,
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

// MARK: - Fakes

private final class FakeSpeech: SpeechRecognizing {
    var transcript = ""
    var state: ListeningState = .ready
    var onTranscriptUpdate: ((String) -> Void)?
    var onStateChange: ((ListeningState) -> Void)?
    var contextualStrings: [String] = []

    func requestPermissions() async -> Bool { true }

    func start(language _: ReadingLanguage) async throws {
        state = .listening
        onStateChange?(.listening)
    }

    func stop() {
        state = .ready
    }

    func send(_ text: String) {
        transcript = text
        onTranscriptUpdate?(text)
    }
}

/// Bundled sounds plus whatever a test adds as "cloud" sounds.
private final class FakeCatalog: SoundCatalogProviding {
    var cloud: [String: SoundInfo] = [:]
    var names: Set<String> = []
    func cloudSoundNames() -> Set<String> { names }
    func info(for soundID: String) -> SoundInfo? {
        BundledSoundCatalog.shared.info(for: soundID) ?? cloud[soundID]
    }
}

private final class FakePageAnalyzer: PageAnalyzing {
    var result = PageAnalysis(cues: [], ambience: nil, upcoming: [])
    var error: Error?
    private(set) var texts: [String] = []
    func analyzePage(text: String, context _: String) async throws -> PageAnalysis {
        texts.append(text)
        if let error { throw error }
        return result
    }
}

private final class FakeTextRecognizer: PageTextRecognizing {
    var text = ""
    func recognizeText(in _: [UIImage], language _: ReadingLanguage) async throws -> String { text }
}

private final class FakePrefetcher: SoundPrefetching {
    private(set) var requested: [[String]] = []
    func prefetch(_ soundIDs: [String]) -> [String] {
        if !soundIDs.isEmpty { requested.append(soundIDs) }
        return soundIDs
    }
}

private final class FakePlayer: SoundEffectPlaying {
    private(set) var playedIDs: [String] = []
    private(set) var sceneCalls: [[String]] = []
    private(set) var speechActivityCount = 0

    func play(event: StoryEvent) { playedIDs.append(event.soundID) }
    func setAmbience(_ events: [StoryEvent]) { sceneCalls.append(events.map(\.soundID).sorted()) }
    func noteSpeechActivity() { speechActivityCount += 1 }
    func stopAll() {}
    func setVolume(_: Float) {}
}

/// LLM stand-in whose responses can be held back until `open()` is called.
private final class FakeLLM: SoundMatching, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [String] = []
    private var recordedContexts: [String] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = true

    var responder: (String) -> SoundAnalysis = { _ in .none }
    var error: Error?

    var calls: [String] { lock.withLock { recordedCalls } }
    var contexts: [String] { lock.withLock { recordedContexts } }

    func close() { lock.withLock { isOpen = false } }

    func open() {
        let pending = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume() }
    }

    func analyze(text: String, context: String) async throws -> SoundAnalysis {
        lock.withLock {
            recordedCalls.append(text)
            recordedContexts.append(context)
        }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        if let error { throw error }
        return responder(text)
    }
}

private extension SoundAnalysis {
    static let none = SoundAnalysis(sounds: [], ambience: nil)
    static func sounds(_ matches: [LLMSoundMatch]) -> SoundAnalysis {
        SoundAnalysis(sounds: matches, ambience: nil)
    }
}
