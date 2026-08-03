#if os(iOS)
import SwiftUI
import Charts

// MARK: - iOS 平台重型可视化
//
// 策略雷达 / 月度调仓图表 / 持仓饼图。数据全部来自 model 已聚合的计算属性,
// 无需额外 fetch。复用 Core 层 StrategyRadarSummary / PlatformMonthSummary /
// HoldingItemPayload + PlatformHoldingAllocationBuilder。

// MARK: - 策略雷达

struct IOSStrategyRadarPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let summary = model.strategyRadarSummary
        return IOSSectionCard(title: "策略雷达", subtitle: summary.headline, icon: "dot.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: IOSDesign.spaceS) {
                    ForEach(summary.items, id: \.dimension) { item in
                        radarTile(item)
                    }
                }
            }
        }
    }

    private func radarTile(_ item: StrategyRadarItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.title).font(IOSDesign.sansBody(13, weight: .medium)).foregroundStyle(IOSDesign.ink)
                Spacer()
                Text("\(item.score)").font(IOSDesign.monoNumber(14)).foregroundStyle(scoreColor(item.score))
            }
            Text(item.metric).font(IOSDesign.monoNumber(13)).foregroundStyle(IOSDesign.muted)
            ProgressView(value: Double(item.score), total: 100)
                .tint(scoreColor(item.score))
            Text(item.detail).font(IOSDesign.sansBody(11)).foregroundStyle(IOSDesign.muted).lineLimit(2)
        }
        .padding(IOSDesign.spaceS + 2)
        .background(IOSDesign.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: IOSDesign.radiusS))
    }

    private func scoreColor(_ score: Int) -> Color {
        if score >= 70 { return AppPalette.marketLoss }   // 高分=进攻,红
        if score >= 40 { return AppPalette.warning }
        return IOSDesign.muted
    }
}

// MARK: - 月度调仓图表

struct IOSPlatformMonthlyChart: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedMonth: PlatformMonthSummary?

    var body: some View {
        let months = model.monthlyPlatformSummary
        return IOSSectionCard(title: "月度调仓", subtitle: "近 \(months.count) 个月", icon: "chart.bar.fill") {
            if months.isEmpty {
                Text("暂无月度数据").font(IOSDesign.sansBody(13)).foregroundStyle(IOSDesign.muted)
            } else {
                legend
                chart(months)
                statsBar(months)
            }
        }
    }

    /// 统计/详情条(固定高度):未选中显示累计汇总,选中显示该月明细。
    @ViewBuilder
    private func statsBar(_ months: [PlatformMonthSummary]) -> some View {
        // 仅选中时显示该月详情(未选中时空,不显示冗余汇总/提示)。
        if let sel = selectedMonth {
            HStack(spacing: IOSDesign.spaceM) {
                Text("\(sel.month)").font(IOSDesign.sansBody(13, weight: .semibold)).foregroundStyle(IOSDesign.ink)
                Spacer()
                Text("买 \(sel.buyCount)").font(IOSDesign.monoNumber(12)).foregroundStyle(AppPalette.marketLoss)
                Text("卖 \(sel.sellCount)").font(IOSDesign.monoNumber(12)).foregroundStyle(AppPalette.marketGain)
                Text("\(sel.activeDays) 天").font(IOSDesign.monoNumber(12)).foregroundStyle(IOSDesign.muted)
            }
            .padding(.top, IOSDesign.spaceS)
        }
    }

    private var legend: some View {
        HStack(spacing: IOSDesign.spaceM) {
            HStack(spacing: 4) {
                Circle().fill(AppPalette.marketLoss.opacity(0.85)).frame(width: 8, height: 8)
                Text("买入").font(IOSDesign.sansBody(11)).foregroundStyle(IOSDesign.muted)
            }
            HStack(spacing: 4) {
                Circle().fill(AppPalette.marketGain.opacity(0.85)).frame(width: 8, height: 8)
                Text("卖出").font(IOSDesign.sansBody(11)).foregroundStyle(IOSDesign.muted)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func chart(_ months: [PlatformMonthSummary]) -> some View {
        // 月数多时:水平滚动,每柱给足宽度,底部标尺不再挤;月数少时直接显示。
        if months.count > 6 {
            ScrollView(.horizontal, showsIndicators: false) {
                chartBody(months)
                    .frame(width: CGFloat(months.count) * 56)
            }
        } else {
            chartBody(months)
        }
    }

    private func chartBody(_ months: [PlatformMonthSummary]) -> some View {
        let maxCount = max(months.map(\.totalCount).max() ?? 1, 1)
        // 扁平数据:买入/卖出各自一条记录,Charts 用 foregroundStyle(by:) 自动并排分组
        let rows = months.flatMap { m -> [(month: String, kind: String, value: Int, isSel: Bool)] in
            let sel = selectedMonth?.month == m.month
            return [
                (monthLabel(m.month), "买入", m.buyCount, sel),
                (monthLabel(m.month), "卖出", m.sellCount, sel)
            ]
        }
        return Chart(rows, id: \.month) { r in
            BarMark(
                x: .value("月", r.month),
                y: .value("笔", r.value),
                width: .fixed(10)   // 固定柱宽,月份少时也不会变粗
            )
            .foregroundStyle(by: .value("类型", r.kind))
            .opacity(r.isSel ? 1.0 : (selectedMonth == nil ? 0.9 : 0.35))
        }
        .chartForegroundStyleScale([
            "买入": AppPalette.marketLoss,
            "卖出": AppPalette.marketGain
        ])
        .chartXAxis {
            AxisMarks(values: .automatic) { value in
                AxisValueLabel {
                    if let s = value.as(String.self) { Text(s).font(.system(size: 9)) }
                }
                AxisGridLine().foregroundStyle(IOSDesign.ink.opacity(0.08))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel().font(.system(size: 10))
                AxisGridLine().foregroundStyle(IOSDesign.ink.opacity(0.08))
            }
        }
        .chartYScale(domain: 0...(maxCount + 1))
        .chartLegend(.hidden) // 用自定义 legend
        .frame(height: 180)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        // plotAreaFrame 给出绘图区在 geo 中的 frame(含 Y 轴偏移)
                        let plotFrame = geo[proxy.plotAreaFrame]
                        let xInPlot = location.x - plotFrame.origin.x
                        guard xInPlot >= 0, xInPlot <= plotFrame.width else { return }
                        if let raw = proxy.value(atX: xInPlot, as: String.self),
                           let m = months.first(where: { monthLabel($0.month) == raw }) {
                            selectedMonth = (selectedMonth?.month == m.month) ? nil : m
                        }
                    }
            }
        }
    }

    private func monthLabel(_ month: String) -> String {
        // "2024-03" -> "24-03"
        guard month.count >= 7 else { return month }
        return String(month.dropFirst(2))
    }
}

