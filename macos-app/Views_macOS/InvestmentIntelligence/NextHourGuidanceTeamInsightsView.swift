import SwiftUI

struct NextHourGuidanceTeamInsightsView: View {
    let evidence: [TrendEvidence]

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            HStack(spacing: AppPalette.spaceS) {
                Label("三方判断约束", systemImage: "person.3.sequence.fill")
                    .font(AppPalette.appFont(.headline, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                TermHelpView(term: .teamConstraints)
            }
            Text("行情、新闻、持仓三个独立角度给出的限制，防止单一视角把话说满")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)

            NextHourGuidanceTeamInsightView(
                title: "行情信号",
                sourceName: "行情信号分析",
                systemImage: "waveform.path.ecg",
                tint: AppPalette.info,
                evidence: evidence
            )

            NextHourGuidanceTeamInsightView(
                title: "新闻事件",
                sourceName: "新闻事件分析",
                systemImage: "newspaper.fill",
                tint: AppPalette.brand,
                evidence: evidence
            )

            NextHourGuidanceTeamInsightView(
                title: "持仓结构",
                sourceName: "持仓结构分析",
                systemImage: "chart.pie.fill",
                tint: AppPalette.warning,
                evidence: evidence
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
