import SwiftUI

struct MarketCloseReviewHeaderView: View {
    let review: MarketCloseReviewSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            HStack(alignment: .firstTextBaseline, spacing: AppPalette.spaceS) {
                TintedCapsuleBadge(
                    text: review.eyebrow,
                    tint: stateTint,
                    font: AppPalette.appFont(.footnote, weight: .bold),
                    horizontalPadding: AppPalette.spaceS,
                    verticalPadding: 3,
                    softStrokeOpacity: nil
                )

                if let evidenceText = review.evidenceText {
                    Text(evidenceText)
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: AppPalette.spaceS)
            }

            Text(review.headline)
                .font(AppPalette.appFont(.title2, weight: .bold))
                .foregroundStyle(AppPalette.ink)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            Text(review.summary)
                .font(AppPalette.appFont(.subheadline))
                .foregroundStyle(AppPalette.muted)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stateTint: Color {
        switch review.state {
        case .ready: AppPalette.positive
        case .scanning, .awaitingClose: AppPalette.info
        case .noScan, .stale: AppPalette.warning
        }
    }
}