// MARK: - 持仓饼图

struct IOSPlatformHoldingsPie: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let holdings = model.platformHoldings
        return IOSSectionCard(title: "当前持仓", subtitle: "\(holdings.count) 只", icon: "chart.pie.fill") {
            if holdings.isEmpty {
                Text("暂无持仓数据").font(IOSDesign.sansBody(13)).foregroundStyle(IOSDesign.muted)
            } else {
                VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
                    allocationChart("资产大类", holdings: holdings, dimension: .largeClass)
                    allocationChart("资产类型", holdings: holdings, dimension: .strategyType)
                }
            }
        }
    }

    enum AllocationDimension {
        case largeClass, strategyType
    }

    private func allocationChart(_ title: String, holdings: [HoldingItemPayload], dimension: AllocationDimension) -> some View {
        let slices = buildSlices(holdings, dimension: dimension)
        return VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            Text(title).font(IOSDesign.serifHeading(15)).foregroundStyle(IOSDesign.ink)
            if slices.isEmpty {
                Text("无数据").font(IOSDesign.sansBody(12)).foregroundStyle(IOSDesign.muted)
            } else {
                Chart(slices) { slice in
                    SectorMark(
                        angle: .value("份额", slice.value),
                        innerRadius: .ratio(0.58),
                        angularInset: 1.2
                    )
                    .foregroundStyle(slice.color)
                }
                .frame(height: 160)
                legend(slices)
            }
        }
    }

    private struct Slice: Identifiable {
        let label: String
        let value: Double
        let ratio: Double
        let count: Int
        let color: Color
        var id: String { label }
    }

    private func buildSlices(_ holdings: [HoldingItemPayload], dimension: AllocationDimension) -> [Slice] {
        // 只计 currentUnits > 0 的持仓
        let active = holdings.filter { ($0.currentUnits ?? 0) > 0 }
        var groups: [String: (value: Double, count: Int)] = [:]
        for h in active {
            let label: String
            switch dimension {
            case .largeClass:
                let lc = h.largeClass?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                label = lc.isEmpty ? "未分类" : lc
            case .strategyType:
                label = assetTypeLabel(h)
            }
            let v = Double(h.currentUnits ?? 0)
            let existing = groups[label] ?? (0, 0)
            groups[label] = (existing.value + v, existing.count + 1)
        }
        let total = groups.values.reduce(0) { $0 + $1.value }
        guard total > 0 else { return [] }
        return groups
            .map { (label, val) in
                Slice(label: label, value: val.value, ratio: val.value / total,
                      count: val.count, color: chartColor(label))
            }
            .sorted { $0.value > $1.value }
    }

    private func assetTypeLabel(_ h: HoldingItemPayload) -> String {
        let text = ((h.strategyType ?? "") + " " + (h.label ?? "") + " " + (h.fundName ?? "")).lowercased()
        if text.contains("债") { return "债券" }
        if text.contains("货币") || text.contains("现金") { return "现金及货币" }
        if text.contains("商品") || text.contains("金") || text.contains("油") { return "商品" }
        if text.contains("另类") || text.contains("reit") { return "另类资产" }
        if text.contains("股") { return "股票" }
        return "其他"
    }

    private func legend(_ slices: [Slice]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(slices) { s in
                HStack(spacing: 6) {
                    Circle().fill(s.color).frame(width: 8, height: 8)
                    Text(s.label).font(IOSDesign.sansBody(12, weight: .medium)).foregroundStyle(IOSDesign.ink)
                    Spacer()
                    Text("\(s.count)只 · \(String(format: "%.0f%%", s.ratio * 100))")
                        .font(IOSDesign.monoNumber(11))
                        .foregroundStyle(IOSDesign.muted)
                }
            }
        }
    }

    private func chartColor(_ label: String) -> Color {
        let palette: [Color] = [IOSDesign.accent, AppPalette.marketGain, AppPalette.marketLoss,
                                AppPalette.warning, AppPalette.info, IOSDesign.muted]
        let labels = ["未分类", "债券", "现金及货币", "商品", "另类资产", "股票", "其他", "权益"]
        if let idx = labels.firstIndex(of: label) {
            return palette[idx % palette.count]
        }
        return palette[abs(label.hashValue) % palette.count]
    }
}
#endif
