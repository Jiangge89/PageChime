import Foundation

protocol SpeechRecognizing: AnyObject {
    var transcript: String { get }
    var state: ListeningState { get }
    var onTranscriptUpdate: ((String) -> Void)? { get set }
    var onStateChange: ((ListeningState) -> Void)? { get set }
    func requestPermissions() async -> Bool
    func start(language: ReadingLanguage) async throws
    func stop()
}
