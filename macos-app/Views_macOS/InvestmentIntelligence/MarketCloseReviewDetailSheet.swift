import SwiftUI

struct MarketCloseReviewDetailSheet: View {
    let review: MarketCloseReviewSnapshot

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: AppPalette.spaceM) {
                Image(systemName: "sunset.fill")
                    .font(AppPalette.appFont(.title2, weight: .bold))
                    .foregroundStyle(AppPalette.brand)
                    .frame(width: 38, height: 38)
                    .background(
                        AppPalette.brand.opacity(AppPalette.accentFill),
                        in: RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: AppPalette.spaceXS) {
                    Text("今日收盘复盘")
                        .font(AppPalette.appFont(.title2, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text(review.subtitle)
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                }

                Spacer(minLength: AppPalette.spaceM)

                Button("关闭", systemImage: "xmark", action: dismiss.callAsFunction)
                    .buttonStyle(.appSecondary)
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("关闭完整收盘复盘")
            }
            .padding(AppPalette.spaceL)

            Divider()

            ScrollView {
                MarketCloseReviewDetailsView(review: review)
                    .padding(AppPalette.spaceL)
            }
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 560, idealHeight: 680)
        .background(AppPalette.surface)
    }
}
