import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ReadingSessionViewModel()

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
                privacyNotice
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
        }
        .background(Theme.background)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            Text("PageChime")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(Color.primary)
                .accessibilityAddTraits(.isHeader)

            Text("Read any story aloud and hear it come alive.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Language Selector

    private var languageSelector: some View {
        HStack(spacing: 12) {
            ForEach(ReadingLanguage.allCases) { lang in
                Button {
                    viewModel.changeLanguage(lang)
                } label: {
                    Text(lang.displayName)
                        .font(.body.weight(.medium))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            viewModel.language == lang
                                ? Theme.accent
                                : Theme.card
                        )
                        .foregroundStyle(
                            viewModel.language == lang
                                ? .white
                                : Color.primary
                        )
                        .clipShape(Capsule())
                }
                .accessibilityLabel("Language: \(lang.displayName)")
                .accessibilityAddTraits(viewModel.language == lang ? .isSelected : [])
            }
        }
    }

    // MARK: - Main Button

    private var mainButton: some View {
        Button {
            viewModel.toggleListening()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: viewModel.isListening ? "stop.fill" : "book.fill")
                    .font(.title2)
                Text(viewModel.isListening ? stopButtonLabel : startButtonLabel)
                    .font(.title3.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(viewModel.isListening ? Color.red.opacity(0.85) : Theme.accent)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .accessibilityLabel(viewModel.isListening ? "Stop reading" : "Start reading")
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
            Text(viewModel.state.displayText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(viewModel.state.displayText)")
    }

    private var statusColor: Color {
        switch viewModel.state {
        case .ready: return .gray
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

            Text(viewModel.transcript.isEmpty ? "..." : viewModel.transcript)
                .font(.body)
                .foregroundStyle(viewModel.transcript.isEmpty ? .tertiary : .primary)
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
                Text(viewModel.language == .chinese ? "等待故事开始..." : "Waiting for the story to begin...")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 6) {
                    ForEach(viewModel.recentEffects) { event in
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
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(event.entity) sound effect")
                    }
                }
            }
        }
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
            Text("Your voice and transcript are processed for this reading session and are not saved by PageChime.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Theme.card.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Theme Colors

enum Theme {
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
            : UIColor(red: 0.98, green: 0.96, blue: 0.92, alpha: 1)
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
