import SwiftUI

struct MarketCloseReviewMarketPulseView: View {
    let items: [MarketCloseReviewSnapshot.PulseItem]

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            Label("市场温度", systemImage: "waveform.path.ecg")
                .font(AppPalette.appFont(.headline, weight: .bold))
                .foregroundStyle(AppPalette.ink)

            ForEach(items) { item in
                VStack(alignment: .leading, spacing: AppPalette.spaceXS) {
                    HStack(spacing: AppPalette.spaceS) {
                        Text(item.name)
                            .font(AppPalette.appFont(.subheadline, weight: .semibold))
                            .foregroundStyle(AppPalette.ink)
                        Text(item.category)
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                        Spacer(minLength: AppPalette.spaceS)
                    TintedCapsuleBadge(
                        text: "\(item.direction.dashboardText) · \(item.confidenceText)",
                        tint: directionTint(item.direction),
                        font: AppPalette.appFont(.footnote, weight: .bold),
                        horizontalPadding: AppPalette.spaceS,
                        verticalPadding: 3,
                        softStrokeOpacity: nil
                    )
                }
                Text(item.rationale)
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
                    .lineSpacing(3)
                    .lineLimit(3)
                }
                if item.id != items.last?.id {
                    Divider()
                }
            }
        }
    }

    private func directionTint(_ direction: TrendDirection) -> Color {
        switch direction {
        case .bullish, .neutralPositive: AppPalette.positive
        case .neutral: AppPalette.info
        case .neutralNegative, .bearish: AppPalette.warning
        case .uncertain: AppPalette.muted
        }
    }
}
