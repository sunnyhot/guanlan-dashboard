import SwiftUI

// MARK: - AlfaHoldingCard

/// alfa 投顾组合持仓成分卡片（百分比口径：占比 + 净值 + 日涨跌）。
/// 与长赢的 `HoldingCard`（份数/市值/收益率口径）不同。
struct AlfaHoldingCard: View {
    let part: AlfaHoldingPart
    let rank: Int

    private var returnTint: Color {
        AppPalette.marketTint(for: part.dailyReturn)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Text(String(format: "%02d", rank))
                    .font(AppPalette.appFont(.footnote, weight: .bold, design: .rounded))
                    .foregroundStyle(AppPalette.brand)
                    .frame(width: 28, height: 28)
                    .background(AppPalette.brand.opacity(0.11), in: RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 3) {
                    Text(part.fundName)
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        Text(part.fundCode)
                            .font(AppPalette.appFont(.caption, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppPalette.muted)
                        if let variety = part.varietyName, !variety.isEmpty {
                            TintedCapsuleBadge(
                                text: variety,
                                tint: AppPalette.info,
                                font: AppPalette.appFont(.caption, weight: .medium),
                                horizontalPadding: 5,
                                verticalPadding: 2,
                                softFillOpacity: 0.09,
                                softStrokeOpacity: nil
                            )
                        }
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("目标占比")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                    Text(part.percentText)
                        .font(AppPalette.appFont(.title3, weight: .bold, design: .rounded))
                        .foregroundStyle(AppPalette.ink)
                }
            }

            ProgressView(value: min(max(part.percent, 0), 1), total: 1)
                .progressViewStyle(.linear)
                .tint(AppPalette.brand)

            HStack(spacing: 0) {
                holdingMetric(
                    title: "最新净值",
                    value: part.nav.map { String(format: "%.4f", $0) } ?? "—",
                    tint: AppPalette.ink
                )
                Spacer()
                holdingMetric(
                    title: "净值日期",
                    value: part.navDate ?? "—",
                    tint: AppPalette.muted
                )
                Spacer()
                holdingMetric(
                    title: "日涨跌",
                    value: part.dailyReturnText,
                    tint: returnTint,
                    alignment: .trailing
                )
            }
        }
        .padding(12)
        .background(AppPalette.cardStrong.opacity(0.82), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                .stroke(AppPalette.line.opacity(0.38), lineWidth: 1)
        )
    }

    private func holdingMetric(
        title: String,
        value: String,
        tint: Color,
        alignment: HorizontalAlignment = .leading
    ) -> some View {
        LabeledValue(
            title: title,
            value: value,
            tint: tint,
            titleSize: .caption2,
            valueSize: .footnote,
            valueWeight: .semibold,
            valueDesign: .monospaced,
            minimumScaleFactor: 1.0,
            alignment: alignment
        )
    }
}
