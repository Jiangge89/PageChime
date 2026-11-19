import AVFoundation
import Foundation
@testable import PageChime

extension StubServer {
    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubServer.self]
        return URLSession(configuration: config)
    }
}

/// Session provider that always returns the same token.
final class StaticSessions: SessionProviding {
    func token() async throws -> String { "TEST" }
    func invalidate(_ token: String) async {}
}

/// Writes a short sine tone, for tests that need a real audio file.
func writeTestTone(
    to url: URL, seconds: Double, sampleRate: Double = 44100, channels: AVAudioChannelCount = 2,
    aac: Bool = true
) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    let settings: [String: Any] = aac
        ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]
        : format.settings
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<Int(channels) {
        let data = buffer.floatChannelData![channel]
        for i in 0..<Int(frames) {
            data[i] = 0.2 * sin(2 * .pi * 440 * Float(i) / Float(sampleRate))
        }
    }
    try file.write(from: buffer)
}

/// In-process fake of the PageChime API.
final class StubServer: URLProtocol {
    struct Recorded {
        let path: String
        let authorization: String?
        let headers: [String: String]
        let body: [String: Any]
    }

    typealias Route = (Recorded) -> (Int, [String: Any])
    /// Raw responses (e.g. audio files), checked before JSON routes.
    typealias DataRoute = (Recorded) -> (status: Int, body: Data, headers: [String: String])

    private static let lock = NSLock()
    private static var _routes: [String: Route] = [:]
    private static var _requests: [Recorded] = []
    private static var _dataRoutes: [String: DataRoute] = [:]

    static var dataRoutes: [String: DataRoute] {
        get { lock.withLock { _dataRoutes } }
        set { lock.withLock { _dataRoutes = newValue } }
    }

    static var routes: [String: Route] {
        get { lock.withLock { _routes } }
        set { lock.withLock { _routes = newValue } }
    }

    static var requests: [Recorded] { lock.withLock { _requests } }

    static func reset() {
        lock.withLock {
            _routes = [:]
            _dataRoutes = [:]
            _requests = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = Recorded(
            path: request.url?.path ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            headers: request.allHTTPHeaderFields ?? [:],
            body: (try? JSONSerialization.jsonObject(with: Self.bodyData(of: request))) as? [String: Any] ?? [:]
        )
        let (route, dataRoute) = Self.lock.withLock {
            Self._requests.append(recorded)
            return (Self._routes[recorded.path], Self._dataRoutes[recorded.path])
        }
        let status: Int
        let body: Data
        var headers: [String: String] = [:]
        if let dataRoute {
            (status, body, headers) = dataRoute(recorded)
        } else {
            let (code, json) = route?(recorded) ?? (404, ["error": "not found"])
            status = code
            body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        }

        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession moves `httpBody` into a stream before it reaches a URLProtocol.
    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
