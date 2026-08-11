import SwiftUI

struct CloseReviewHoldingSummaryView: View {
    let review: MarketCloseReviewSnapshot.PortfolioReview?

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            HStack(alignment: .firstTextBaseline, spacing: AppPalette.spaceS) {
                Label("主要持仓影响", systemImage: "chart.pie.fill")
                    .font(AppPalette.appFont(.headline, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                Spacer(minLength: AppPalette.spaceS)
                if review?.holdingImpacts.isEmpty == false {
                    Text("按当日影响金额排序")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                }
            }

            if let review, !review.holdingImpacts.isEmpty {
                let items = Array(review.holdingImpacts.prefix(3))
                VStack(spacing: AppPalette.spaceS) {
                    ForEach(items) { item in
                        CloseReviewHoldingImpactCard(item: item)
                    }
                }
            } else {
                InvestmentEmptyState(
                    icon: "chart.pie",
                    title: review == nil ? "等待个人持仓" : "暂无持仓影响",
                    detail: review == nil ? "刷新个人持仓后显示主要影响。" : "暂时没有可展示的持仓涨跌数据。"
                )
            }
        }
    }
}
