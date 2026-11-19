import XCTest
@testable import PageChime

final class SoundLibraryTests: XCTestCase {
    private var root: URL!

    private let manifest: [String: Any] = [
        "version": 7,
        "sounds": [
            [
                "id": "wolf_howl", "kind": "oneShot", "name": "wolf", "category": "animal",
                "description": "a lone wolf howling",
                "variants": [
                    ["file": "wolf_howl.aaaa.m4a", "duration": 2.0, "bytes": 4],
                    ["file": "wolf_howl.bbbb.m4a", "duration": 2.0, "bytes": 4],
                ],
            ],
            [
                "id": "cave_drips", "kind": "ambience", "name": "cave", "category": "spaceship",
                "description": "dripping cave",
                "variants": [["file": "cave_drips.cccc.m4a", "duration": 60.0, "bytes": 4]],
            ],
        ],
    ]

    override func setUp() {
        super.setUp()
        StubServer.reset()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SoundLibraryTests-\(UUID().uuidString)")
        StubServer.dataRoutes["/v1/library"] = { [manifest] request in
            if request.headers["If-None-Match"] == "\"v7\"" { return (304, Data(), ["ETag": "\"v7\""]) }
            return (200, try! JSONSerialization.data(withJSONObject: manifest), ["ETag": "\"v7\""])
        }
        for file in ["wolf_howl.aaaa.m4a", "wolf_howl.bbbb.m4a", "cave_drips.cccc.m4a"] {
            StubServer.dataRoutes["/v1/sounds/\(file)"] = { _ in (200, Data(file.utf8), [:]) }
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        StubServer.reset()
        super.tearDown()
    }

    private func makeLibrary(maxCacheBytes: Int = 1_000_000) -> SoundLibrary {
        let backend = Backend(
            baseURL: URL(string: "https://api.test")!,
            apiSession: StubServer.session, downloadSession: StubServer.session,
            sessions: StaticSessions()
        )
        return SoundLibrary(
            backend: backend,
            directory: root.appendingPathComponent("support"),
            cacheDirectory: root.appendingPathComponent("cache"),
            maxCacheBytes: maxCacheBytes
        )
    }

    private func requests(_ path: String) -> Int {
        StubServer.requests.filter { $0.path == path }.count
    }

    func testRefreshLoadsManifestAndDescribesCloudSounds() async {
        let library = makeLibrary()
        XCTAssertNil(library.info(for: "wolf_howl"))

        await library.refresh()

        XCTAssertEqual(library.version, 7)
        XCTAssertEqual(
            library.info(for: "wolf_howl"),
            SoundInfo(isAmbience: false, type: .animal, entity: "wolf", intensity: .normal)
        )
        XCTAssertEqual(library.info(for: "cave_drips")?.isAmbience, true)
        XCTAssertEqual(library.info(for: "cave_drips")?.type, .environment, "Unknown categories fall back")
        XCTAssertEqual(library.info(for: "dog_bark")?.entity, "dog", "Bundled sounds still resolve")
        XCTAssertEqual(library.cloudSoundNames(), ["wolf"], "Only one-shot names count")
    }

    func testManifestPersistsAndUnchangedManifestIsNotRedownloaded() async {
        await makeLibrary().refresh()

        let reopened = makeLibrary()
        XCTAssertEqual(reopened.version, 7, "Stored manifest is available offline")

        await reopened.refresh()
        let last = StubServer.requests.last { $0.path == "/v1/library" }
        XCTAssertEqual(last?.headers["If-None-Match"], "\"v7\"")
        XCTAssertEqual(reopened.version, 7)
    }

    func testFetchDownloadsVariantsAndLocalFileAvoidsRepeats() async throws {
        let library = makeLibrary()
        await library.refresh()
        XCTAssertNil(library.localFile(for: "wolf_howl"))

        let first = try await library.fetchFile(for: "wolf_howl")
        let second = try await library.fetchFile(for: "wolf_howl")
        XCTAssertNotEqual(first.lastPathComponent, second.lastPathComponent, "Fetch prefers a missing variant")
        XCTAssertEqual(try String(contentsOf: first), first.lastPathComponent)

        var picks: [String] = []
        for _ in 0..<6 {
            picks.append(try XCTUnwrap(library.localFile(for: "wolf_howl")).lastPathComponent)
        }
        for (a, b) in zip(picks, picks.dropFirst()) {
            XCTAssertNotEqual(a, b, "The same variant should not play twice in a row")
        }
    }

    func testConcurrentFetchesShareOneDownload() async throws {
        let library = makeLibrary()
        await library.refresh()

        async let a = library.fetchFile(for: "cave_drips")
        async let b = library.fetchFile(for: "cave_drips")
        let urls = try await [a, b]

        XCTAssertEqual(urls[0], urls[1])
        XCTAssertEqual(requests("/v1/sounds/cave_drips.cccc.m4a"), 1)
    }

    func testCacheEvictsLeastRecentlyUsedFiles() async throws {
        // Each stub file is ~18 bytes; allow room for about one.
        let library = makeLibrary(maxCacheBytes: 25)
        await library.refresh()

        let cave = try await library.fetchFile(for: "cave_drips")
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: cave.path)
        let wolf = try await library.fetchFile(for: "wolf_howl")

        XCTAssertFalse(FileManager.default.fileExists(atPath: cave.path), "Older file should be evicted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wolf.path))
    }

    func testPrefetchDownloadsOneVariantOfEachMissingCloudSound() async throws {
        let library = makeLibrary()
        await library.refresh()

        let queued = library.prefetch(["wolf_howl", "cave_drips", "wolf_howl", "dog_bark", "nope"])
        XCTAssertEqual(queued, ["wolf_howl", "cave_drips"], "Bundled-only and unknown sounds are skipped")
        XCTAssertEqual(library.prefetch(["wolf_howl"]), [], "Already queued")

        let wolfRequests = { self.requests("/v1/sounds/wolf_howl.aaaa.m4a") + self.requests("/v1/sounds/wolf_howl.bbbb.m4a") }
        let deadline = Date().addingTimeInterval(3)
        while (requests("/v1/sounds/cave_drips.cccc.m4a") == 0 || wolfRequests() == 0), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000) // let the downloads land on disk
        XCTAssertEqual(requests("/v1/sounds/cave_drips.cccc.m4a"), 1)
        XCTAssertEqual(wolfRequests(), 1,
                       "Prefetch takes one variant; more come as the sound is used")
        XCTAssertEqual(library.prefetch(["wolf_howl", "cave_drips"]), [], "Already on disk")
    }

    func testUnknownSoundCannotBeFetched() async {
        let library = makeLibrary()
        await library.refresh()
        do {
            _ = try await library.fetchFile(for: "nope")
            XCTFail("Expected an error")
        } catch {}
        XCTAssertFalse(library.hasCloudVariants("nope"))
        XCTAssertTrue(library.hasCloudVariants("wolf_howl"))
    }
}
