import SwiftUI

struct CloseReviewMetricsView: View {
    let review: MarketCloseReviewSnapshot.PortfolioReview

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            Label("组合今日表现", systemImage: "chart.line.uptrend.xyaxis")
                .font(AppPalette.appFont(.headline, weight: .bold))
                .foregroundStyle(AppPalette.ink)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppPalette.spaceM) {
                    metricTiles(axis: .horizontal)
                }
                VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                    metricTiles(axis: .vertical)
                }
            }
            .padding(AppPalette.spaceM)
            .staticSurface(
                tint: changeTint,
                fill: AppPalette.cardStrong,
                strokeOpacity: AppPalette.strokeSubtle,
                activeStrokeOpacity: 0.40
            )
        }
    }

    @ViewBuilder
    private func metricTiles(axis: Axis) -> some View {
        CloseReviewMetricTile(
            title: review.changeTitle,
            value: dailyChangeCurrencyText(review.dailyChangeAmount),
            detail: dailyChangePercentText(review.dailyChangePct),
            tint: changeTint
        )
        metricDivider(axis: axis)
        CloseReviewMetricTile(
            title: "涨跌覆盖",
            value: "\(review.coveredHoldingCount)/\(review.holdingCount)",
            detail: review.coveredHoldingCount == review.holdingCount ? "持仓已全部覆盖" : "仅按已有净值计算",
            tint: review.coveredHoldingCount == review.holdingCount
                ? AppPalette.positive
                : AppPalette.warning
        )
        metricDivider(axis: axis)
        if let impact = review.holdingImpacts.first {
            CloseReviewMetricTile(
                title: "首要影响",
                value: impact.name,
                detail: "\(dailyChangeCurrencyText(impact.changeAmount, market: impact.market)) · \(dailyChangePercentText(impact.changePct))",
                tint: AppPalette.marketTint(for: impact.changeAmount ?? impact.changePct)
            )
        } else {
            CloseReviewMetricTile(
                title: "组合市值",
                value: currencyText(review.totalMarketValue),
                detail: "等待持仓涨跌数据",
                tint: AppPalette.info
            )
        }
    }

    @ViewBuilder
    private func metricDivider(axis: Axis) -> some View {
        if axis == .horizontal {
            Divider().frame(height: 42)
        } else {
            Divider()
        }
    }

    private var changeTint: Color {
        AppPalette.marketTint(for: review.dailyChangeAmount ?? review.dailyChangePct)
    }
}
