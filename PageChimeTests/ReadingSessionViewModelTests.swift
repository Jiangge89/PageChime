import XCTest
@testable import PageChime

@MainActor
final class ReadingSessionViewModelTests: XCTestCase {
    private var speech: FakeSpeech!
    private var player: FakePlayer!
    private var llm: FakeLLM!
    private var cacheURL: URL!
    private var viewModel: ReadingSessionViewModel!
    private var now = Date()

    override func setUp() async throws {
        speech = FakeSpeech()
        player = FakePlayer()
        llm = FakeLLM()
        cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sound_cache_\(UUID().uuidString).json")
        viewModel = ReadingSessionViewModel(
            speechService: speech,
            soundPlayer: player,
            llmService: llm,
            soundCache: SoundCache(fileURL: cacheURL)
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
            text.contains("strange noise") ? [LLMSoundMatch(id: "owl_hoot", trigger: "strange noise")] : []
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
        llm.responder = { _ in [LLMSoundMatch(id: "frog_croak", trigger: "frog")] }
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
            [LLMSoundMatch(id: "owl_hoot", trigger: "strange noise"),
             LLMSoundMatch(id: "forest_ambience", trigger: "attic")]
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

private final class FakePlayer: SoundEffectPlaying {
    private(set) var playedIDs: [String] = []

    func play(event: StoryEvent) { playedIDs.append(event.soundID) }
    func stopAll() {}
    func setVolume(_: Float) {}
}

/// LLM stand-in whose responses can be held back until `open()` is called.
private final class FakeLLM: SoundMatching, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [String] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = true

    var responder: (String) -> [LLMSoundMatch] = { _ in [] }
    var error: Error?

    var calls: [String] { lock.withLock { recordedCalls } }

    func close() { lock.withLock { isOpen = false } }

    func open() {
        let pending = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume() }
    }

    func analyze(text: String) async throws -> [LLMSoundMatch] {
        lock.withLock { recordedCalls.append(text) }
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
