import SwiftUI

struct InvestmentDirectionMarketScanStateView: View {
    let title: String
    let detail: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: AppPalette.spaceXS) {
                Text(title)
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(detail)
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(AppPalette.warning)
        }
        .padding(AppPalette.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppPalette.warning.opacity(0.07),
            in: RoundedRectangle(cornerRadius: AppPalette.controlRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                .stroke(AppPalette.warning.opacity(0.24), lineWidth: 1)
        }
    }
}
