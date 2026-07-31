import SwiftUI

struct HoldingCountBadge: View {
    let count: Int

    var body: some View {
        TintedCapsuleBadge(
            text: "\(count) 持仓",
            tint: AppPalette.brand,
            font: AppPalette.appFont(.footnote, weight: .semibold),
            horizontalPadding: 9,
            verticalPadding: 4,
            softFillOpacity: 0.12,
            softStrokeOpacity: 0.22
        )
    }
}
