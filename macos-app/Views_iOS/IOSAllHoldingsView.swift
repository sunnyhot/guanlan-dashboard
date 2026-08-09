#if os(iOS)
import SwiftUI

// MARK: - 共享持仓行

struct IOSHoldingRow: View {
    let row: PersonalAssetAggregateRow
    var isPinned: Bool = false
    var onTap: (() -> Void)? = nil

    private var holding: UserPortfolioValuationRow? { row.holdingRow }
    private var marketValue: Double? { holding?.marketValue }
    private var change: Double? { holding?.estimatedDailyChangeAmount }

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: IOSDesign.spaceS) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: IOSDesign.spaceXS) {
                        Text(row.fundName)
                            .font(IOSDesign.sansBody(15, weight: .medium))
                            .foregroundStyle(IOSDesign.ink)
                            .lineLimit(1)
                        if isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(AppPalette.warning)
                        }
                    }
                    if let code = row.fundCode {
                        Text(code)
                            .font(IOSDesign.sansBody(12))
                            .foregroundStyle(IOSDesign.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(marketValue.map { currencyText($0) } ?? "—")
                        .font(IOSDesign.monoNumber(15))
                        .foregroundStyle(IOSDesign.ink)
                    if let change {
                        Text(signedCurrencyText(change))
                            .font(IOSDesign.monoNumber(12, weight: .medium))
                            .foregroundStyle(marketTone(for: change).color)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(IOSDesign.muted)
            }
            .contentShape(Rectangle())
            .padding(.vertical, IOSDesign.spaceXS)
        }
        .buttonStyle(.plain)
    }
}
#endif
