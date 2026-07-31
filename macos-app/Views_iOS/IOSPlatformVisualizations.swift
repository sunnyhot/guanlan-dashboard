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
        return IOSSectionCard(title: "月度调仓", subtitle: "近 \(months.count) 个月 · 点柱看详情", icon: "chart.bar.fill") {
            if months.isEmpty {
                Text("暂无月度数据").font(IOSDesign.sansBody(13)).foregroundStyle(IOSDesign.muted)
            } else {
                legend
                summaryStats(months)
                chart(months)
            }
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

    private func summaryStats(_ months: [PlatformMonthSummary]) -> some View {
        let total = months.reduce(0) { $0 + $1.totalCount }
        let buys = months.reduce(0) { $0 + $1.buyCount }
        let sells = months.reduce(0) { $0 + $1.sellCount }
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: IOSDesign.spaceS) {
            statTile("累计", "\(total)")
            statTile("买入", "\(buys)", tone: AppPalette.marketLoss)
            statTile("卖出", "\(sells)", tone: AppPalette.marketGain)
        }
    }

    private func statTile(_ title: String, _ value: String, tone: Color = IOSDesign.ink) -> some View {
        VStack(spacing: 2) {
            Text(value).font(IOSDesign.monoNumber(16)).foregroundStyle(tone)
            Text(title).font(IOSDesign.sansBody(11)).foregroundStyle(IOSDesign.muted)
        }
        .frame(maxWidth: .infinity)
    }

    private func chart(_ months: [PlatformMonthSummary]) -> some View {
        let maxCount = max(months.map(\.totalCount).max() ?? 1, 1)
        return Chart(months, content: chartMarks)
            .chartXAxis {
                AxisMarks(values: xAxisValues(months)) { value in
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
            .frame(height: 200)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            handleTap(location, proxy: proxy, geo: geo, months: months)
                        }
                }
            }
    }

    @ChartContentBuilder
    private func chartMarks(_ m: PlatformMonthSummary) -> some ChartContent {
        BarMark(
            x: .value("月", monthLabel(m.month)),
            y: .value("买入", m.buyCount)
        )
        .foregroundStyle(AppPalette.marketLoss.opacity(0.85))

        BarMark(
            x: .value("月", monthLabel(m.month)),
            y: .value("卖出", m.sellCount)
        )
        .foregroundStyle(AppPalette.marketGain.opacity(0.85))
    }

    private func handleTap(_ location: CGPoint, proxy: ChartProxy, geo: GeometryProxy, months: [PlatformMonthSummary]) {
        guard let plotFrame = proxy.plotFrame else { return }
        let origin = geo[plotFrame].origin
        let x = location.x - origin.x
        if let raw = proxy.value(atX: x, as: String.self),
           let m = months.first(where: { monthLabel($0.month) == raw }) {
            selectedMonth = (selectedMonth?.month == m.month) ? nil : m
        } else {
            selectedMonth = nil
        }
    }

    /// X 轴标签值:月数多时抽稀,避免挤成一团。
    private func xAxisValues(_ months: [PlatformMonthSummary]) -> [String] {
        let labels = months.map { monthLabel($0.month) }
        guard labels.count > 6 else { return labels }
        let step = max(1, labels.count / 6)
        return stride(from: 0, to: labels.count, by: step).map { labels[$0] }
    }

    private func tooltip(_ m: PlatformMonthSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(m.month).font(IOSDesign.sansBody(12, weight: .semibold)).foregroundStyle(IOSDesign.ink)
            Text("买入 \(m.buyCount) · 卖出 \(m.sellCount)").font(IOSDesign.sansBody(11)).foregroundStyle(IOSDesign.muted)
            Text("共 \(m.totalCount) 笔 · 活跃 \(m.activeDays) 天").font(IOSDesign.sansBody(11)).foregroundStyle(IOSDesign.muted)
        }
        .padding(IOSDesign.spaceS)
        .background(IOSDesign.card, in: RoundedRectangle(cornerRadius: IOSDesign.radiusS))
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
