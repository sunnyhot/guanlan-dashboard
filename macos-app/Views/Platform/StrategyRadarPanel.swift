import SwiftUI

// MARK: - StrategyRadarPanel

struct StrategyRadarPanel: View {
    let summary: StrategyRadarSummary

    var body: some View {
        SectionCard(title: "主理人策略雷达", subtitle: summary.headline, icon: "radar") {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
                    RadarStatChip(title: "调仓动作", value: "\(summary.actionCount)", tint: AppPalette.brand)
                    RadarStatChip(title: "买入", value: "\(summary.buyCount)", tint: AppPalette.positive)
                    RadarStatChip(title: "卖出", value: "\(summary.sellCount)", tint: AppPalette.warning)
                    RadarStatChip(title: "策略标签", value: "\(summary.strategyTypeCount)", tint: AppPalette.info)
                    RadarStatChip(title: "持仓覆盖", value: "\(summary.holdingCount)", tint: AppPalette.accentWarm)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 10)], spacing: 10) {
                    ForEach(summary.items) { item in
                        StrategyRadarTile(item: item)
                    }
                }
            }
        }
    }
}

struct RadarStatChip: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(AppPalette.appFont(.footnote, weight: .medium))
                .foregroundStyle(AppPalette.muted)
                .lineLimit(1)
            Text(value)
                .font(AppPalette.appFont(.title3, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppPalette.cardStrong.opacity(0.70), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                .stroke(tint.opacity(0.14), lineWidth: 1)
        )
    }
}

struct StrategyRadarTile: View {
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.title)
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(item.score)")
                    .font(AppPalette.appFont(.title3, weight: .bold, design: .rounded))
                    .foregroundStyle(scoreTint)
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppPalette.line.opacity(0.30))
                    Capsule()
                        .fill(scoreTint.opacity(0.86))
                        .frame(width: max(4, proxy.size.width * CGFloat(item.score) / 100))
                }
            }
            .frame(height: 6)

            Text(item.metric)
                .font(AppPalette.appFont(.body, weight: .bold, design: .rounded))
                .foregroundStyle(scoreTint)
                .monospacedDigit()
                .lineLimit(1)

            Text(item.detail)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .padding(12)
        .staticSurface(
            tint: scoreTint,
            fill: AppPalette.cardStrong.opacity(0.64),
            strokeOpacity: 0.16,
            activeStrokeOpacity: 0.30
        )
    }
}
