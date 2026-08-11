import SwiftUI

struct CloseReviewHoldingImpactCard: View {
    let item: MarketCloseReviewSnapshot.HoldingImpactItem
    var showsWatch = false

    private var tint: Color {
        AppPalette.marketTint(for: item.changeAmount ?? item.changePct)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceXS) {
            HStack(alignment: .firstTextBaseline, spacing: AppPalette.spaceS) {
                Text(item.name)
                    .font(AppPalette.appFont(.body, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(item.code)
                    .font(AppPalette.appFont(.footnote, design: .rounded))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
                Spacer(minLength: AppPalette.spaceS)
                Text(dailyChangeCurrencyText(item.changeAmount, market: item.market))
                    .font(AppPalette.appFont(.subheadline, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                    .lineLimit(1)
                Text(dailyChangePercentText(item.changePct))
                    .font(AppPalette.appFont(.caption, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            if let analysis = item.analysis {
                Label {
                    Text(analysis)
                        .lineLimit(showsWatch ? nil : 2)
                        .lineSpacing(2)
                } icon: {
                    Image(systemName: analysis.hasPrefix("原因待确认")
                        ? "questionmark.circle"
                        : "arrow.triangle.branch")
                        .accessibilityHidden(true)
                }
                .font(AppPalette.appFont(.subheadline))
                .foregroundStyle(AppPalette.muted)
            }

            if showsWatch, let watchText = item.watchText {
                Label("次日验证：\(watchText)", systemImage: "eye.fill")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, AppPalette.spaceM)
        .padding(.vertical, AppPalette.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .staticSurface(
            tint: tint,
            fill: AppPalette.cardStrong,
            strokeOpacity: AppPalette.strokeSubtle,
            activeStrokeOpacity: 0.40
        )
        .accessibilityElement(children: .combine)
    }
}
