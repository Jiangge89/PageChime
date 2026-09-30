import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ReadingSessionViewModel()
    @State private var isPulsing = false
    @State private var showDebugLog = false
    @AppStorage("hasSeenPrivacy") private var hasSeenPrivacy = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                headerSection
                languageSelector
                mainButton
                statusIndicator
                transcriptSection
                recentEffectsSection
                volumeControl
                if !hasSeenPrivacy {
                    privacyNotice
                }
                debugLogSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
        }
        .background(
            LinearGradient(
                colors: [Theme.background, Theme.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .onChange(of: viewModel.state) { _, newState in
            if newState == .listening {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            } else {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isPulsing = false
                }
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            Text("PageChime")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(Color.primary)
                .accessibilityAddTraits(.isHeader)

            Text(viewModel.language == .chinese
                ? "大声朗读故事，聆听它活起来"
                : "Read any story aloud and hear it come alive.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Language Selector

    private var languageSelector: some View {
        Picker("Language", selection: Binding(
            get: { viewModel.language },
            set: { viewModel.changeLanguage($0) }
        )) {
            ForEach(ReadingLanguage.allCases) { lang in
                Text(lang.displayName).tag(lang)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Select language")
    }

    // MARK: - Main Button

    private var isActive: Bool {
        viewModel.state == .starting || viewModel.state == .listening
    }

    private var mainButton: some View {
        Button {
            viewModel.toggleListening()
        } label: {
            HStack(spacing: 10) {
                if viewModel.state == .starting {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: isActive ? "stop.fill" : "book.fill")
                        .font(.title2)
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(isActive ? stopButtonLabel : startButtonLabel)
                    .font(.title3.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(isActive ? Color.red.opacity(0.85) : Theme.accent)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: (isActive ? Color.red : Theme.accent).opacity(0.25), radius: 8, y: 4)
        }
        .animation(.easeInOut(duration: 0.25), value: isActive)
        .accessibilityLabel(isActive ? "Stop reading" : "Start reading")
    }

    private var startButtonLabel: String {
        viewModel.language == .chinese ? "开始阅读" : "Start Reading"
    }

    private var stopButtonLabel: String {
        viewModel.language == .chinese ? "停止阅读" : "Stop Reading"
    }

    // MARK: - Status

    private var statusIndicator: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .scaleEffect(isPulsing ? 1.5 : 1.0)
                .opacity(isPulsing ? 0.55 : 1.0)
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(statusText)")
    }

    private var statusText: String {
        if viewModel.language == .chinese {
            switch viewModel.state {
            case .ready: return "准备就绪"
            case .starting: return "正在启动..."
            case .listening: return "正在聆听"
            case .paused: return "已暂停"
            case .permissionRequired: return "需要授权"
            case .error(let msg): return "错误: \(msg)"
            }
        }
        return viewModel.state.displayText
    }

    private var statusColor: Color {
        switch viewModel.state {
        case .ready: return .gray
        case .starting: return .orange
        case .listening: return .green
        case .paused: return .orange
        case .permissionRequired: return .yellow
        case .error: return .red
        }
    }

    // MARK: - Transcript

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(viewModel.language == .chinese ? "实时文本" : "Live Transcript")
                    .font(.caption.weight(.medium))
            } icon: {
                Image(systemName: "text.quote")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)

            HStack(alignment: .bottom, spacing: 2) {
                Text(viewModel.transcript.isEmpty
                    ? (viewModel.language == .chinese ? "等待朗读..." : "Waiting for speech...")
                    : viewModel.transcript)
                    .font(.body)
                    .foregroundStyle(viewModel.transcript.isEmpty ? .tertiary : .primary)

                if viewModel.state == .listening {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Theme.accent)
                        .frame(width: 2, height: 16)
                        .phaseAnimator([false, true]) { content, phase in
                            content.opacity(phase ? 1 : 0)
                        } animation: { _ in
                            .easeInOut(duration: 0.6)
                        }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
            .padding(12)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("Transcript: \(viewModel.transcript.isEmpty ? "No text yet" : viewModel.transcript)")
        }
    }

    // MARK: - Recent Effects

    private var recentEffectsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(viewModel.language == .chinese ? "最近音效" : "Recent Effects")
                    .font(.caption.weight(.medium))
            } icon: {
                Image(systemName: "sparkles")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)

            if viewModel.recentEffects.isEmpty {
                emptyEffectsView
            } else {
                VStack(spacing: 6) {
                    ForEach(viewModel.recentEffects) { event in
                        effectRow(event)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.85).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                }
                .animation(.spring(duration: 0.4, bounce: 0.2), value: viewModel.recentEffects.map(\.id))
            }
        }
    }

    private var emptyEffectsView: some View {
        VStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.title2)
                .foregroundStyle(Theme.accent.opacity(0.5))
            Text(viewModel.language == .chinese
                ? "音效会在朗读故事时自动出现"
                : "Sound effects appear as you read")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func effectRow(_ event: StoryEvent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(for: event.type))
                .font(.body)
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.entity.capitalized)
                    .font(.callout.weight(.medium))
                Text(event.soundID.replacingOccurrences(of: "_", with: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .modifier(FlashModifier())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.entity) sound effect")
    }

    private func iconName(for type: StoryEventType) -> String {
        switch type {
        case .animal: return "pawprint.fill"
        case .weather: return "cloud.fill"
        case .vehicle: return "car.fill"
        case .action: return "figure.walk"
        case .environment: return "leaf.fill"
        case .object: return "cube.fill"
        }
    }

    // MARK: - Volume

    private var volumeControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(viewModel.language == .chinese ? "音效音量" : "Sound Effect Volume")
                    .font(.caption.weight(.medium))
            } icon: {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { viewModel.volume },
                    set: { viewModel.updateVolume($0) }
                ), in: 0...1)
                .tint(Theme.accent)
                .accessibilityLabel("Volume")
                .accessibilityValue("\(Int(viewModel.volume * 100))%")
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Privacy Notice

    private var privacyNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.caption)
                .foregroundStyle(Theme.accent)
            Text(viewModel.language == .chinese
                ? "语音和文本仅在本次阅读中处理，不会被保存。"
                : "Your voice and transcript are processed for this session only and are not saved.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                withAnimation { hasSeenPrivacy = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(Theme.card.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Debug Log

    private var debugLogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { showDebugLog.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "ant.fill")
                        .font(.caption)
                    Text("Debug Log")
                        .font(.caption.weight(.medium))
                    Spacer()
                    if !viewModel.analysisLogs.isEmpty {
                        Text("\(viewModel.analysisLogs.count)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.2))
                            .clipShape(Capsule())
                    }
                    Image(systemName: showDebugLog ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }

            if showDebugLog {
                if viewModel.analysisLogs.isEmpty {
                    Text("No analysis yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .background(Theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    debugStats
                    VStack(spacing: 4) {
                        ForEach(viewModel.analysisLogs) { log in
                            debugLogRow(log)
                        }
                    }
                    Button("Clear", role: .destructive) {
                        viewModel.clearLogs()
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private var debugStats: some View {
        let logs = viewModel.analysisLogs
        let avgTotal = logs.isEmpty ? 0 : logs.map(\.totalMs).reduce(0, +) / logs.count
        let cacheCount = logs.filter { $0.method == .cache }.count
        let llmCount = logs.filter { $0.method == .llm }.count
        let keywordCount = logs.filter { $0.method == .keyword }.count
        let cacheRate = logs.isEmpty ? 0 : Int(Double(cacheCount) / Double(logs.count) * 100)

        return HStack(spacing: 12) {
            statBadge("Avg", "\(avgTotal)ms", .secondary)
            statBadge("Cache", "\(cacheRate)%", .green)
            statBadge("LLM", "\(llmCount)", .orange)
            statBadge("KW", "\(keywordCount)", .blue)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func statBadge(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func debugLogRow(_ log: AnalysisLog) -> some View {
        HStack(spacing: 8) {
            Text(log.method.rawValue)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(methodColor(log.method))
                .frame(width: 52, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("wait \(log.waitMs)ms")
                        .foregroundStyle(.secondary)
                    Text("+")
                        .foregroundStyle(.quaternary)
                    Text("analysis \(log.analysisMs)ms")
                        .foregroundStyle(.secondary)
                    Text("= \(log.totalMs)ms")
                        .foregroundStyle(log.totalMs > 1000 ? .red : log.totalMs > 200 ? .orange : .green)
                }
                .font(.system(size: 9, design: .monospaced))

                if !log.soundIDs.isEmpty {
                    Text(log.soundIDs.joined(separator: ", "))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }

                Text(log.inputText.prefix(40) + (log.inputText.count > 40 ? "..." : ""))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func methodColor(_ method: AnalysisLog.Method) -> Color {
        switch method {
        case .cache: return .green
        case .llm: return .orange
        case .keyword: return .blue
        case .noMatch: return .gray
        }
    }
}

// MARK: - Flash Highlight

private struct FlashModifier: ViewModifier {
    @State private var flash = true

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.accent.opacity(flash ? 0.12 : 0))
                    .allowsHitTesting(false)
            )
            .onAppear {
                withAnimation(.easeOut(duration: 0.8)) {
                    flash = false
                }
            }
    }
}

// MARK: - Theme Colors

enum Theme {
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
            : UIColor(red: 0.98, green: 0.96, blue: 0.92, alpha: 1)
    })

    static let backgroundBottom = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)
            : UIColor(red: 0.95, green: 0.93, blue: 0.88, alpha: 1)
    })

    static let card = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1)
            : UIColor.white
    })

    static let accent = Color(uiColor: UIColor(red: 0.35, green: 0.65, blue: 0.55, alpha: 1))
}

#Preview {
    ContentView()
}
