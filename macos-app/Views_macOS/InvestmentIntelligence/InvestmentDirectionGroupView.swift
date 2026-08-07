import SwiftUI

struct InvestmentDirectionGroupView: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let signals: [InvestmentDirectionSignal]
    let emptyText: String
    @Binding var selectedSignal: InvestmentDirectionSignal?

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            Label(title, systemImage: systemImage)
                .font(AppPalette.appFont(.body, weight: .semibold))
                .foregroundStyle(AppPalette.ink)

            Text(subtitle)
                .font(AppPalette.appFont(.subheadline))
                .foregroundStyle(AppPalette.muted)

            if signals.isEmpty {
                InvestmentEmptyState(
                    icon: "tray",
                    title: "暂无可展示结论",
                    detail: emptyText
                )
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 285, maximum: 390), spacing: AppPalette.spaceS)
                    ],
                    alignment: .leading,
                    spacing: AppPalette.spaceS
                ) {
                    ForEach(signals) { signal in
                        InvestmentDirectionCard(
                            signal: signal,
                            selectedSignal: $selectedSignal
                        )
                    }
                }
            }
        }
    }
}
