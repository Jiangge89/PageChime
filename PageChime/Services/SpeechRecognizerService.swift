import AVFoundation
import Foundation
import Speech

final class SpeechRecognizerService: SpeechRecognizing {
    private(set) var transcript: String = ""
    private(set) var state: ListeningState = .ready

    var onTranscriptUpdate: ((String) -> Void)?
    var onStateChange: ((ListeningState) -> Void)?

    private var audioEngine = AVAudioEngine()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var speechRecognizer: SFSpeechRecognizer?
    private var accumulatedTranscript: String = ""
    private var isListening = false
    private var currentLanguage: ReadingLanguage = .english
    private var sessionGeneration: UInt = 0

    func requestPermissions() async -> Bool {
        let micGranted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard micGranted else {
            updateState(.permissionRequired)
            return false
        }

        let speechGranted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechGranted else {
            updateState(.permissionRequired)
            return false
        }

        return true
    }

    func start(language: ReadingLanguage) async throws {
        currentLanguage = language
        sessionGeneration &+= 1
        speechRecognizer = findAvailableRecognizer(for: language)

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            let supported = SFSpeechRecognizer.supportedLocales()
                .map(\.identifier)
                .filter { $0.hasPrefix(language.rawValue) }
                .joined(separator: ", ")
            let hint = supported.isEmpty
                ? "Try adding \(language.displayName) in Settings → General → Keyboard → Keyboards."
                : "Available: \(supported)"
            updateState(.error("Speech recognizer unavailable for \(language.displayName). \(hint)"))
            throw SpeechError.recognizerUnavailable
        }

        accumulatedTranscript = ""
        transcript = ""
        isListening = true

        try configureAudioSession()
        try startRecognitionTask()
        updateState(.listening)
    }

    private func findAvailableRecognizer(for language: ReadingLanguage) -> SFSpeechRecognizer? {
        for localeID in language.speechLocales {
            let locale = Locale(identifier: localeID)
            if let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable {
                return recognizer
            }
        }
        let supported = SFSpeechRecognizer.supportedLocales()
        for locale in supported where locale.language.languageCode?.identifier == language.rawValue {
            if let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable {
                return recognizer
            }
        }
        return nil
    }

    func stop() {
        isListening = false
        sessionGeneration &+= 1
        stopRecognitionTask()
        stopAudioEngine()
        transcript = ""
        accumulatedTranscript = ""
        updateState(.ready)
    }

    // MARK: - Private

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func startRecognitionTask() throws {
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else {
            throw SpeechError.requestCreationFailed
        }

        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = speechRecognizer?.supportsOnDeviceRecognition ?? false

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        let nativeFormat = inputNode.outputFormat(forBus: 0)

        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw SpeechError.noAudioInput
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        let gen = sessionGeneration
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self, self.sessionGeneration == gen else { return }

            if let result {
                let taskTranscript = result.bestTranscription.formattedString
                let fullTranscript: String
                if self.accumulatedTranscript.isEmpty {
                    fullTranscript = taskTranscript
                } else {
                    fullTranscript = self.accumulatedTranscript + " " + taskTranscript
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self, self.sessionGeneration == gen else { return }
                    self.transcript = fullTranscript
                    self.onTranscriptUpdate?(fullTranscript)
                }

                if result.isFinal {
                    self.accumulatedTranscript = fullTranscript
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.sessionGeneration == gen else { return }
                        self.restartIfNeeded()
                    }
                }
            }

            if error != nil {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.sessionGeneration == gen else { return }
                    self.restartIfNeeded()
                }
            }
        }
    }

    private func restartIfNeeded() {
        guard isListening else { return }
        stopRecognitionTask()
        stopAudioEngine()
        audioEngine = AVAudioEngine()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isListening else { return }
            do {
                try self.configureAudioSession()
                try self.startRecognitionTask()
            } catch {
                self.updateState(.error("Failed to restart recognition"))
            }
        }
    }

    private func stopRecognitionTask() {
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func stopAudioEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
    }

    private func updateState(_ newState: ListeningState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.state = newState
            self.onStateChange?(newState)
        }
    }
}

enum SpeechError: LocalizedError {
    case recognizerUnavailable
    case requestCreationFailed
    case permissionDenied
    case noAudioInput

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable: return "Speech recognizer is not available."
        case .requestCreationFailed: return "Could not create recognition request."
        case .permissionDenied: return "Microphone or speech recognition permission denied."
        case .noAudioInput: return "No audio input available. If you are using the Simulator, please test on a physical device."
        }
    }
}
