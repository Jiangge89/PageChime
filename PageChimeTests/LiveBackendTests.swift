import AVFoundation
import XCTest
@testable import PageChime

/// End-to-end checks against a running backend (`npm run dev` in backend/,
/// with a library uploaded via `build-library.mjs --upload local`).
/// Skipped unless PAGECHIME_LIVE_BACKEND is set, e.g.:
///
///   TEST_RUNNER_PAGECHIME_LIVE_BACKEND=http://localhost:8787 xcodebuild test ...
final class LiveBackendTests: XCTestCase {
    private var backend: Backend!
    private var root: URL!

    override func setUpWithError() throws {
        guard let value = ProcessInfo.processInfo.environment["PAGECHIME_LIVE_BACKEND"],
              let url = URL(string: value)
        else { throw XCTSkip("Set PAGECHIME_LIVE_BACKEND to run live backend tests") }
        backend = Backend(baseURL: url)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Live-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    func testLibraryDownloadsAndStreamsCloudAmbience() async throws {
        let library = SoundLibrary(
            backend: backend,
            directory: root.appendingPathComponent("support"),
            cacheDirectory: root.appendingPathComponent("cache")
        )
        await library.refresh()
        XCTAssertGreaterThan(library.version, 0, "Library manifest should load")

        let ambience = try XCTUnwrap(
            ["test_brook"].first { library.info(for: $0)?.isAmbience == true },
            "Upload the test library first"
        )
        let url = try await library.fetchFile(for: ambience)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.sampleRate, 44100)
        XCTAssertEqual(file.processingFormat.channelCount, 2)

        let player = SoundEffectPlayer(buffers: AudioBufferCache(preload: false), catalog: library, cloud: library)
        defer { player.stopAll() }
        player.play(event: StoryEvent(
            id: UUID(), type: .environment, entity: "brook", soundID: ambience,
            intensity: .normal, delayMilliseconds: 0, cooldownSeconds: 3, sourceText: ""
        ))
        XCTAssertEqual(player.streamedAmbienceIDs, [ambience])
    }

    func testAnalysisRoundTrip() async throws {
        let result = try await BackendSoundMatcher(backend: backend)
            .analyze(text: "The door creaked and then someone knocked twice", context: "")
        print("live analysis:", result.sounds.map(\.id), result.ambience ?? [])
        XCTAssertFalse(result.sounds.isEmpty)
    }
}
