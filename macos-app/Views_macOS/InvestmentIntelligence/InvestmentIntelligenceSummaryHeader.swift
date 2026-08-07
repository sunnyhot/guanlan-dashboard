import SwiftUI

/// AI 投资助手的首屏判断。信息先于装饰，不使用虚构评分。
///
/// `embedded = true` 时只渲染内容（无卡片外壳），用于嵌入父级 `SectionCard`
/// 避免「卡中卡」；`embedded = false`（默认）自带卡片外壳作为独立 hero。
struct InvestmentIntelligenceSummaryHeader: View {
    let summary: InvestmentIntelligenceDashboardSummary
    var embedded: Bool = false

    private var tint: Color {
        InvestmentIntelligenceStyle.tint(for: summary.overallState)
    }

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                content
                    .padding(.vertical, AppPalette.spaceM)
                    .padding(.horizontal, AppPalette.spaceL)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                            .stroke(AppPalette.muted.opacity(0.16), lineWidth: 1)
                    )
            }
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: AppPalette.spaceL) {
            Rectangle()
                .fill(tint)
                .frame(width: 3)
                .clipShape(Capsule())

            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                Text(summary.headline)
                    .font(AppPalette.appFont(.headline, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if !summary.detail.isEmpty {
                    Text(summary.detail.replacingOccurrences(of: "\n", with: " · "))
                        .font(AppPalette.appFont(.subheadline))
                        .foregroundStyle(AppPalette.muted)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: AppPalette.spaceL)

            HStack(alignment: .top, spacing: AppPalette.spaceL) {
                InvestmentMetricLabel(
                    title: "活跃事项",
                    value: "\(summary.activeCaseCount)",
                    tint: summary.activeCaseCount == 0 ? AppPalette.positive : tint
                )
                InvestmentMetricLabel(
                    title: "待复盘",
                    value: "\(summary.reviewDueCount)",
                    tint: summary.reviewDueCount == 0 ? AppPalette.ink : AppPalette.warning
                )
            }
            .frame(width: 150)
        }
    }
}
