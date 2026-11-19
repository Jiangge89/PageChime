import SwiftUI

/// Language, volume and the developer log, out of the way of reading.
struct SettingsView: View {
    @ObservedObject var viewModel: ReadingSessionViewModel
    @AppStorage("dimWhileReading") private var dimWhileReading = true
    @Environment(\.dismiss) private var dismiss

    private var copy: Copy { Copy(chinese: viewModel.language == .chinese) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(copy("Reading language", "朗读语言"), selection: Binding(
                        get: { viewModel.language },
                        set: { viewModel.changeLanguage($0) }
                    )) {
                        ForEach(ReadingLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                } footer: {
                    Text(copy("Pick the language the book is written in.", "选择这本书所用的语言。"))
                }
                .listRowBackground(Theme.surface)

                Section(copy("While reading", "朗读时")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(copy("Sound effect volume", "音效音量"))
                        HStack(spacing: 12) {
                            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                            Slider(value: Binding(
                                get: { viewModel.volume },
                                set: { viewModel.updateVolume($0) }
                            ), in: 0...1)
                            .tint(Theme.gold)
                            .accessibilityLabel(copy("Volume", "音量"))
                            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    Toggle(copy("Dim the screen", "调暗屏幕"), isOn: $dimWhileReading)
                        .tint(Theme.gold)
                }
                .listRowBackground(Theme.surface)

                Section(copy("Privacy", "隐私")) {
                    Label(copy(
                        "Your voice and transcript are processed for this session only and are not saved. Page photos are read on this phone and never uploaded.",
                        "语音和文本仅在本次阅读中处理，不会被保存。书页照片在手机上识别，不会上传。"
                    ), systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .listRowBackground(Theme.surface)

                Section {
                    NavigationLink {
                        DebugLogView(viewModel: viewModel)
                    } label: {
                        HStack {
                            Label(copy("Debug log", "调试日志"), systemImage: "ant")
                            Spacer()
                            if !viewModel.analysisLogs.isEmpty {
                                Text("\(viewModel.analysisLogs.count)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.night)
            .navigationTitle(copy("Settings", "设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(copy("Done", "完成")) { dismiss() }
                }
            }
        }
    }
}

/// How each stretch of reading was matched to sounds, and how long it took.
struct DebugLogView: View {
    @ObservedObject var viewModel: ReadingSessionViewModel

    var body: some View {
        List {
            if viewModel.analysisLogs.isEmpty {
                Text("No analysis yet").foregroundStyle(.secondary)
            } else {
                Section { stats }
                Section {
                    ForEach(viewModel.analysisLogs) { log in
                        row(log)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.night)
        .navigationTitle("Debug Log")
        .toolbar {
            if !viewModel.analysisLogs.isEmpty {
                Button("Clear", role: .destructive) { viewModel.clearLogs() }
            }
        }
    }

    private var stats: some View {
        let logs = viewModel.analysisLogs
        let average = logs.map(\.totalMs).reduce(0, +) / max(logs.count, 1)
        let cacheRate = Int(Double(logs.filter { $0.method == .cache }.count) / Double(max(logs.count, 1)) * 100)
        return HStack {
            badge("Avg", "\(average)ms", .secondary)
            badge("Cache", "\(cacheRate)%", .green)
            badge("LLM", "\(logs.filter { $0.method == .llm }.count)", .orange)
            badge("Page", "\(logs.filter { $0.method == .page }.count)", .purple)
            badge("KW", "\(logs.filter { $0.method == .keyword }.count)", .blue)
        }
    }

    private func badge(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(color)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ log: AnalysisLog) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(log.method.rawValue)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(color(log.method))
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("wait \(log.waitMs)ms + analysis \(log.analysisMs)ms = \(log.totalMs)ms")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(log.totalMs > 1000 ? .red : log.totalMs > 200 ? .orange : .secondary)
                if !log.soundIDs.isEmpty {
                    Text(log.soundIDs.joined(separator: ", "))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.gold)
                }
                if let note = log.note {
                    Text(note)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(log.method == .error ? .red : .orange)
                        .lineLimit(2)
                }
                Text(log.inputText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func color(_ method: AnalysisLog.Method) -> Color {
        switch method {
        case .cache: return .green
        case .llm: return .orange
        case .keyword: return .blue
        case .page: return .purple
        case .noMatch: return .gray
        case .error: return .red
        }
    }
}
