import AVFoundation
import Foundation
import Speech

final class SpeechRecognizerService: SpeechRecognizing {
    private(set) var transcript: String = ""
    private(set) var state: ListeningState = .ready

    var onTranscriptUpdate: ((String) -> Void)?
    var onStateChange: ((ListeningState) -> Void)?
    var contextualStrings: [String] = []

    private var audioEngine = AVAudioEngine()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var speechRecognizer: SFSpeechRecognizer?
    private var accumulatedTranscript: String = ""
    private var isListening = false
    private var currentLanguage: ReadingLanguage = .english
    private var sessionGeneration: UInt = 0

    private var lastResultTime = Date()
    private var taskStartTime = Date()
    private var healthCheckTimer: Timer?
    private var consecutiveRestarts = 0
    private var isRestarting = false
    private var interruptionObserver: Any?

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
        consecutiveRestarts = 0
        isRestarting = false

        try configureAudioSession()
        try startRecognitionTask()
        updateState(.listening)
        startHealthCheck()
        observeInterruptions()
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
        isRestarting = false
        stopHealthCheck()
        removeInterruptionObserver()
        stopRecognitionTask()
        stopAudioEngine()
        transcript = ""
        accumulatedTranscript = ""
        updateState(.ready)
    }

    // MARK: - Health Check

    private func startHealthCheck() {
        stopHealthCheck()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.performHealthCheck()
            }
        }
    }

    private func stopHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }

    private func performHealthCheck() {
        guard isListening, !isRestarting else { return }

        let now = Date()

        if !audioEngine.isRunning {
            restartIfNeeded()
            return
        }

        // Periodic restart to avoid Apple's ~60s recognition timeout
        if now.timeIntervalSince(taskStartTime) > 50 {
            restartIfNeeded()
            return
        }

        // Restart if no results for 10 seconds (recognizer may have silently stopped)
        if now.timeIntervalSince(lastResultTime) > 10 {
            consecutiveRestarts += 1
            if consecutiveRestarts > 5 {
                updateState(.error("Speech recognition not responding. Please stop and restart."))
                return
            }
            restartIfNeeded()
        }
    }

    // MARK: - Interruption Handling

    private func observeInterruptions() {
        removeInterruptionObserver()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }
    }

    private func removeInterruptionObserver() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        if type == .ended {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.isListening else { return }
                self.restartIfNeeded()
            }
        }
    }

    // MARK: - Private

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func startRecognitionTask() throws {
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else {
            throw SpeechError.requestCreationFailed
        }

        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = false
        if !contextualStrings.isEmpty {
            recognitionRequest.contextualStrings = contextualStrings
        }

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        let nativeFormat = inputNode.outputFormat(forBus: 0)

        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw SpeechError.noAudioInput
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        taskStartTime = Date()
        lastResultTime = Date()

        let gen = sessionGeneration
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self, self.sessionGeneration == gen else { return }

            if let result {
                self.lastResultTime = Date()
                self.consecutiveRestarts = 0

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
        guard isListening, !isRestarting else { return }
        isRestarting = true
        stopRecognitionTask()
        stopAudioEngine()
        audioEngine = AVAudioEngine()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isListening else {
                self?.isRestarting = false
                return
            }
            do {
                try self.configureAudioSession()
                try self.startRecognitionTask()
                self.isRestarting = false
            } catch {
                self.isRestarting = false
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
