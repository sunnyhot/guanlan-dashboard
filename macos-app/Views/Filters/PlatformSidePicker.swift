import SwiftUI

struct PlatformSidePicker: View {
    @Binding var selection: PlatformSideFilter
    let counts: PlatformActionCounts

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PlatformSideFilter.allCases) { filter in
                let isSelected = selection == filter
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selection = filter
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: filter.systemImage)
                            .font(AppPalette.appFont(.footnote, weight: .semibold))
                        Text(label(for: filter))
                            .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    }
                    .foregroundStyle(isSelected ? AppPalette.onBrand : AppPalette.muted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Group {
                            if isSelected {
                                Capsule()
                                    .fill(AppPalette.brand)
                                    .overlay(
                                        Capsule()
                                            .stroke(AppPalette.brand.opacity(0.6), lineWidth: 1)
                                    )
                            } else {
                                Capsule()
                                    .fill(AppPalette.card)
                                    .overlay(
                                        Capsule()
                                            .stroke(AppPalette.line.opacity(0.45), lineWidth: 1)
                                    )
                            }
                        }
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func label(for filter: PlatformSideFilter) -> String {
        let count: Int
        switch filter {
        case .all: count = counts.all
        case .buy: count = counts.buy
        case .sell: count = counts.sell
        }
        return "\(filter.rawValue) (\(count))"
    }
}
