import SwiftUI

struct NextHourGuidanceTeamInsightView: View {
    let title: String
    let sourceName: String
    let systemImage: String
    let tint: Color
    let evidence: [TrendEvidence]

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            HStack(spacing: AppPalette.spaceS) {
                Image(systemName: systemImage)
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(AppPalette.accentFill), in: RoundedRectangle(cornerRadius: AppPalette.iconBoxRadius))

                Text(title)
                    .font(AppPalette.appFont(.subheadline, weight: .bold))
                    .foregroundStyle(AppPalette.ink)

                Spacer(minLength: AppPalette.spaceS)

                Text("\(teamEvidence.count) 条")
                    .font(AppPalette.appFont(.caption, design: .rounded))
                    .foregroundStyle(AppPalette.muted)
            }

            if teamEvidence.isEmpty {
                Text("本轮没有形成可展示的独立结论。")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
            } else {
                ForEach(teamEvidence.prefix(2)) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(AppPalette.appFont(.caption, weight: .semibold))
                            .foregroundStyle(AppPalette.ink)
                            .lineLimit(2)
                        Text(item.summary)
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                            .lineLimit(2)
                    }
                }

                if teamEvidence.count > 2 {
                    Text("另有 \(teamEvidence.count - 2) 条结论，点击下方“完整依据”查看。")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(tint)
                }
            }
        }
        .padding(AppPalette.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.controlFill, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                .stroke(tint.opacity(AppPalette.strokeSubtle), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private var teamEvidence: [TrendEvidence] {
        evidence.filter { item in
            item.sourceName == sourceName || item.id.hasPrefix(evidenceIDPrefix)
        }
    }

    private var evidenceIDPrefix: String {
        switch sourceName {
        case "行情信号分析":
            "analysis:market:"
        case "新闻事件分析":
            "analysis:news:"
        case "持仓结构分析":
            "analysis:portfolio:"
        default:
            "unmatched-analysis-source:"
        }
    }
}
