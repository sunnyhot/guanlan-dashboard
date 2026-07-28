import SwiftUI

// MARK: - HoldingCard

struct HoldingCard: View {
    let holding: HoldingItemPayload

    private var profitTint: Color {
        AppPalette.marketTint(for: holding.displayProfitPct)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalLayout
            compactLayout
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .staticSurface(
            tint: profitTint,
            fill: AppPalette.card,
            strokeOpacity: 0.45,
            activeStrokeOpacity: 0.50
        )
    }

    private var horizontalLayout: some View {
        HStack(alignment: .center, spacing: 12) {
            accentBar

            identityBlock
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)

            metricsRow
                .frame(minWidth: 268, alignment: .leading)

            trailingSummary
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                accentBar
                identityBlock
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailingSummary
            }

            ViewThatFits(in: .horizontal) {
                metricsRow
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                    metricViews
                }
            }
            .padding(.leading, 13)
        }
    }

    private var accentBar: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(
                LinearGradient(
                    colors: [profitTint, profitTint.opacity(0.3)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 3, height: 42)
    }

    private var identityBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(holding.label ?? holding.fundName ?? "未命名标的")
                .font(AppPalette.appFont(.headline, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
                .lineLimit(1)

            Text("\(holding.fundCode ?? "无代码") · \(holding.largeClass ?? "未分类")")
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
                .lineLimit(1)

            Text("最近 \(holding.latestActionTitle ?? holding.latestAction ?? "未知动作") · \(holding.latestTime ?? "未知时间")")
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted.opacity(0.88))
                .lineLimit(1)
        }
    }

    private var metricsRow: some View {
        HStack(spacing: 14) {
            metricViews
        }
    }

    @ViewBuilder
    private var metricViews: some View {
        HoldingCardMetric(title: "均价", value: decimalText(holding.avgCost))
        HoldingCardMetric(title: "现价", value: decimalText(holding.currentPrice))
        HoldingCardMetric(title: "市值", value: amountText(holding.displayPositionValue))
        HoldingCardMetric(title: "收益率", value: percentText(holding.displayProfitPct), tint: profitTint)
    }

    private var trailingSummary: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("\(holding.currentUnits ?? 0) 份")
                .font(AppPalette.appFont(.title3, weight: .bold, design: .rounded))
                .foregroundStyle(AppPalette.ink)
                .monospacedDigit()
                .lineLimit(1)

            Text(holding.priceSourceLabel ?? holding.priceSource ?? "估值来源未知")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
                .lineLimit(1)
        }
        .frame(minWidth: 74, alignment: .trailing)
    }

    private func decimalText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.4f", value)
    }

    private func amountText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f", value)
    }

    private func percentText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%+.2f%%", value)
    }
}

private struct HoldingCardMetric: View {
    let title: String
    let value: String
    var tint: Color = AppPalette.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(AppPalette.appFont(.caption, weight: .medium))
                .foregroundStyle(AppPalette.muted)
                .lineLimit(1)

            Text(value)
                .font(AppPalette.appFont(.subheadline, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(minWidth: 54, alignment: .leading)
    }
}
