import CryptoKit
import XCTest
@testable import PageChime

final class BackendSoundMatcherTests: XCTestCase {
    private let baseURL = URL(string: "https://api.test")!
    private var defaults: UserDefaults!
    private var defaultsName: String!

    override func setUp() {
        super.setUp()
        StubServer.reset()
        defaultsName = "BackendSoundMatcherTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsName)
        StubServer.reset()
        super.tearDown()
    }

    private var urlSession: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubServer.self]
        return URLSession(configuration: config)
    }

    private func provider(attest: FakeAttest = FakeAttest(supported: false), allowDev: Bool = true) -> AppAttestSessionProvider {
        AppAttestSessionProvider(
            http: BackendHTTP(baseURL: baseURL, session: urlSession),
            attest: attest,
            defaults: defaults,
            allowDevSessions: allowDev
        )
    }

    private func matcher(sessions: SessionProviding? = nil) -> BackendSoundMatcher {
        BackendSoundMatcher(backend: Backend(
            baseURL: baseURL, apiSession: urlSession, downloadSession: urlSession,
            sessions: sessions ?? provider()
        ))
    }

    // MARK: - Analysis

    func testAnalyzeSendsTextWithTokenAndParsesResult() async throws {
        StubServer.routes["/v1/dev-session"] = { _ in (200, ["token": "T1", "expiresIn": 3600]) }
        StubServer.routes["/v1/analyze"] = { _ in
            (200, [
                "sounds": [["id": "owl_hoot", "trigger": "an owl"]],
                "ambience": ["night_ambience", "not_in_app"],
                "upcoming": ["wolf_howl"],
            ])
        }

        let result = try await matcher().analyze(text: "an owl hooted", context: "it was night")

        XCTAssertEqual(result.sounds.map(\.id), ["owl_hoot"])
        XCTAssertEqual(result.sounds.first?.trigger, "an owl")
        // Unknown ids pass through; the view model filters what it can't play.
        XCTAssertEqual(result.ambience, ["night_ambience", "not_in_app"])
        XCTAssertEqual(result.upcoming, ["wolf_howl"])

        let request = try XCTUnwrap(StubServer.requests.last { $0.path == "/v1/analyze" })
        XCTAssertEqual(request.authorization, "Bearer T1")
        XCTAssertEqual(request.body["text"] as? String, "an owl hooted")
        XCTAssertEqual(request.body["context"] as? String, "it was night")
    }

    func testNullAmbienceStaysNil() async throws {
        StubServer.routes["/v1/dev-session"] = { _ in (200, ["token": "T1", "expiresIn": 3600]) }
        StubServer.routes["/v1/analyze"] = { _ in (200, ["sounds": [], "ambience": NSNull()]) }

        let result = try await matcher().analyze(text: "hello", context: "")
        XCTAssertNil(result.ambience)
        XCTAssertEqual(result.upcoming, [], "Older servers send no upcoming list")
    }

    func testExpiredTokenIsRefreshedOnce() async throws {
        var issued = 0
        StubServer.routes["/v1/dev-session"] = { _ in
            issued += 1
            return (200, ["token": "T\(issued)", "expiresIn": 3600])
        }
        StubServer.routes["/v1/analyze"] = { request in
            request.authorization == "Bearer T2" ? (200, ["sounds": []]) : (401, ["error": "expired"])
        }

        _ = try await matcher().analyze(text: "hello", context: "")
        XCTAssertEqual(issued, 2)
        XCTAssertEqual(StubServer.requests.filter { $0.path == "/v1/analyze" }.count, 2)
    }

    func testServerErrorIsThrown() async {
        StubServer.routes["/v1/dev-session"] = { _ in (200, ["token": "T1", "expiresIn": 3600]) }
        StubServer.routes["/v1/analyze"] = { _ in (504, ["error": "model timed out"]) }

        do {
            _ = try await matcher().analyze(text: "hello", context: "")
            XCTFail("Expected an error")
        } catch BackendError.http(let code) {
            XCTAssertEqual(code, 504)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testMissingBackendURLMeansNotConfigured() async {
        let matcher = BackendSoundMatcher(backend: nil)
        do {
            _ = try await matcher.analyze(text: "hello", context: "")
            XCTFail("Expected an error")
        } catch BackendError.notConfigured {
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    // MARK: - Sessions

    func testSessionTokenIsReused() async throws {
        StubServer.routes["/v1/dev-session"] = { _ in (200, ["token": "T1", "expiresIn": 3600]) }
        let sessions = provider()

        let first = try await sessions.token()
        let second = try await sessions.token()

        XCTAssertEqual(first, second)
        XCTAssertEqual(StubServer.requests.count, 1)
    }

    func testReleaseBuildWithoutAppAttestFails() async {
        do {
            _ = try await provider(allowDev: false).token()
            XCTFail("Expected an error")
        } catch BackendError.attestationUnsupported {
            XCTAssertTrue(StubServer.requests.isEmpty)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testNewDeviceAttestsKeyAndStoresIt() async throws {
        let attest = FakeAttest(supported: true)
        StubServer.routes["/v1/challenge"] = { _ in (200, ["challenge": "C1"]) }
        StubServer.routes["/v1/attest"] = { _ in (200, ["token": "A1", "expiresIn": 3600]) }

        let token = try await provider(attest: attest).token()

        XCTAssertEqual(token, "A1")
        XCTAssertEqual(defaults.string(forKey: AppAttestSessionProvider.keyIdDefaultsKey), "KEY-1")
        XCTAssertEqual(attest.attestedHashes, [Data(SHA256.hash(data: Data("C1".utf8)))])

        let request = try XCTUnwrap(StubServer.requests.last)
        XCTAssertEqual(request.body["keyId"] as? String, "KEY-1")
        XCTAssertEqual(request.body["challenge"] as? String, "C1")
        XCTAssertEqual(request.body["attestation"] as? String, Data("attestation".utf8).base64EncodedString())
    }

    func testKnownDeviceSignsAssertion() async throws {
        defaults.set("KEY-0", forKey: AppAttestSessionProvider.keyIdDefaultsKey)
        let attest = FakeAttest(supported: true)
        StubServer.routes["/v1/challenge"] = { _ in (200, ["challenge": "C2"]) }
        StubServer.routes["/v1/assert"] = { _ in (200, ["token": "S1", "expiresIn": 3600]) }

        let token = try await provider(attest: attest).token()

        XCTAssertEqual(token, "S1")
        XCTAssertEqual(attest.assertedKeys, ["KEY-0"])
        XCTAssertTrue(attest.attestedHashes.isEmpty)
    }

    func testUnknownKeyIsReplacedWithNewAttestation() async throws {
        defaults.set("KEY-0", forKey: AppAttestSessionProvider.keyIdDefaultsKey)
        let attest = FakeAttest(supported: true)
        StubServer.routes["/v1/challenge"] = { _ in (200, ["challenge": "C3"]) }
        StubServer.routes["/v1/assert"] = { _ in (404, ["error": "unknown key"]) }
        StubServer.routes["/v1/attest"] = { _ in (200, ["token": "A2", "expiresIn": 3600]) }

        let token = try await provider(attest: attest).token()

        XCTAssertEqual(token, "A2")
        XCTAssertEqual(defaults.string(forKey: AppAttestSessionProvider.keyIdDefaultsKey), "KEY-1")
    }
}

// MARK: - Fakes

private final class FakeAttest: AppAttesting, @unchecked Sendable {
    let isSupported: Bool
    private(set) var attestedHashes: [Data] = []
    private(set) var assertedKeys: [String] = []
    private var generated = 0

    init(supported: Bool) { isSupported = supported }

    func generateKey() async throws -> String {
        generated += 1
        return "KEY-\(generated)"
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        attestedHashes.append(clientDataHash)
        return Data("attestation".utf8)
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        assertedKeys.append(keyId)
        return Data("assertion".utf8)
    }
}
