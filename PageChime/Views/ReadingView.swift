import SwiftUI

/// While reading: a dark, dimmed screen whose glow follows the scene, so the
/// phone can sit beside the book without lighting up the room.
struct ReadingView: View {
    let copy: Copy
    let state: ListeningState
    let isPaused: Bool
    let page: PageSummary?
    let firedCueCount: Int
    let sceneIDs: [String]
    let lastSound: StoryEvent?
    let canScan: Bool
    let onStop: () -> Void
    let onPauseToggle: () -> Void
    let onNextPage: () -> Void

    @AppStorage("dimWhileReading") private var dimWhileReading = true
    @Environment(\.scenePhase) private var scenePhase
    @State private var dimmer = ScreenDimmer()
    @State private var drift = false
    @State private var ripple: CGFloat = 1

    private var mood: SceneMood { SceneMood(sceneIDs: sceneIDs) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            center
            Spacer()
            progress
                .padding(.bottom, 36)
            controls
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // In the background the oversized glow can't widen the layout.
        .background {
            ZStack {
                Theme.deepNight
                glow
            }
            .ignoresSafeArea()
        }
        .onAppear {
            drift = true
            if dimWhileReading { dimmer.dim() }
        }
        .onDisappear { dimmer.restore() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, dimWhileReading { dimmer.dim() } else { dimmer.restore() }
        }
        .onChange(of: lastSound?.id) { _, id in
            guard id != nil else { return }
            ripple = 0.6
            withAnimation(.easeOut(duration: 1.6)) { ripple = 1 }
        }
    }

    // MARK: - Pieces

    private var glow: some View {
        ZStack {
            Circle()
                .fill(mood.primary)
                .frame(width: 560, height: 480)
                .blur(radius: 80)
                .opacity(0.55)
                .offset(x: drift ? -30 : 30, y: drift ? -60 : -20)
            Circle()
                .fill(mood.secondary)
                .frame(width: 320, height: 280)
                .blur(radius: 90)
                .opacity(0.4)
                .offset(x: drift ? 90 : 40, y: drift ? 170 : 230)
        }
        .animation(.easeInOut(duration: 9).repeatForever(autoreverses: true), value: drift)
        .animation(.easeInOut(duration: 2.5), value: sceneIDs)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var topBar: some View {
        HStack {
            Text(page.map { copy("Page \($0.number)", "第 \($0.number) 页") } ?? copy("Reading", "朗读中"))
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
            Spacer()
        }
        .frame(height: 44)
    }

    @ViewBuilder
    private var center: some View {
        switch state {
        case .permissionRequired:
            message(
                icon: "mic.slash",
                text: copy("PageChime needs the microphone and speech recognition to follow your reading.",
                           "PageChime 需要麦克风和语音识别权限，才能跟上你的朗读。"),
                action: (copy("Open Settings", "打开设置"), {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                })
            )
        case .error(let error):
            message(icon: "exclamationmark.triangle", text: error, action: nil)
        default:
            VStack(spacing: 18) {
                rings
                sceneLine
            }
        }
    }

    private var rings: some View {
        ZStack {
            Circle().stroke(Theme.text.opacity(0.10), lineWidth: 1)
            Circle().stroke(Theme.text.opacity(0.18), lineWidth: 1).padding(30)
            Circle().stroke(Theme.gold.opacity(0.55), lineWidth: 1.5).padding(60)
                .scaleEffect(ripple)
                .opacity(Double(ripple))
            VStack(spacing: 6) {
                Text(centerTitle)
                    .font(Theme.serif(28))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.4), value: centerTitle)
                Text(centerCaption)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 70)
        }
        .frame(width: 280, height: 280)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("readingCenter")
    }

    /// The background sounds playing now, under the latest sound. Space is
    /// kept when there are none, so the rings don't jump.
    private var sceneLine: some View {
        let names = sceneIDs.prefix(3).map(SoundName.scene).joined(separator: " · ")
        return HStack(spacing: 8) {
            Circle().fill(mood.dot).frame(width: 7, height: 7)
            Text(names)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text.opacity(0.85))
                .lineLimit(1)
        }
        .frame(height: 20)
        .opacity(names.isEmpty || isPaused ? 0 : 1)
        .animation(.easeInOut(duration: 0.6), value: names)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(copy("Background", "背景声") + ": " + names)
        .accessibilityHidden(names.isEmpty || isPaused)
        .accessibilityIdentifier("sceneLine")
    }

    private var centerTitle: String {
        if isPaused { return copy("Paused", "已暂停") }
        if state == .starting { return copy("Starting…", "正在启动…") }
        if let lastSound { return SoundName.display(lastSound.soundID) }
        return copy("Listening…", "正在聆听…")
    }

    private var centerCaption: String {
        if isPaused { return copy("Tap play to keep reading", "点播放继续朗读") }
        if lastSound != nil, state == .listening { return copy("Last sound", "刚刚的音效") }
        return copy("Start reading aloud", "开始大声朗读吧")
    }

    @ViewBuilder
    private var progress: some View {
        if let page, !page.cues.isEmpty {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(0..<min(page.cues.count, 10), id: \.self) { index in
                        Capsule()
                            .fill(index < firedCueCount ? Theme.gold : Theme.text.opacity(0.18))
                            .frame(width: 26, height: 5)
                    }
                }
                .animation(.easeOut(duration: 0.3), value: firedCueCount)
                Text(copy("\(firedCueCount) of \(page.cues.count) sounds on this page",
                          "这一页 \(page.cues.count) 个音效，已响 \(firedCueCount) 个"))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faint)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("pageProgress")
        }
    }

    private var controls: some View {
        HStack(alignment: .bottom) {
            labeledButton(copy("Stop", "结束"), width: 80) {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.text.opacity(0.9))
                        .frame(width: 52, height: 52)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .accessibilityLabel(copy("Stop reading", "结束朗读"))
            }
            Spacer()
            labeledButton(isPaused ? copy("Resume", "继续") : copy("Pause", "暂停"), width: 90) {
                Button(action: onPauseToggle) {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.night)
                        .frame(width: 80, height: 80)
                        .background(Theme.text, in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .disabled(state == .starting)
                .accessibilityLabel(isPaused ? copy("Resume", "继续") : copy("Pause", "暂停"))
            }
            Spacer()
            labeledButton(copy("Next page", "下一页"), width: 80) {
                Button(action: onNextPage) {
                    Image(systemName: "doc.viewfinder")
                        .font(.system(size: 19))
                        .foregroundStyle(Theme.gold)
                        .frame(width: 52, height: 52)
                        .background(Theme.gold.opacity(0.18), in: Circle())
                }
                .accessibilityLabel(copy("Scan the next page", "扫描下一页"))
            }
            .opacity(canScan ? 1 : 0)
            .disabled(!canScan)
        }
    }

    private func labeledButton<Content: View>(_ title: String, width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 8) {
            content()
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
                .accessibilityHidden(true)
        }
        .frame(width: width)
    }

    private func message(icon: String, text: String, action: (String, () -> Void)?) -> some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(Theme.gold)
            Text(text)
                .font(.system(size: 16))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(OutlineButtonStyle())
                    .frame(maxWidth: 220)
            }
        }
        .padding(.horizontal, 16)
    }
}

