import SwiftUI

struct InvestmentDirectionDetailBlock: View {
    let title: String
    let systemImage: String
    let items: [String]
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            Label(title, systemImage: systemImage)
                .font(AppPalette.appFont(.headline, weight: .semibold))
                .foregroundStyle(AppPalette.ink)

            if items.isEmpty {
                Text(emptyText)
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Label {
                        Text(item)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(AppPalette.brand)
                            .accessibilityHidden(true)
                    }
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
                }
            }
        }
        .padding(AppPalette.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppPalette.cardStrong,
            in: RoundedRectangle(cornerRadius: AppPalette.controlRadius)
        )
    }
}
