#if os(iOS)
import SwiftUI
import Charts

// MARK: - iOS 基金穿透分析面板
//
// 复用 Core 的 `PortfolioLookThroughSnapshot`（纯函数派生）。
// iPhone 单列：覆盖度摘要 + 底层证券暴露 donut（SectorMark，等价 macOS 的 PortfolioTreemap）
// + 底层持仓 Top 列表 + 行业暴露水平柱状图（BarMark）。
// 数据来源 model.portfolioLookThroughSnapshot，由 PortfolioSectionView 的 .task(id:)
// 调用 model.refreshPortfolioLookThrough() 填充（对齐 macOS 触发模型）。

struct IOSPortfolioLookThroughPanel: View {
    let snapshot: PortfolioLookThroughSnapshot?

    var body: some View {
        IOSSectionCard(title: "基金穿透", subtitle: subtitle, icon: "square.stack.3d.up.fill") {
            if let snapshot {
                VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
                    coverageGrid(snapshot)
                    if !snapshot.topPositions.isEmpty {
                        positionsDonut(snapshot.topPositions)
                    }
                    if !snapshot.industries.isEmpty {
                        industryChart(snapshot.industries)
                    }
                    if !snapshot.funds.isEmpty {
                        fundDisclosureList(snapshot.funds)
                    }
                    if !snapshot.warnings.isEmpty {
                        warningsBlock(snapshot.warnings)
                    }
                }
            } else {
                IOSEmptyState(
                    title: "暂无穿透数据",
                    subtitle: "基金底层持仓穿透分析将在数据加载后生成。"
                )
            }
        }
    }

    private var subtitle: String {
        guard let snapshot else { return "等待数据" }
        return "底层证券覆盖 \(formatted(snapshot.disclosedSecurityCoveragePct))"
    }

    // MARK: 覆盖度指标

    private func coverageGrid(_ snapshot: PortfolioLookThroughSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: IOSDesign.spaceS) {
            IOSStatTile(title: "基金覆盖", value: "\(snapshot.coveredFundCount) / \(snapshot.expectedFundCount)")
            IOSStatTile(title: "基金数据覆盖", value: formatted(snapshot.fundDataCoveragePct))
            IOSStatTile(title: "底层证券覆盖", value: formatted(snapshot.disclosedSecurityCoveragePct))
            IOSStatTile(title: "未披露占比", value: formatted(snapshot.unknownPortfolioWeightPct))
        }
    }

    // MARK: 底层证券暴露 donut

    private func positionsDonut(_ positions: [PortfolioLookThroughPosition]) -> some View {
        let items = topPositionItems(positions)
        let total = items.reduce(0) { $0 + max(0, $1.weight) }
        return VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            Text("穿透后证券暴露")
                .font(IOSDesign.serifHeading(15))
                .foregroundStyle(IOSDesign.ink)
            Chart(items) { item in
                SectorMark(
                    angle: .value("份额", max(0, item.weight)),
                    innerRadius: .ratio(0.6),
                    angularInset: 1.2
                )
                .foregroundStyle(item.color)
            }
            .frame(height: 170)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    HStack(spacing: IOSDesign.spaceS) {
                        Circle().fill(item.color).frame(width: 8, height: 8)
                        Text(item.label).font(IOSDesign.sansBody(12)).foregroundStyle(IOSDesign.ink).lineLimit(1)
                        if item.kind == .bond {
                            IOSTintedBadge(text: "债", tone: .neutral)
                        }
                        Spacer()
                        Text(formatted(item.weight)).font(IOSDesign.monoNumber(12, weight: .medium)).foregroundStyle(IOSDesign.muted)
                    }
                }
                Text("合计 \(formatted(total))")
                    .font(IOSDesign.sansBody(11))
                    .foregroundStyle(IOSDesign.muted)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: 行业暴露饼图（对齐 macOS 的 donut + 图例）

    private func industryChart(_ industries: [PortfolioLookThroughIndustry]) -> some View {
        let items = topIndustryItems(industries)
        let total = items.reduce(0) { $0 + max(0, $1.weight) }
        return VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            Text("行业暴露（占组合）")
                .font(IOSDesign.serifHeading(15))
                .foregroundStyle(IOSDesign.ink)
            Chart(items) { item in
                SectorMark(
                    angle: .value("份额", max(0, item.weight)),
                    innerRadius: .ratio(0.6),
                    angularInset: 1.2
                )
                .foregroundStyle(item.color)
            }
            .frame(height: 170)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    HStack(spacing: IOSDesign.spaceS) {
                        Circle().fill(item.color).frame(width: 8, height: 8)
                        Text(item.label).font(IOSDesign.sansBody(12)).foregroundStyle(IOSDesign.ink).lineLimit(1)
                        Spacer()
                        Text(formatted(item.weight)).font(IOSDesign.monoNumber(12, weight: .medium)).foregroundStyle(IOSDesign.muted)
                    }
                }
                Text("合计 \(formatted(total))")
                    .font(IOSDesign.sansBody(11))
                    .foregroundStyle(IOSDesign.muted)
                    .padding(.top, 2)
            }
        }
    }

    /// 行业按权重降序取 Top 8,其余合并为「其他」。
    private func topIndustryItems(_ industries: [PortfolioLookThroughIndustry]) -> [IndustrySlice] {
        let sorted = industries.sorted { $0.portfolioWeightPct > $1.portfolioWeightPct }
        let shown = Array(sorted.prefix(8))
        let shownIDs = Set(shown.map(\.id))
        let otherWeight = sorted.filter { !shownIDs.contains($0.id) }.reduce(0) { $0 + max(0, $1.portfolioWeightPct) }
        var items = shown.enumerated().map { idx, ind in
            IndustrySlice(label: ind.name, weight: ind.portfolioWeightPct, color: AppPalette.chartColor(index: idx))
        }
        if otherWeight >= 0.5 {
            items.append(IndustrySlice(label: "其他", weight: otherWeight, color: IOSDesign.muted))
        }
        return items
    }

    // MARK: 基金披露表（卡片内导航行，点击 push 到完整列表页）

    private func fundDisclosureList(_ funds: [PortfolioFundLookThroughSummary]) -> some View {
        NavigationLink {
            IOSFundDisclosureListView(funds: funds)
        } label: {
            HStack(spacing: IOSDesign.spaceS) {
                Text("基金披露明细")
                    .font(IOSDesign.serifHeading(15))
                    .foregroundStyle(IOSDesign.ink)
                Text("\(funds.count) 只")
                    .font(IOSDesign.sansBody(12))
                    .foregroundStyle(IOSDesign.muted)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(IOSDesign.muted)
            }
            .contentShape(Rectangle())
            .padding(.vertical, IOSDesign.spaceS)
        }
        .buttonStyle(.plain)
    }

    // MARK: 警告

    private func warningsBlock(_ warnings: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(warnings, id: \.self) { w in
                HStack(alignment: .top, spacing: IOSDesign.spaceS) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(AppPalette.warning)
                    Text(w)
                        .font(IOSDesign.sansBody(11))
                        .foregroundStyle(IOSDesign.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(IOSDesign.spaceS)
        .background(AppPalette.warning.opacity(0.06), in: RoundedRectangle(cornerRadius: IOSDesign.radiusS))
    }

    // MARK: 辅助

    /// 按权重降序取 Top 9，其余合并为"其他"。
    private func topPositionItems(_ positions: [PortfolioLookThroughPosition]) -> [PositionSlice] {
        let sorted = positions.sorted { $0.portfolioWeightPct > $1.portfolioWeightPct }
        let shown = Array(sorted.prefix(9))
        let shownIDs = Set(shown.map(\.id))
        let otherWeight = sorted.filter { !shownIDs.contains($0.id) }.reduce(0) { $0 + max(0, $1.portfolioWeightPct) }
        var items = shown.enumerated().map { idx, p in
            PositionSlice(label: p.name, weight: p.portfolioWeightPct, kind: p.kind, color: AppPalette.chartColor(index: idx))
        }
        if otherWeight >= 0.5 {
            items.append(PositionSlice(label: "其他", weight: otherWeight, kind: .stock, color: IOSDesign.muted))
        }
        return items
    }

    private func formatted(_ pct: Double) -> String {
        String(format: "%.1f%%", pct)
    }

    private struct PositionSlice: Identifiable {
        let id = UUID()
        let label: String
        let weight: Double
        let kind: FundUnderlyingAssetKind
        let color: Color
    }

    private struct IndustrySlice: Identifiable {
        let id = UUID()
        let label: String
        let weight: Double
        let color: Color
    }
}
#endif
