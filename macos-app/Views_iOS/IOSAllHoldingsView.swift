#if os(iOS)
import SwiftUI

// MARK: - iOS 全部持仓列表（从持仓页 push 进来）
//
// 首页持仓明细只展示前 5 条，超出部分通过「查看全部」按钮 push 到本视图。
// List（lazy）+ 右上角添加按钮 + 下拉刷新。点击行进 IOSPersonalAssetDetailSheet。
// 行渲染复用 IOSHoldingRow（与首页共享，避免重复实现）。

struct IOSAllHoldingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var detailRow: PersonalAssetAggregateRow?
    @State private var showingAdd = false

    private var rows: [PersonalAssetAggregateRow] {
        model.personalAssetRows.filter { $0.holdingRow != nil }
    }

    var body: some View {
        List {
            ForEach(rows) { row in
                IOSHoldingRow(row: row) { detailRow = row }
                    .listRowInsets(EdgeInsets(top: 6, leading: IOSDesign.spaceM, bottom: 6, trailing: IOSDesign.spaceM))
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .background(IOSDesign.paper)
        .scrollContentBackground(.hidden)
        .navigationTitle("持仓明细")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .refreshable {
            try? await model.refreshLatest(updateNotice: false)
        }
        .sheet(item: $detailRow) { row in
            IOSPersonalAssetDetailSheet(row: row)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingAdd) {
            IOSAddHoldingSheet()
        }
    }
}

// MARK: - 共享持仓行（首页前 10 条 + 全部列表页复用）

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
