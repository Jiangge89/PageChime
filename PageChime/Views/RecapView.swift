import SwiftUI

/// "The end": a short look back at the story just read.
struct RecapView: View {
    let copy: Copy
    let story: StoryProgress?
    let onAnotherStory: () -> Void
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                HStack {
                    Spacer()
                    CircleIconButton(systemName: "xmark", label: copy("Close", "关闭"), action: onDone)
                }

                VStack(spacing: 14) {
                    Image(systemName: "moon.stars")
                        .font(.system(size: 50, weight: .light))
                        .foregroundStyle(Theme.gold)
                        .accessibilityHidden(true)
                    Text(copy("The end.", "讲完啦。"))
                        .font(Theme.serif(48))
                        .foregroundStyle(Theme.text)
                    Text(copy("Sweet dreams.", "晚安，好梦。"))
                        .font(Theme.serif(18, weight: .regular).italic())
                        .foregroundStyle(Theme.muted)
                }
                .padding(.top, 24)

                if let story {
                    HStack(spacing: 10) {
                        stat(minutes(story), copy(minutes(story) == 1 ? "minute" : "minutes", "分钟"))
                            .accessibilityIdentifier("recapMinutes")
                        stat(story.pages, copy(story.pages == 1 ? "page" : "pages", "页"))
                            .accessibilityIdentifier("recapPages")
                        stat(story.soundCount, copy(story.soundCount == 1 ? "sound" : "sounds", "个音效"))
                            .accessibilityIdentifier("recapSounds")
                    }

                    if !story.soundIDs.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(copy("Tonight's sounds", "今晚的声音"))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.muted)
                            FlowLayout(spacing: 8) {
                                ForEach(story.soundIDs.prefix(12), id: \.self) { id in
                                    chip(SoundName.scene(id), dim: false)
                                }
                                if story.soundIDs.count > 12 {
                                    chip(copy("+ \(story.soundIDs.count - 12) more", "还有 \(story.soundIDs.count - 12) 个"), dim: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button(copy("Read another story", "再读一个故事"), action: onAnotherStory)
                    .buttonStyle(GoldButtonStyle(height: 58))
                Button(copy("Done for tonight", "今晚就到这里"), action: onDone)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .frame(height: 50)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
    }

    private func minutes(_ story: StoryProgress) -> Int {
        let end = story.endedAt ?? Date()
        return max(1, Int((end.timeIntervalSince(story.startedAt) / 60).rounded()))
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(Theme.serif(28))
                .foregroundStyle(Theme.text)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func chip(_ text: String, dim: Bool) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(dim ? Theme.muted : Theme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surface, in: Capsule())
    }
}

/// Wraps its children onto new lines, like words in a paragraph.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let isFirst = rows[rows.count - 1].indices.isEmpty
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += isFirst ? size.width : size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
