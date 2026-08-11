import SwiftUI

struct MarketCloseReviewDetailsView: View {
    let review: MarketCloseReviewSnapshot

    var body: some View {
        LazyVStack(alignment: .leading, spacing: AppPalette.spaceM) {
            if let portfolio = review.portfolioReview {
                portfolioDetails(portfolio)
            }

            if !review.marketPulse.isEmpty {
                MarketCloseReviewMarketPulseView(items: review.marketPulse)
                    .padding(AppPalette.spaceM)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        AppPalette.cardStrong,
                        in: RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                    )
            }

            if !review.strongThemes.isEmpty || !review.weakThemes.isEmpty {
                MarketCloseReviewThemeView(
                    strongThemes: review.strongThemes,
                    weakThemes: review.weakThemes
                )
                .padding(AppPalette.spaceM)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    AppPalette.cardStrong,
                    in: RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                )
            }

            HStack(alignment: .top, spacing: AppPalette.spaceS) {
                Image(systemName: "shield.lefthalf.filled")
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AppPalette.spaceXS) {
                    Text("数据边界")
                        .font(AppPalette.appFont(.subheadline, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text(review.dataBoundary)
                    if let evidenceText = review.evidenceText {
                        Text(evidenceText)
                    }
                }
            }
            .font(AppPalette.appFont(.subheadline))
            .foregroundStyle(AppPalette.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(AppPalette.spaceM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .staticSurface(
                tint: AppPalette.info,
                fill: AppPalette.cardStrong,
                strokeOpacity: AppPalette.strokeSubtle,
                activeStrokeOpacity: 0.40
            )
        }
    }

    @ViewBuilder
    private func portfolioDetails(_ portfolio: MarketCloseReviewSnapshot.PortfolioReview) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            HStack(alignment: .firstTextBaseline, spacing: AppPalette.spaceS) {
                Label("组合明细", systemImage: "list.bullet.rectangle")
                    .font(AppPalette.appFont(.subheadline, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                Spacer(minLength: AppPalette.spaceS)
                Text("市值 \(currencyText(portfolio.totalMarketValue)) · 更新于 \(String(portfolio.refreshedAt.prefix(16)))")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
            }

            ForEach(portfolio.holdingImpacts) { item in
                CloseReviewHoldingImpactCard(item: item, showsWatch: true)
            }
        }
        .padding(AppPalette.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppPalette.cardStrong,
            in: RoundedRectangle(cornerRadius: AppPalette.cardRadius)
        )
    }
}
