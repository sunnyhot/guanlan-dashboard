import SwiftUI

// MARK: - StrategyRadarPanel

struct StrategyRadarPanel: View {
    let summary: StrategyRadarSummary

    var body: some View {
        SectionCard(title: "策略概览", subtitle: summary.headline, icon: "scope") {
            VStack(alignment: .leading, spacing: 12) {
                MetricStrip(items: [
                    MetricStripItem(id: "actions", title: "调仓动作", value: "\(summary.actionCount)"),
                    MetricStripItem(id: "buys", title: "买入", value: "\(summary.buyCount)", tint: AppPalette.marketGain),
                    MetricStripItem(id: "sells", title: "卖出", value: "\(summary.sellCount)", tint: AppPalette.marketLoss),
                    MetricStripItem(id: "strategies", title: "策略标签", value: "\(summary.strategyTypeCount)"),
                    MetricStripItem(id: "holdings", title: "持仓覆盖", value: "\(summary.holdingCount)"),
                ])

                VStack(spacing: 0) {
                    ForEach(Array(summary.items.enumerated()), id: \.element.id) { index, item in
                        StrategySignalRow(item: item)
                        if index < summary.items.count - 1 {
                            Divider()
                                .padding(.leading, AppPalette.spaceM)
                        }
                    }
                }
                .background(AppPalette.cardStrong.opacity(0.28), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
            }
        }
    }
}

struct StrategySignalRow: View {
    let item: StrategyRadarItem

    private var scoreTint: Color {
        if item.score >= 70 {
            return AppPalette.positive
        }
        if item.score >= 40 {
            return AppPalette.warning
        }
        return AppPalette.muted
    }

    var body: some View {
        HStack(alignment: .center, spacing: AppPalette.spaceM) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: AppPalette.spaceS) {
                    Text(item.title)
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                    Text(item.metric)
                        .font(AppPalette.appFont(.body, weight: .bold, design: .rounded))
                        .foregroundStyle(scoreTint)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Text(item.detail)
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(item.score)")
                    .font(AppPalette.appFont(.title3, weight: .bold, design: .rounded))
                    .foregroundStyle(scoreTint)
                    .monospacedDigit()
                Text("综合分")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.title)综合分 \(item.score)")
        }
        .padding(.horizontal, AppPalette.spaceM)
        .padding(.vertical, 10)
    }
}
