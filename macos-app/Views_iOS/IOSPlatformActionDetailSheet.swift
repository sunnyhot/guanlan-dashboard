#if os(iOS)
import SwiftUI

// MARK: - iOS 调仓详情 Sheet
//
// 对齐 macOS PlatformActionDetailCard 的产品逻辑,展示调仓明细全字段:
// side/fundName/百分比或估值分支/comment/数据来源/平台原文。

struct IOSPlatformActionDetailSheet: View {
    let action: PlatformActionPayload
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: IOSDesign.spaceL) {
                    headerSection
                    if action.isPercentBased {
                        percentSection
                    } else {
                        valuationSection
                    }
                    if let comment = action.comment, !comment.isEmpty {
                        commentSection(comment)
                    }
                    sourceSection
                    if let url = articleURL {
                        Button {
                            openURL(url)
                        } label: {
                            Label("查看平台原文", systemImage: "arrow.up.right.square")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(IOSDesign.accent)
                    }
                }
                .padding(.horizontal, IOSDesign.spaceM)
                .padding(.vertical, IOSDesign.spaceM)
            }
            .background(IOSDesign.paper)
            .navigationTitle("调仓明细")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private var articleURL: URL? {
        guard let raw = action.articleUrl, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    // MARK: - 头部

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            HStack(spacing: IOSDesign.spaceS) {
                if let side = action.side {
                    sideBadge(side)
                }
                Text(action.displayTitle)
                    .font(IOSDesign.serifHeading(20))
                    .foregroundStyle(IOSDesign.ink)
                    .lineLimit(3)
            }
            if let fundCode = action.fundCode, !fundCode.isEmpty {
                Text("\(action.fundName ?? "") · \(fundCode)")
                    .font(IOSDesign.sansBody(13))
                    .foregroundStyle(IOSDesign.muted)
            }
            if let date = dateString {
                Text(date)
                    .font(IOSDesign.sansBody(12))
                    .foregroundStyle(IOSDesign.muted)
            }
        }
    }

    private func sideBadge(_ side: String) -> some View {
        let isBuy = side.lowercased() == "buy"
        return Text(isBuy ? "买入" : "卖出")
            .font(IOSDesign.sansBody(12, weight: .semibold))
            .padding(.horizontal, IOSDesign.spaceS)
            .padding(.vertical, 3)
            .background((isBuy ? AppPalette.marketGain : AppPalette.marketLoss).opacity(0.12), in: Capsule())
            .foregroundStyle(isBuy ? AppPalette.marketGain : AppPalette.marketLoss)
    }

    // MARK: - 百分比调仓(alfa 投顾)

    private var percentSection: some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            sectionLabel("持仓比例")
            HStack(spacing: IOSDesign.spaceM) {
                if let before = action.beforePercent {
                    metricTile("调仓前", value: percentText(before))
                }
                Image(systemName: "arrow.right")
                    .foregroundStyle(IOSDesign.muted)
                if let after = action.afterPercent {
                    metricTile("调仓后", value: percentText(after), highlight: true)
                }
            }
            if let before = action.beforePercent, let after = action.afterPercent {
                let change = after - before
                HStack {
                    Text("仓位变化")
                        .font(IOSDesign.sansBody(13))
                        .foregroundStyle(IOSDesign.muted)
                    Spacer()
                    Text(String(format: "%+.2f%%", change * 100))
                        .font(IOSDesign.monoNumber(15))
                        .foregroundStyle(change > 0 ? AppPalette.marketGain : (change < 0 ? AppPalette.marketLoss : IOSDesign.muted))
                }
            }
            if let group = action.groupName, !group.isEmpty {
                metaRow("调仓分组", group)
            }
        }
    }

    // MARK: - 估值调仓(长赢)

    private var valuationSection: some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            sectionLabel("交易明细")
            if let v = action.tradeValuation {
                metricRow("交易估值", currencyText(v))
            }
            if let v = action.currentValuation {
                metricRow("现估值", currencyText(v))
            }
            if let pct = action.valuationChangePct {
                metricRow("估值变化率", signedPercent(pct), tone: marketTone(for: pct))
            }
            if let amt = action.valuationChangeAmount {
                metricRow("变化金额", signedCurrency(amt), tone: marketTone(for: amt))
            }
            if let unit = action.tradeUnit {
                metricRow("交易份数", "\(unit) 份")
            }
            if let unit = action.postPlanUnit {
                metricRow("计划份数", "\(unit) 份")
            }
            if let act = action.action, !act.isEmpty {
                metricRow("动作", act)
            }
        }
    }

    // MARK: - 说明 / 来源

    private func commentSection(_ comment: String) -> some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            sectionLabel("调仓说明")
            Text(comment)
                .font(IOSDesign.sansBody(14))
                .foregroundStyle(IOSDesign.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(IOSDesign.spaceM)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(IOSDesign.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: IOSDesign.radiusS))
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let s = action.tradeValuationSource, !s.isEmpty {
                metaRow("交易估值来源", s)
            }
            if let s = action.currentValuationSource, !s.isEmpty {
                metaRow("现估值来源", s)
            }
        }
    }

    // MARK: - 组件辅助

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(IOSDesign.sansBody(13, weight: .semibold))
            .foregroundStyle(IOSDesign.muted)
    }

    private func metricTile(_ title: String, value: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(IOSDesign.sansBody(12)).foregroundStyle(IOSDesign.muted)
            Text(value)
                .font(IOSDesign.monoNumber(17))
                .foregroundStyle(highlight ? IOSDesign.accent : IOSDesign.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(IOSDesign.spaceS + 4)
        .background(IOSDesign.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: IOSDesign.radiusS))
    }

    private func metricRow(_ title: String, _ value: String, tone: IOSStatTile.StatTone = .neutral) -> some View {
        HStack {
            Text(title).font(IOSDesign.sansBody(14)).foregroundStyle(IOSDesign.muted)
            Spacer()
            Text(value)
                .font(IOSDesign.monoNumber(14))
                .foregroundStyle(tone == .neutral ? IOSDesign.ink : tone.color)
        }
    }

    private func metaRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).font(IOSDesign.sansBody(13)).foregroundStyle(IOSDesign.muted)
            Spacer()
            Text(value).font(IOSDesign.sansBody(13)).foregroundStyle(IOSDesign.ink).multilineTextAlignment(.trailing)
        }
    }

    // MARK: - 格式化

    private var dateString: String? {
        let raw = action.txnDate ?? action.createdAt ?? ""
        guard !raw.isEmpty else { return nil }
        return raw.count >= 10 ? String(raw.prefix(10)) : raw
    }

    private func percentText(_ v: Double) -> String {
        String(format: "%.2f%%", v * 100)
    }

    private func signedPercent(_ v: Double) -> String {
        String(format: "%+.2f%%", v)
    }

    private func signedCurrency(_ v: Double) -> String {
        signedCurrencyText(v)
    }
}
#endif