/// Colours for the glow, from the ambience that's playing.
struct SceneMood {
    let primary: Color
    let secondary: Color
    let dot: Color

    init(sceneIDs: [String]) {
        let ids = sceneIDs.joined(separator: " ")
        func has(_ words: String...) -> Bool { words.contains { ids.contains($0) } }
        if has("fire", "candle", "hearth") {
            (primary, secondary, dot) = (Color(hex: 0x8A3E16), Color(hex: 0xC9762E), Color(hex: 0xF2B45A))
        } else if has("sea", "ocean", "beach", "wave", "underwater", "lake") {
            (primary, secondary, dot) = (Color(hex: 0x0F5A7A), Color(hex: 0x1F8AA8), Color(hex: 0x7FD3E8))
        } else if has("rain", "storm", "thunder", "wind", "snow", "blizzard") {
            (primary, secondary, dot) = (Color(hex: 0x2E4A8A), Color(hex: 0x5A6FA8), Color(hex: 0x8FA6E0))
        } else if has("forest", "wood", "jungle", "garden", "meadow", "farm", "brook", "river", "stream") {
            (primary, secondary, dot) = (Color(hex: 0x1F5A48), Color(hex: 0x2F7A5E), Color(hex: 0x7FD1A6))
        } else if has("cave", "night", "castle", "space") {
            (primary, secondary, dot) = (Color(hex: 0x3A2E7A), Color(hex: 0x5A4AA8), Color(hex: 0xB1A6F0))
        } else {
            (primary, secondary, dot) = (Color(hex: 0x25336B), Color(hex: 0x3A4A86), Color(hex: 0xA7AEC8))
        }
    }
}

/// Lowers screen brightness while reading and puts it back afterwards.
@MainActor
final class ScreenDimmer {
    private var saved: CGFloat?
    private let level: CGFloat = 0.3

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
    }

    func dim() {
        guard saved == nil, let screen else { return }
        saved = screen.brightness
        if screen.brightness > level { screen.brightness = level }
    }

    func restore() {
        guard let saved, let screen else { return }
        screen.brightness = saved
        self.saved = nil
    }
}
