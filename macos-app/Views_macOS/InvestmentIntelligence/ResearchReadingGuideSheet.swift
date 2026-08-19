import SwiftUI

/// 「怎么读这份研判」帮助:立场声明 + 三个关键数字 + 术语速查。
/// 术语内容全部来自 `ResearchTermGlossary`,不在此处另写文案。
struct ResearchReadingGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AppPalette.spaceS) {
                Label("怎么读这份研判", systemImage: "text.book.closed")
                    .font(AppPalette.appFont(.headline, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                Button("关闭", systemImage: "xmark", action: dismiss.callAsFunction)
                    .buttonStyle(.appSecondary)
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("关闭怎么读指南")
            }
            .padding(AppPalette.spaceL)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: AppPalette.spaceL) {
                    section(title: "怎么用这些结论", icon: "checkmark.shield") {
                        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                            bullet("只给依据和条件，不替你做买卖决定；买卖与否始终由你判断。")
                            bullet("证据不足时宁可明说不足，不会把没把握的结论包装成指令。")
                            bullet("所有结论都有时效，过了「有效至」或触发失效条件，就该重新评估。")
                        }
                    }

                    section(title: "三个关键数字", icon: "number.circle") {
                        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
                            ForEach(
                                [ResearchTerm.confidence, .triggerInvalidation, .independentSources]
                            ) { term in
                                termBlock(term)
                            }
                        }
                    }

                    section(title: "术语速查", icon: "character.book.closed") {
                        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
                            ForEach(ResearchTerm.allCases) { term in
                                termBlock(term)
                            }
                        }
                    }
                }
                .padding(AppPalette.spaceL)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 480, height: 560)
    }

    private func section<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            Label(title, systemImage: icon)
                .font(AppPalette.appFont(.subheadline, weight: .bold))
                .foregroundStyle(AppPalette.ink)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: AppPalette.spaceS) {
            Circle()
                .fill(AppPalette.brand)
                .frame(width: 4, height: 4)
                .padding(.top, 6)
            Text(text)
                .font(AppPalette.appFont(.subheadline))
                .foregroundStyle(AppPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func termBlock(_ term: ResearchTerm) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceXS) {
            Text(term.title)
                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
            Text(term.plainExplanation)
                .font(AppPalette.appFont(.subheadline))
                .foregroundStyle(AppPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text(term.example)
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppPalette.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppPalette.cardStrong.opacity(0.6),
            in: RoundedRectangle(cornerRadius: AppPalette.controlRadius)
        )
    }
}
