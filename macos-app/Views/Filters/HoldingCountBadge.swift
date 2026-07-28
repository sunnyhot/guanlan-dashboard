import SwiftUI

struct HoldingCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count) 持仓")
            .font(AppPalette.appFont(.footnote, weight: .semibold))
            .foregroundStyle(AppPalette.brand)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(AppPalette.brand.opacity(0.12), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(AppPalette.brand.opacity(0.22), lineWidth: 1)
            )
    }
}
