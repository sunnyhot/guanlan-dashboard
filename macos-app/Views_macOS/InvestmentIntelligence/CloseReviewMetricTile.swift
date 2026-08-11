import SwiftUI

struct CloseReviewMetricTile: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceXS) {
            Text(title)
                .font(AppPalette.appFont(.caption, weight: .bold))
                .foregroundStyle(AppPalette.muted)
            Text(value)
                .font(AppPalette.appFont(.headline, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(detail)
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
