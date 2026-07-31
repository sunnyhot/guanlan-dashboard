#if os(iOS)
import SwiftUI

// MARK: - iOS 持仓页
//
// 复用 AppModel 数据(userPortfolioSnapshot / personalAssetRows),iPhone 原生
// 单列布局:顶部资产概览卡(总市值/今日涨跌/累计收益) + 持仓基金列表。
// 组合诊断/收益归因等复杂分析在 iOS 暂以摘要形式展示。

struct PortfolioSectionView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                overviewCard
                holdingsListCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .refreshable {
            try? await model.refreshLatest(persist: false)
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
        return IOSSectionCard(title: "持仓明细", subtitle: "\(rows.count) 只基金", icon: "list.bullet.rectangle.portrait") {
            if rows.isEmpty {
                IOSEmptyState(
                    title: "暂无持仓",
                    subtitle: "在设置中配置主理人并刷新,或稍后手动导入持仓数据。",
                    actionTitle: "刷新"
                ) {
                    Task { try? await model.refreshLatest(persist: false) }
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
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.fundName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                if let code = row.fundCode {
                    Text(code)
                        .font(.system(size: 12))
                        .foregroundStyle(AppPalette.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(marketValue.map { currencyText($0) } ?? "—")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                if let change {
                    Text(signedCurrencyText(change))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(marketTone(for: change).color)
                }
            }
        }
        .padding(.vertical, 4)
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
