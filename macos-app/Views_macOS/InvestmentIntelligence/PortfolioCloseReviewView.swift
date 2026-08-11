import SwiftUI

struct PortfolioCloseReviewView: View {
    let review: MarketCloseReviewSnapshot.PortfolioReview?
    let tomorrowWatch: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            CloseReviewHoldingSummaryView(review: review)
            CloseReviewTomorrowWatchView(items: tomorrowWatch)
        }
    }
}
