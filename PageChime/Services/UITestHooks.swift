import UIKit

/// Stand-ins for the microphone and camera so UI tests can drive the whole
/// app: a scripted reader instead of speech recognition, and rendered page
/// photos instead of the document camera. Only Debug builds launched with
/// `-ui-testing` use them.
enum UITestHooks {
    static var isActive: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-ui-testing")
        #else
        false
        #endif
    }

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// What the scripted reader says. "||" marks where it stops and waits
    /// for the next start (the end of a page).
    static var speechScript: String? { isActive ? environment["UITEST_SPEECH"] : nil }

    /// Text of the pages "scanned", in order, separated by "||".
    static var pageTexts: [String] {
        guard isActive, let pages = environment["UITEST_PAGES"] else { return [] }
        return pages.components(separatedBy: "||").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static var nextPageIndex = 0

    /// The next page photo, or the current one again for a rescan; nil when
    /// pages aren't scripted.
    static func nextPagePhoto(replacing: Bool) -> UIImage? {
        let pages = pageTexts
        guard !pages.isEmpty else { return nil }
        let index = replacing ? max(nextPageIndex - 1, 0) : nextPageIndex
        if !replacing { nextPageIndex += 1 }
        return renderPage(pages[min(index, pages.count - 1)])
    }

    /// Clears saved settings (onboarding, language) for a first-launch test.
    static func resetStateIfRequested() {
        guard isActive, ProcessInfo.processInfo.arguments.contains("-ui-reset-state"),
              let id = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: id)
    }

    /// A plain book page with the text set in a large serif, for Vision to read.
    static func renderPage(_ text: String) -> UIImage {
        let size = CGSize(width: 1240, height: 1754)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 18
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont(name: "Georgia", size: 48) ?? UIFont.systemFont(ofSize: 48),
                .foregroundColor: UIColor.black,
                .paragraphStyle: style,
            ]
            (text as NSString).draw(in: CGRect(x: 100, y: 120, width: size.width - 200, height: size.height - 240), withAttributes: attributes)
        }
    }
}

/// Reads a script aloud as if it were speech recognition: the transcript
/// grows a word (Chinese: two characters) at a time.
final class ScriptedSpeechRecognizer: SpeechRecognizing {
    private(set) var transcript = ""
    private(set) var state: ListeningState = .ready
    var onTranscriptUpdate: ((String) -> Void)?
    var onStateChange: ((ListeningState) -> Void)?
    var contextualStrings: [String] = []

    private struct Section {
        let tokens: [String]
        let separator: String
    }

    private let sections: [Section]
    private let interval: TimeInterval
    private var section = 0
    private var position = 0
    private var generation = 0

    /// True once every section has been read.
    var isFinished: Bool { section >= sections.count }

    init(script: String, wordsPerSecond: Double = 5) {
        sections = script.components(separatedBy: "||").map { part in
            let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.contains(" ") {
                return Section(tokens: text.split(whereSeparator: \.isWhitespace).map(String.init), separator: " ")
            }
            let characters = Array(text)
            let tokens = stride(from: 0, to: characters.count, by: 2).map {
                String(characters[$0..<min($0 + 2, characters.count)])
            }
            return Section(tokens: tokens, separator: "")
        }
        interval = 1 / max(wordsPerSecond, 0.5)
    }

    func requestPermissions() async -> Bool { true }

    func start(language _: ReadingLanguage) async throws {
        generation += 1
        transcript = ""
        state = .listening
        onStateChange?(.listening)
        scheduleNextWord(generation)
    }

    func stop() {
        generation += 1
        transcript = ""
        state = .ready
    }

    private func scheduleNextWord(_ expected: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self, self.generation == expected, self.section < self.sections.count else { return }
            let current = self.sections[self.section]
            guard self.position < current.tokens.count else {
                // End of this page: wait for the next start.
                self.section += 1
                self.position = 0
                return
            }
            let word = current.tokens[self.position]
            self.position += 1
            self.transcript += (self.transcript.isEmpty ? "" : current.separator) + word
            self.onTranscriptUpdate?(self.transcript)
            self.scheduleNextWord(expected)
        }
    }
}

extension ReadingSessionViewModel {
    /// The app's view model; under UI tests its microphone is a scripted reader.
    @MainActor
    static func forLaunch() -> ReadingSessionViewModel {
        if let script = UITestHooks.speechScript {
            return ReadingSessionViewModel(speechService: ScriptedSpeechRecognizer(script: script))
        }
        return ReadingSessionViewModel()
    }
}
