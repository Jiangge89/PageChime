import SwiftUI

/// After a scan: the page's text with its trigger words marked, and the
/// sounds that are ready.
struct PageReadyView: View {
    let copy: Copy
    let chinese: Bool
    let status: PageStatus
    let page: PageSummary?
    /// The story already has pages behind this one.
    let pageNumberHint: Int
    let onBack: () -> Void
    let onRescan: () -> Void
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 24)
                .padding(.top, 12)

            switch status {
            case .reading, .analyzing, .none:
                Spacer()
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Theme.gold)
                    Text(status == .analyzing
                        ? copy("Finding the sounds…", "正在准备音效…")
                        : copy("Reading the page…", "正在识别文字…"))
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
            case .failed(let message):
                Spacer()
                VStack(spacing: 18) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.gold)
                    Text(message)
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.center)
                    Button(copy("Scan again", "重新扫描"), action: onRescan)
                        .buttonStyle(OutlineButtonStyle())
                        .frame(maxWidth: 220)
                }
                .padding(.horizontal, 32)
                Spacer()
            case .ready:
                if let page {
                    ready(page)
                }
            }
        }
    }

    /// While a new page is loading, `page` still holds the previous one.
    private var pageNumber: Int {
        if case .ready = status, let page { return page.number }
        return pageNumberHint
    }

    private var topBar: some View {
        HStack {
            CircleIconButton(systemName: "chevron.left", label: copy("Back", "返回"), action: onBack)
            Spacer()
            Text(copy("Page \(pageNumber)", "第 \(pageNumber) 页"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.text)
            Spacer()
            CircleIconButton(systemName: "arrow.triangle.2.circlepath", label: copy("Scan this page again", "重新扫描这一页"), action: onRescan)
        }
    }

    private func ready(_ page: PageSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(highlighted(page))
                    .font(Theme.serif(19, weight: .regular))
                    .lineSpacing(7)
                    .foregroundStyle(Theme.ink)
                    .padding(.vertical, 22)
                    .padding(.horizontal, 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.paper, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 15, y: 12)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: page.cues.isEmpty ? "info.circle" : "checkmark.circle")
                            .foregroundStyle(page.cues.isEmpty ? Theme.muted : Theme.success)
                        Text(page.cues.isEmpty
                            ? copy("No sounds on this page", "这一页没有找到音效")
                            : copy("\(page.cues.count) \(page.cues.count == 1 ? "sound" : "sounds") ready", "\(page.cues.count) 个音效已就绪"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        if !page.cues.isEmpty {
                            Text(copy("· play when you read them", "· 读到就会响"))
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.muted)
                        }
                    }

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(uniqueSounds(page)) { cue in
                            soundChip(cue)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button(action: onStart) {
                    Label(copy("Start reading", "开始朗读"), systemImage: "play.fill")
                }
                .buttonStyle(GoldButtonStyle(height: 62))
                if !page.cues.isEmpty {
                    Text(copy("Highlighted words start each sound", "高亮的词会触发对应音效"))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(Theme.night)
        }
    }

    private func uniqueSounds(_ page: PageSummary) -> [PageSummary.Cue] {
        var seen = Set<String>()
        return page.cues.filter { seen.insert($0.soundID).inserted }
    }

    private func soundChip(_ cue: PageSummary.Cue) -> some View {
        HStack(spacing: 10) {
            Image(systemName: cue.isAmbience ? "wind" : SoundName.symbol(for: cue.type))
                .font(.system(size: 17))
                .foregroundStyle(Theme.gold)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(SoundName.display(cue.soundID))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(cue.isAmbience ? copy("Background", "背景声") : copy("Sound", "音效"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// The page as one paragraph, with each cue's trigger marked.
    private func highlighted(_ page: PageSummary) -> AttributedString {
        let separator = chinese ? "" : " "
        let flat = page.text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: separator)
        var result = AttributedString(flat)
        for cue in page.cues {
            guard let range = result.range(of: cue.trigger, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            result[range].backgroundColor = Theme.highlight
        }
        return result
    }
}
