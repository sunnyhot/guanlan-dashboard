import SwiftUI

struct PersonalWatchlistGroup: View {
    let category: PersonalWatchlistCategory
    let rows: [PersonalWatchlistQuoteRow]
    let selectedItemID: UUID?
    let onSelect: (PersonalWatchlistQuoteRow) -> Void
    let onConfigureAlerts: (PersonalWatchlistQuoteRow) -> Void
    let onDelete: (PersonalWatchlistQuoteRow) -> Void

    private var tint: Color {
        switch category {
        case .offExchangeFund:
            return AppPalette.brand
        case .onExchangeFund:
            return AppPalette.accentWarm
        case .stock:
            return AppPalette.info
        }
    }

    private var gainCount: Int {
        rows.filter { ($0.changeSinceFollowPct ?? 0) > 0 }.count
    }

    private var lossCount: Int {
        rows.filter { ($0.changeSinceFollowPct ?? 0) < 0 }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: AppPalette.swatchRadius)
                    .fill(tint)
                    .frame(width: 3, height: 18)
                Text(category.displayName)
                    .font(AppPalette.appFont(.headline, weight: .bold))
                    .foregroundStyle(tint)
                ToolbarBadge(title: "\(rows.count) 只", tint: tint)
                Spacer(minLength: 8)
                if gainCount > 0 {
                    Text("上涨 \(gainCount)")
                        .foregroundStyle(AppPalette.marketGain)
                }
                if lossCount > 0 {
                    Text("下跌 \(lossCount)")
                        .foregroundStyle(AppPalette.marketLoss)
                }
            }
            .font(AppPalette.appFont(.footnote, weight: .semibold))
            .padding(.horizontal, AppPalette.spaceM)
            .padding(.vertical, 10)
            .background(tint.opacity(0.06))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(tint.opacity(0.18))
                    .frame(height: 1)
            }

            VStack(spacing: AppPalette.spaceS) {
                ForEach(rows) { row in
                    VStack(spacing: AppPalette.spaceS) {
                        PersonalWatchlistListRow(
                            row: row,
                            isSelected: selectedItemID == row.id,
                            tint: tint,
                            onSelect: { onSelect(row) },
                            onConfigureAlerts: { onConfigureAlerts(row) },
                            onDelete: { onDelete(row) }
                        )

                        if selectedItemID == row.id {
                            PersonalWatchlistDetailChart(row: row)
                                .transition(.opacity)
                        }
                    }
                }
            }
        }
    }
}
