import CryptoKit
import DeviceCheck
import Foundation

enum BackendError: Error, CustomStringConvertible {
    case notConfigured
    case attestationUnsupported
    case http(Int)
    case invalidResponse

    var description: String {
        switch self {
        case .notConfigured: return "backend not configured"
        case .attestationUnsupported: return "App Attest not supported on this device"
        case .http(let code): return "backend returned \(code)"
        case .invalidResponse: return "invalid backend response"
        }
    }
}

/// Minimal JSON-over-HTTP client for the PageChime API.
struct BackendHTTP {
    let baseURL: URL
    let session: URLSession

    func post(_ path: String, body: [String: Any] = [:], bearer: String? = nil) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BackendError.invalidResponse }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (http.statusCode, json)
    }
}

/// Supplies session tokens for `/v1/analyze`.
protocol SessionProviding: AnyObject {
    func token() async throws -> String
    /// Drops a token the server rejected, so the next call fetches a new one.
    func invalidate(_ token: String) async
}

/// The parts of `DCAppAttestService` we use, so tests can fake them.
protocol AppAttesting {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

extension DCAppAttestService: AppAttesting {}

/// Proves to the backend that requests come from a genuine copy of the app.
///
/// The first time, a new App Attest key is attested (`/v1/attest`); later the
/// stored key signs an assertion (`/v1/assert`). Either returns a session token
/// valid for an hour, which is reused for analysis requests.
///
/// The simulator can't use App Attest; Debug builds fall back to
/// `/v1/dev-session`, which only a local development server accepts.
actor AppAttestSessionProvider: SessionProviding {
    private let http: BackendHTTP
    private let attest: AppAttesting
    private let defaults: UserDefaults
    private let allowDevSessions: Bool
    private var current: (token: String, expiresAt: Date)?
    private var pending: Task<String, Error>?

    static let keyIdDefaultsKey = "appAttestKeyId"
    /// Refresh this long before the token expires.
    private let refreshMargin: TimeInterval = 60

    init(
        http: BackendHTTP,
        attest: AppAttesting = DCAppAttestService.shared,
        defaults: UserDefaults = .standard,
        allowDevSessions: Bool = AppAttestSessionProvider.isDebugBuild
    ) {
        self.http = http
        self.attest = attest
        self.defaults = defaults
        self.allowDevSessions = allowDevSessions
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    func token() async throws -> String {
        if let current, current.expiresAt.timeIntervalSinceNow > refreshMargin {
            return current.token
        }
        // Concurrent requests share one fetch.
        if let pending { return try await pending.value }
        let task = Task { try await fetchSession() }
        pending = task
        defer { pending = nil }
        return try await task.value
    }

    func invalidate(_ token: String) {
        if current?.token == token { current = nil }
    }

    // MARK: - Session flow

    private func fetchSession() async throws -> String {
        let response: [String: Any]
        if attest.isSupported {
            response = try await attestedSession()
        } else if allowDevSessions {
            response = try await expect(200, from: http.post("/v1/dev-session"))
        } else {
            throw BackendError.attestationUnsupported
        }

        guard let token = response["token"] as? String,
              let expiresIn = response["expiresIn"] as? Double
        else { throw BackendError.invalidResponse }
        current = (token, Date().addingTimeInterval(expiresIn))
        return token
    }

    private func attestedSession() async throws -> [String: Any] {
        if let keyId = defaults.string(forKey: Self.keyIdDefaultsKey) {
            do {
                return try await assertionSession(keyId: keyId)
            } catch let error as DCError where error.code == .invalidKey {
                // The key is gone (e.g. app reinstalled from a backup); start over.
                defaults.removeObject(forKey: Self.keyIdDefaultsKey)
            } catch BackendError.http(404) {
                // The server doesn't know this key; start over.
                defaults.removeObject(forKey: Self.keyIdDefaultsKey)
            }
        }
        return try await attestationSession()
    }

    private func attestationSession() async throws -> [String: Any] {
        let keyId = try await attest.generateKey()
        let challenge = try await fetchChallenge()
        let attestation = try await attest.attestKey(keyId, clientDataHash: Self.hash(challenge))
        let response = try await expect(200, from: http.post("/v1/attest", body: [
            "keyId": keyId,
            "attestation": attestation.base64EncodedString(),
            "challenge": challenge,
        ]))
        defaults.set(keyId, forKey: Self.keyIdDefaultsKey)
        return response
    }

    private func assertionSession(keyId: String) async throws -> [String: Any] {
        let challenge = try await fetchChallenge()
        let assertion = try await attest.generateAssertion(keyId, clientDataHash: Self.hash(challenge))
        return try await expect(200, from: http.post("/v1/assert", body: [
            "keyId": keyId,
            "assertion": assertion.base64EncodedString(),
            "challenge": challenge,
        ]))
    }

    private func fetchChallenge() async throws -> String {
        let response = try await expect(200, from: http.post("/v1/challenge"))
        guard let challenge = response["challenge"] as? String else { throw BackendError.invalidResponse }
        return challenge
    }

    private func expect(_ status: Int, from result: (Int, [String: Any])) throws -> [String: Any] {
        guard result.0 == status else { throw BackendError.http(result.0) }
        return result.1
    }

    static func hash(_ challenge: String) -> Data {
        Data(SHA256.hash(data: Data(challenge.utf8)))
    }
}
