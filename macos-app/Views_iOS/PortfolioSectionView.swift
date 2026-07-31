#if os(iOS)
import SwiftUI

// MARK: - iOS 持仓页
//
// 复用 AppModel 数据(userPortfolioSnapshot / personalAssetRows),iPhone 原生
// 单列布局:顶部资产概览卡(总市值/今日涨跌/累计收益) + 持仓基金列表。
// 组合诊断/收益归因等复杂分析在 iOS 暂以摘要形式展示。

struct PortfolioSectionView: View {
    @EnvironmentObject private var model: AppModel
    @State private var detailRow: PersonalAssetAggregateRow?
    @State private var showingAddHolding = false
    @State private var showingWatchlist = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
                overviewCard
                holdingsListCard
            }
            .padding(.horizontal, IOSDesign.spaceM)
            .padding(.vertical, 12)
        }
        .background(IOSDesign.paper)
        .refreshable {
            try? await model.refreshLatest(persist: false)
        }
        .sheet(item: $detailRow) { row in
            IOSPersonalAssetDetailSheet(row: row)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingAddHolding) {
            IOSAddHoldingSheet()
        }
        .sheet(isPresented: $showingWatchlist) {
            IOSPersonalWatchlistSheet()
        }
    }

    // MARK: - 资产概览卡

    private var overviewCard: some View {
        let snapshot = model.userPortfolioSnapshot
        return IOSSectionCard(title: "我的持仓", subtitle: snapshot?.refreshedAt ?? "尚未加载", icon: "briefcase.fill") {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    IOSStatTile(
                        title: "总市值",
                        value: snapshot.map { currencyText($0.totalMarketValue) } ?? "—"
                    )
                    IOSStatTile(
                        title: snapshot?.dailyChangeTitle ?? "今日涨跌",
                        value: dailyChangeText(snapshot?.dailyChangeSummary.amount),
                        tone: marketTone(for: snapshot?.dailyChangeSummary.amount)
                    )
                    IOSStatTile(
                        title: "累计收益",
                        value: profitText(snapshot?.totalProfitAmount),
                        tone: marketTone(for: snapshot?.totalProfitAmount)
                    )
                    IOSStatTile(
                        title: "累计收益率",
                        value: profitPctText(snapshot?.totalProfitPct),
                        tone: marketTone(for: snapshot?.totalProfitPct)
                    )
                }
                if let pct = snapshot?.dailyChangeSummary.pct {
                    HStack {
                        Text("今日涨跌幅")
                            .font(.system(size: 13))
                            .foregroundStyle(AppPalette.muted)
                        Spacer()
                        Text(dailyChangePercentText(pct))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(marketTone(for: pct).color)
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - 持仓列表

    private var holdingsListCard: some View {
        let rows = model.personalAssetRows.filter { $0.holdingRow != nil }
        return IOSSectionCard(
            title: "持仓明细",
            subtitle: "\(rows.count) 只基金",
            icon: "list.bullet.rectangle.portrait",
            trailing: {
                Button {
                    showingAddHolding = true
                } label: {
                    Label("添加", systemImage: "plus.circle.fill")
                        .font(IOSDesign.sansBody(13, weight: .semibold))
                        .foregroundStyle(IOSDesign.accent)
                }
            }
        ) {
            // 关注列表入口
            Button {
                showingWatchlist = true
            } label: {
                HStack {
                    Image(systemName: "star.fill").foregroundStyle(IOSDesign.accent)
                    Text("关注列表").font(IOSDesign.sansBody(14, weight: .medium)).foregroundStyle(IOSDesign.ink)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(IOSDesign.muted)
                }
                .contentShape(Rectangle())
                .padding(.bottom, IOSDesign.spaceS)
            }
            .buttonStyle(.plain)

            if rows.isEmpty {
                IOSEmptyState(
                    title: "暂无持仓",
                    subtitle: "点击右上角「添加」,录入你的第一只基金或股票。",
                    actionTitle: "添加持仓"
                ) {
                    showingAddHolding = true
                }
            } else {
                ForEach(rows) { row in
                    holdingRow(row)
                    if row.id != rows.last?.id {
                        Divider().opacity(0.5)
                    }
                }
            }
        }
    }

    private func holdingRow(_ row: PersonalAssetAggregateRow) -> some View {
        let holding = row.holdingRow
        let marketValue = holding?.marketValue
        let change = holding?.estimatedDailyChangeAmount
        return Button {
            detailRow = row
        } label: {
            HStack(spacing: IOSDesign.spaceS + 2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.fundName)
                        .font(IOSDesign.sansBody(15, weight: .medium))
                        .foregroundStyle(IOSDesign.ink)
                        .lineLimit(1)
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

    // MARK: - 格式化辅助

    private func dailyChangeText(_ amount: Double?) -> String {
        guard let amount else { return "—" }
        return signedCurrencyText(amount)
    }

    private func profitText(_ amount: Double?) -> String {
        guard let amount else { return "—" }
        return signedCurrencyText(amount)
    }

    private func profitPctText(_ pct: Double?) -> String {
        guard let pct else { return "—" }
        return dailyChangePercentText(pct)
    }
}
#endif
