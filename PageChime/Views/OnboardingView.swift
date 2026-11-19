import SwiftUI

/// First launch: what PageChime does, a one-sentence demo that asks for the
/// microphone in context, and a few tips. Every step can be skipped.
struct OnboardingView: View {
    @ObservedObject var viewModel: ReadingSessionViewModel
    /// Shown again from Settings, so the microphone may already be allowed.
    let isReplay: Bool
    let onFinish: () -> Void

    enum Step: Int { case welcome, tryIt, tips }

    @State private var step: Step = .welcome
    @State private var listening = false
    /// "Heard nothing?" help, shown if the demo stays silent for a while.
    @State private var showSilenceHelp = false

    private var copy: Copy { Copy(chinese: viewModel.language == .chinese) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 24)
                .padding(.top, 12)

            Group {
                switch step {
                case .welcome: welcome
                case .tryIt: tryIt
                case .tips: tips
                }
            }
            .transition(.opacity)
            .frame(maxHeight: .infinity, alignment: .top)

            footer
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
        }
        .background(alignment: .top) {
            LinearGradient(colors: [Color(hex: 0x1B2654), Theme.night], startPoint: .top, endPoint: .center)
                .opacity(step == .welcome ? 1 : 0)
                .ignoresSafeArea()
        }
        .background(Theme.night)
        .animation(.easeInOut(duration: 0.3), value: step)
        .animation(.easeInOut(duration: 0.3), value: listening)
        .preferredColorScheme(.dark)
        .onDisappear(perform: stopDemo)
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            if step == .welcome {
                languageMenu
            } else {
                CircleIconButton(systemName: "chevron.left", label: copy("Back", "返回")) {
                    go(to: Step(rawValue: step.rawValue - 1) ?? .welcome)
                }
            }
            Spacer()
            if step != .tips {
                Button(copy("Skip", "跳过"), action: finish)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .frame(height: 44)
                    .padding(.horizontal, 8)
            }
        }
        .frame(height: 44)
    }

    private var languageMenu: some View {
        Menu {
            Picker(copy("Reading language", "朗读语言"), selection: Binding(
                get: { viewModel.language },
                set: { viewModel.changeLanguage($0) }
            )) {
                ForEach(ReadingLanguage.allCases) { Text($0.displayName).tag($0) }
            }
        } label: {
            Text(viewModel.language == .chinese ? "中文" : "EN")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(.white.opacity(0.1), in: Capsule())
        }
        .accessibilityLabel(copy("Reading language: English", "朗读语言：中文"))
    }

    private var footer: some View {
        VStack(spacing: 18) {
            if step == .tryIt, listening, showSilenceHelp, heardCount == 0 {
                Text(copy(
                    "Heard nothing? Check that silent mode is off and the volume is up, then read it again.",
                    "没听到声音？请确认静音开关已关闭、音量已调高，再读一遍。"
                ))
                .font(.system(size: 13))
                .foregroundStyle(Theme.faint)
                .multilineTextAlignment(.center)
            }
            if step == .tips {
                Text(copy("You can find these again in Settings", "设置里可以再次查看这些内容"))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faint)
            }

            HStack(spacing: 8) {
                ForEach(0..<3) { index in
                    Capsule()
                        .fill(index == step.rawValue ? Theme.gold : Color(hex: 0x3A4475))
                        .frame(width: index == step.rawValue ? 22 : 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(copy("Step \(step.rawValue + 1) of 3", "第 \(step.rawValue + 1) 步，共 3 步"))

            primaryButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .welcome:
            Button(copy("Get started", "开始")) { go(to: .tryIt) }
                .buttonStyle(GoldButtonStyle(height: 62))
        case .tryIt:
            if listening {
                Button(copy("Continue", "继续")) { go(to: .tips) }
                    .buttonStyle(GoldButtonStyle(height: 62))
            } else {
                Button(action: startDemo) {
                    Label(isReplay ? copy("Start listening", "开始聆听") : copy("Turn on the microphone", "打开麦克风"), systemImage: "mic")
                }
                .buttonStyle(GoldButtonStyle(height: 62))
            }
        case .tips:
            Button(copy("Start my first story", "开始第一个故事"), action: finish)
                .buttonStyle(GoldButtonStyle(height: 62))
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Image("WelcomeStage")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 290)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .accessibilityLabel(copy("An open book on a small stage, lit by a warm spotlight", "舞台灯光下的一本打开的书"))

                Text(copy("Read any book aloud. Hear it come alive.", "大声读任何一本书，听它活起来。"))
                    .font(Theme.serif(36))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                Text(copy(
                    "PageChime listens as you read and plays the sounds of the story the moment you reach them. Your own books, in English or Chinese.",
                    "PageChime 一边听你朗读，一边在你读到的那一刻播放故事里的声音。用你自己的书，中文英文都可以。"
                ))
                .font(.system(size: 16))
                .lineSpacing(3)
                .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var tryIt: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if listening {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Circle().fill(Theme.success).frame(width: 7, height: 7)
                            Text(statusText)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.success)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.success.opacity(0.14), in: Capsule())

                        Text(heardCount >= 2 ? copy("That's PageChime.", "这就是 PageChime。") : copy("Read this line out loud.", "把这句话大声读出来。"))
                            .font(Theme.serif(32))
                            .foregroundStyle(Theme.text)
                        if heardCount >= 2 {
                            Text(copy("Every book works like this: sounds play as you read the words.", "每本书都是这样：读到哪里，声音就在哪里响起。"))
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(copy("Try it now", "现在试试"))
                            .font(.system(size: 13, weight: .semibold))
                            .tracking(1)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.gold)
                        Text(copy("Read this line out loud.", "把这句话大声读出来。"))
                            .font(Theme.serif(32))
                            .foregroundStyle(Theme.text)
                    }
                }

                Text(sentence)
                    .font(Theme.serif(22, weight: .regular))
                    .lineSpacing(6)
                    .foregroundStyle(Theme.ink)
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.paper, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 15, y: 12)

                if listening {
                    VStack(spacing: 10) {
                        ForEach(demo.parts, id: \.soundID) { part in
                            soundRow(part)
                        }
                    }
                } else {
                    Label(copy("Turn your volume up so you can hear it", "把音量调大，才能听到声音"), systemImage: "speaker.wave.2")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)

                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "mic")
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.gold)
                            .frame(width: 40, height: 40)
                            .background(Theme.numberFill, in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(copy("PageChime needs to hear you read", "PageChime 需要听到你的朗读"))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            Text(copy(
                                "That's how it knows where you are in the story. Your voice is never saved.",
                                "这样它才知道你读到了哪里。你的声音不会被保存。"
                            ))
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                if viewModel.state == .permissionRequired {
                    permissionHelp
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var tips: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text(copy("For the best results", "这样用效果最好"))
                    .font(Theme.serif(32))
                    .foregroundStyle(Theme.text)
                    .padding(.top, 24)
                tip("iphone.and.arrow.forward", copy("Keep the phone beside the book", "手机放在书旁边"),
                    copy("Within arm's reach is plenty. A normal reading voice is all it needs.", "伸手能碰到的距离就够了，正常音量朗读即可。"))
                tip("doc.viewfinder", copy("Scan each page first", "每一页先扫描"),
                    copy("Sounds load before you start and play right on the word. Lay the page flat in good light.", "开始前先准备好音效，读到那个词就响。书页放平，光线充足。"))
                tip("globe", copy("Match the book's language", "选对书的语言"),
                    copy("English or 中文, switched at the top of the home screen.", "English 或中文，在首页顶部切换。"))
                tip("moon", copy("Read the way you always do", "照平常的方式读"),
                    copy("No need to slow down. The screen dims itself so it won't light up the room.", "不用放慢速度。屏幕会自动调暗，不会照亮房间。"))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - Pieces

    private func tip(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .foregroundStyle(Theme.gold)
                .frame(width: 44, height: 44)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func soundRow(_ part: DemoSentence.Part) -> some View {
        let played = heard.contains(part.soundID)
        return HStack(spacing: 12) {
            Image(systemName: part.symbol)
                .font(.system(size: 18))
                .foregroundStyle(Theme.gold)
                .frame(width: 24)
            HStack(spacing: 4) {
                Text(copy(part.name, part.nameChinese))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.text)
                if part.isBackground {
                    Text(copy("· background", "· 背景声"))
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: played ? "checkmark" : "circle.dotted")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(played ? Theme.success : Theme.faint)
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(played ? 1 : 0.6)
        .animation(.easeOut(duration: 0.3), value: played)
        .accessibilityElement(children: .combine)
        .accessibilityValue(played ? copy("Played", "已播放") : copy("Waiting", "等待中"))
    }

    private var permissionHelp: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(copy(
                "The microphone is off for PageChime. Turn on Microphone and Speech Recognition in Settings to use it.",
                "PageChime 的麦克风权限已关闭。请在系统设置中打开「麦克风」和「语音识别」。"
            ))
            .font(.system(size: 14))
            .foregroundStyle(Theme.text)
            Button(copy("Open Settings", "打开设置")) {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(OutlineButtonStyle())
        }
        .padding(18)
        .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Demo

    private var demo: DemoSentence { DemoSentence.for(viewModel.language) }

    /// Sounds from the demo sentence that have played.
    private var heard: Set<String> { Set(viewModel.story?.soundIDs ?? []).intersection(demo.parts.map(\.soundID)) }
    private var heardCount: Int { heard.count }

    private var statusText: String {
        switch viewModel.state {
        case .starting: return copy("Starting…", "正在启动…")
        case .listening: return copy("Listening", "正在聆听")
        default: return copy("Not listening", "未在聆听")
        }
    }

    /// The sentence with each phrase marked once its sound has played.
    private var sentence: AttributedString {
        var result = AttributedString()
        for piece in demo.pieces {
            var text = AttributedString(piece.text)
            if let id = piece.soundID, heard.contains(id) {
                text.backgroundColor = Theme.highlight
            }
            result += text
        }
        return result
    }

    private func startDemo() {
        viewModel.resetStory()
        viewModel.startReading()
        listening = true
        showSilenceHelp = false
        Task {
            try? await Task.sleep(for: .seconds(8))
            showSilenceHelp = true
        }
    }

    private func stopDemo() {
        if listening || viewModel.story != nil { viewModel.resetStory() }
        listening = false
    }

    private func go(to next: Step) {
        if step == .tryIt { stopDemo() }
        step = next
    }

    private func finish() {
        stopDemo()
        onFinish()
    }
}

/// The demo line: every sound in it is bundled and matched by keyword, so it
/// works instantly and offline.
struct DemoSentence {
    struct Part {
        let soundID: String
        let name: String
        let nameChinese: String
        let symbol: String
        var isBackground = false
    }

    struct Piece {
        let text: String
        var soundID: String?
    }

    let pieces: [Piece]
    let parts: [Part]

    private static let parts: [Part] = [
        Part(soundID: "dog_bark", name: "Dog bark", nameChinese: "狗叫", symbol: "pawprint"),
        Part(soundID: "thunder", name: "Thunder", nameChinese: "雷声", symbol: "cloud.bolt"),
        Part(soundID: "rain_light", name: "Rain", nameChinese: "雨声", symbol: "cloud.rain", isBackground: true),
    ]

    static func `for`(_ language: ReadingLanguage) -> DemoSentence {
        switch language {
        case .chinese:
            return DemoSentence(pieces: [
                Piece(text: "小狗汪汪叫", soundID: "dog_bark"), Piece(text: "，"),
                Piece(text: "天上打雷了", soundID: "thunder"), Piece(text: "，接着"),
                Piece(text: "下起了雨", soundID: "rain_light"), Piece(text: "。"),
            ], parts: parts)
        default:
            return DemoSentence(pieces: [
                Piece(text: "The dog barked", soundID: "dog_bark"), Piece(text: ", then "),
                Piece(text: "thunder rolled", soundID: "thunder"), Piece(text: " and "),
                Piece(text: "rain began to fall", soundID: "rain_light"), Piece(text: "."),
            ], parts: parts)
        }
    }
}
