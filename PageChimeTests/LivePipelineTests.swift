import XCTest
@testable import PageChime

/// End-to-end runs of the reading pipeline against a running backend:
/// real text recognition, page analysis, scene LLM, sound library and
/// cue matching. Only the microphone (a scripted reader) and the speaker
/// (a recorder) are stand-ins. Skipped unless PAGECHIME_LIVE_BACKEND is set:
///
///   TEST_RUNNER_PAGECHIME_LIVE_BACKEND=http://localhost:8787 xcodebuild test ...
@MainActor
final class LivePipelineTests: XCTestCase {
    private var backend: Backend!
    private var root: URL!
    private var library: SoundLibrary!

    static let pageOne = """
    Suddenly a big grey wolf stepped out from behind an oak. The wolf howled at the moon. \
    He knocked on the cottage door, knock knock. The old door creaked open. \
    Thunder rolled across the sky and rain poured down on the little house.
    """

    override func setUp() async throws {
        guard let value = ProcessInfo.processInfo.environment["PAGECHIME_LIVE_BACKEND"],
              let url = URL(string: value)
        else { throw XCTSkip("Set PAGECHIME_LIVE_BACKEND to run live pipeline tests") }
        backend = Backend(baseURL: url)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Pipeline-\(UUID().uuidString)")
        library = SoundLibrary(
            backend: backend,
            directory: root.appendingPathComponent("support"),
            cacheDirectory: root.appendingPathComponent("cache")
        )
        await library.refresh()
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    private func makeViewModel(script: String, player: RecordingPlayer) -> (ReadingSessionViewModel, ScriptedSpeechRecognizer) {
        let speech = ScriptedSpeechRecognizer(script: script, wordsPerSecond: 6)
        let matcher = BackendSoundMatcher(backend: backend)
        let viewModel = ReadingSessionViewModel(
            speechService: speech,
            soundPlayer: player,
            llmService: matcher,
            soundCache: SoundCache(fileURL: root.appendingPathComponent("cache.json")),
            catalog: library,
            prefetcher: library,
            pageAnalyzer: matcher,
            textRecognizer: VisionTextRecognizer()
        )
        return (viewModel, speech)
    }

    /// Scan → page analysis → read aloud: every cue on the page plays, in
    /// the order its words are read, and the story counts the page.
    func testScannedPagePlaysEachCueAsItsWordsAreRead() async throws {
        let player = RecordingPlayer()
        let (viewModel, speech) = makeViewModel(script: Self.pageOne, player: player)
        viewModel.beginStory()

        await viewModel.scanPage([UITestHooks.renderPage(Self.pageOne)])
        guard case .ready(let cueCount) = viewModel.pageStatus, let page = viewModel.page else {
            return XCTFail("Page didn't analyze: \(viewModel.pageStatus)")
        }
        print("page cues:", page.cues.map { "\($0.soundID) ← \"\($0.trigger)\"" })
        XCTAssertGreaterThanOrEqual(cueCount, 3, "A page this eventful should have several cues")
        XCTAssertTrue(page.text.lowercased().contains("wolf howled"), "OCR text: \(page.text)")
        XCTAssertEqual(viewModel.story?.pages, 1)

        viewModel.startReading()
        try await waitUntil(timeout: 40) { speech.isFinished && viewModel.firedCueCount == cueCount }

        // One-shots play in reading order.
        // Recognized text keeps the page's line breaks; phrases may span them.
        let pageText = page.text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        func position(_ cue: PageSummary.Cue) -> Int {
            pageText.range(of: cue.trigger.lowercased()).map { pageText.distance(from: pageText.startIndex, to: $0.lowerBound) } ?? .max
        }
        let expected = page.cues.filter { !$0.isAmbience }.sorted { position($0) < position($1) }.map(\.soundID)
        let cuePlays = player.played.filter { expected.contains($0) }
        XCTAssertEqual(Array(NSOrderedSet(array: cuePlays)) as? [String], Array(NSOrderedSet(array: expected)) as? [String])
        XCTAssertTrue(viewModel.analysisLogs.contains { $0.method == .page && !$0.soundIDs.isEmpty })
        XCTAssertGreaterThanOrEqual(viewModel.story?.soundCount ?? 0, expected.count)

        viewModel.endStory()
        XCTAssertNotNil(viewModel.story?.endedAt)
    }

    /// Reading without scanning: the keyword path plays obvious sounds at
    /// once, and the scene LLM sets the ambience from the story.
    func testReadingWithoutScanningFollowsTheScene() async throws {
        let player = RecordingPlayer()
        let script = "Night fell over the dark forest. An owl hooted in the tall trees while the wind blew softly. Then a dog barked far away."
        let (viewModel, speech) = makeViewModel(script: script, player: player)

        viewModel.startReading()
        try await waitUntil(timeout: 40) {
            speech.isFinished && !player.scenes.isEmpty && viewModel.analysisLogs.contains { $0.method == .llm }
        }
        try await Task.sleep(nanoseconds: 3_000_000_000) // let the last segment's answer land
        print("played:", player.played, "scenes:", player.scenes, "logs:", viewModel.analysisLogs.map { "\($0.method.rawValue) \($0.soundIDs)" })

        XCTAssertTrue(player.played.contains("dog_bark"), "Keyword path should play the dog")
        XCTAssertTrue(viewModel.analysisLogs.contains { $0.method == .keyword })
        let scene = Set(player.scenes.flatMap { $0 })
        XCTAssertFalse(scene.isDisjoint(with: ["forest_ambience", "night_ambience", "wind", "owl_hoot", "crickets"]),
                       "The LLM should set a forest or night scene, got \(scene)")
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("Timed out after \(timeout)s") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

/// Records what would have been played.
private final class RecordingPlayer: SoundEffectPlaying {
    private(set) var played: [String] = []
    private(set) var scenes: [[String]] = []
    func play(event: StoryEvent) { played.append(event.soundID) }
    func setAmbience(_ events: [StoryEvent]) { scenes.append(events.map(\.soundID).sorted()) }
    func noteSpeechActivity() {}
    func stopAll() {}
    func setVolume(_: Float) {}
}
