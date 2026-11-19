import SwiftUI

/// Before a story: scan the first page, or just start reading.
struct HomeView: View {
    let copy: Copy
    let language: ReadingLanguage
    let canScan: Bool
    let onScan: () -> Void
    let onReadWithoutScanning: () -> Void
    let onLanguage: (ReadingLanguage) -> Void
    let onSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                VStack(alignment: .leading, spacing: 10) {
                    Text(copy("Tonight's story", "今晚的故事"))
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(1)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.gold)
                    Text(copy("Open the book to the first page.", "把书翻到第一页。"))
                        .font(Theme.serif(36))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 20)

                actions
                howItWorks
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            Label(copy("Your voice and pages are never saved", "你的声音和书页都不会被保存"), systemImage: "lock.shield")
                .font(.system(size: 13))
                .foregroundStyle(Theme.faint)
                .padding(.bottom, 8)
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 10) {
                Image("BrandMark")
                    .resizable()
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                Text("PageChime")
                    .font(Theme.serif(21, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            Spacer()
            Menu {
                Picker(copy("Reading language", "朗读语言"), selection: Binding(get: { language }, set: onLanguage)) {
                    ForEach(ReadingLanguage.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            } label: {
                Text(language == .chinese ? "中文" : "EN")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(Theme.surface, in: Capsule())
            }
            .accessibilityLabel(copy("Reading language: English", "朗读语言：中文"))
            CircleIconButton(systemName: "gearshape", label: copy("Settings", "设置"), action: onSettings)
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 14) {
            if canScan {
                Button(action: onScan) {
                    Label(copy("Scan the first page", "扫描第一页"), systemImage: "doc.viewfinder")
                }
                .buttonStyle(GoldButtonStyle(height: 62))

                Text(copy(
                    "Sounds load before you start, and play the moment you read the words.",
                    "开始前先准备好音效，读到那句话就立刻响起。"
                ))
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

                Button(copy("Read without scanning", "不扫描，直接读"), action: onReadWithoutScanning)
                    .buttonStyle(OutlineButtonStyle())
            } else {
                Button(action: onReadWithoutScanning) {
                    Label(copy("Start reading", "开始阅读"), systemImage: "book")
                }
                .buttonStyle(GoldButtonStyle(height: 62))
            }
        }
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(copy("How it works", "怎么用"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.muted)
            step(1, canScan ? copy("Scan the page you're about to read", "扫描要读的这一页") : copy("Tap Start reading", "点「开始阅读」"))
            step(2, copy("Read aloud as you always do", "像平常一样大声朗读"))
            step(3, canScan ? copy("Turn the page and scan the next one", "翻页后扫描下一页") : copy("Sounds follow the story", "音效会跟着故事响起"))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 14) {
            Text("\(number)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.gold)
                .frame(width: 28, height: 28)
                .background(Theme.numberFill, in: Circle())
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Theme.text)
        }
        .accessibilityElement(children: .combine)
    }
}
