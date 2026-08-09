#if os(iOS)
import SwiftUI
import Charts

// MARK: - iOS 持仓详情 Sheet
//
// 复用 Core 层 PersonalAssetDetailSummary.make(row:) 的跨平台计算,
// 用 iPhone 友好的 sheet 布局展示基金详情(估值/收益/待确认/计划/净值走势/AI观点)。

struct IOSPersonalAssetDetailSheet: View {
    let row: PersonalAssetAggregateRow
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingDeleteConfirm = false
    @State private var showingEdit = false
    @State private var editingTrade: PersonalPendingTrade?
    @State private var showingAddTrade = false
    @State private var editingPlan: PersonalInvestmentPlan?
    @State private var showingAddPlan = false
    @State private var showingValuationAlert = false
    // 净值走势
    @State private var pricePoints: [PersonalWatchlistDailyPoint] = []
    @State private var isLoadingPrice = false
    @State private var priceLoadError: String?

    private var summary: PersonalAssetDetailSummary {
        PersonalAssetDetailSummary.make(row: row)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    metricsSection
                    priceTrendSection
                    aiOpinionSection
                    attentionSection
                    pendingTradesSection
                    plansSection
                    valuationAlertEntry
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle(summary.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if row.holdingRow != nil {
                            Button {
                                showingEdit = true
                            } label: {
                                Label("编辑持仓", systemImage: "pencil")
                            }
                        }
                        Button(role: .destructive) {
                            showingDeleteConfirm = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog("确认删除该持仓？", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
                Button("删除全部(持仓+待确认+计划)", role: .destructive) {
                    model.deletePersonalAssetEntry(row, scope: .all)
                    dismiss()
                }
                if row.holdingRow != nil {
                    Button("仅删除持仓", role: .destructive) {
                        model.deletePersonalAssetEntry(row, scope: .holding)
                        dismiss()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除后不可恢复。可选择删除范围。")
            }
            .sheet(isPresented: $showingEdit) {
                IOSEditHoldingSheet(row: row)
            }
            .sheet(item: $editingTrade) { trade in
                IOSPendingTradeEditSheet(row: row, trade: trade)
            }
            .sheet(isPresented: $showingAddTrade) {
                IOSPendingTradeEditSheet(row: row, trade: nil)
            }
            .sheet(item: $editingPlan) { plan in
                IOSInvestmentPlanEditSheet(row: row, plan: plan)
            }
            .sheet(isPresented: $showingAddPlan) {
                IOSInvestmentPlanEditSheet(row: row, plan: nil)
            }
            .sheet(isPresented: $showingValuationAlert) {
                IOSValuationAlertSheet(row: row)
            }
            .task {
                await loadPriceHistory()
            }
        }
    }

    // MARK: - 净值走势加载

    private func loadPriceHistory() async {
        guard !isLoadingPrice else { return }
        // 构造 holding 用于查询（对齐 macOS PersonalAssetPriceTrendChart.historyHolding）
        let holding: UserPortfolioHolding?
        if let h = row.holdingRow?.holding ?? row.rawHolding ?? row.archivedHolding {
            holding = h
        } else if let code = row.fundCode, !code.isEmpty {
            holding = UserPortfolioHolding(
                fundCode: code,
                assetType: row.assetType,
                units: 1,
                costPrice: row.costPrice,
                displayName: row.fundName,
                stockMarket: row.detectedMarket,
                fundMarket: row.detectedFundMarket
            )
        } else {
            holding = nil
        }
        guard let holding else {
            priceLoadError = "缺少标的代码，无法加载走势"
            return
        }
        isLoadingPrice = true
        priceLoadError = nil
        defer { isLoadingPrice = false }
        do {
            let result = try await model.platformClient.fetchPersonalAssetPriceHistory(for: holding)
            pricePoints = result
            if result.count < 2 {
                priceLoadError = "拉到的数据点不足（\(result.count) 条）"
            }
        } catch {
            pricePoints = []
            priceLoadError = error.localizedDescription
        }
    }

    // MARK: - 头部

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(summary.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                if let code = summary.codeText {
                    Text(code)
                        .font(.system(size: 13))
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                if let market = summary.marketText {
                    IOSTintedBadge(text: market, tone: .neutral)
                }
                if !summary.statusText.isEmpty {
                    Text(summary.statusText)
                        .font(.system(size: 13))
                        .foregroundStyle(AppPalette.muted)
                }
            }
            Text(summary.effectiveAmountText)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(IOSDesign.accent)
                .padding(.top, 4)
        }
    }

    // MARK: - 指标

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("核心指标")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppPalette.muted)
            // 按行手动 HStack：同一行两列强制等高（LazyVGrid 不保证同行等高）
            metricRows
        }
    }

    private var metricRows: some View {
        let metrics = summary.metrics
        // 不足偶数个时补一个占位，保证最后一行成对
        var pairs: [[PersonalAssetDetailMetric]] = []
        var i = 0
        while i < metrics.count {
            let next = min(i + 2, metrics.count)
            pairs.append(Array(metrics[i..<next]))
            i = next
        }
        return VStack(spacing: 10) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                HStack(spacing: 10) {
                    ForEach(Array(pair.enumerated()), id: \.offset) { _, metric in
                        metricTile(metric)
                    }
                    if pair.count == 1 {
                        // 单数最后一个，补一个透明占位撑住对齐
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func metricTile(_ metric: PersonalAssetDetailMetric) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metric.title)
                .font(.system(size: 12))
                .foregroundStyle(AppPalette.muted)
            Text(metric.value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(metricColor(metric.tone))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            // detail 始终占位（空串也保留一行），保证有无 detail 的 tile 等高
            Text(metric.detail ?? "")
                .font(.system(size: 11))
                .foregroundStyle(AppPalette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .opacity(metric.detail?.isEmpty == false ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
    }

    // MARK: - 净值/价格走势

    private var priceTrendSection: some View {
        let costSubtitle: String = {
            var parts = ["\(pricePoints.count) 个数据点"]
            if let cp = row.costPrice, cp > 0 {
                parts.append("成本 \(String(format: "%.4f", cp))")
            }
            return parts.joined(separator: " · ")
        }()
        return IOSSectionCard(
            title: row.usesMarketTradeColumns ? "收盘价走势" : "单位净值走势",
            subtitle: costSubtitle,
            icon: "chart.line.uptrend.xyaxis"
        ) {
            if isLoadingPrice && pricePoints.isEmpty {
                HStack(spacing: IOSDesign.spaceS) {
                    ProgressView().controlSize(.small)
                    Text("加载走势中…").font(IOSDesign.sansBody(13)).foregroundStyle(IOSDesign.muted)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, IOSDesign.spaceL)
            } else if pricePoints.count < 2 {
                VStack(spacing: IOSDesign.spaceS) {
                    Text(priceLoadError ?? "暂无足够走势数据")
                        .font(IOSDesign.sansBody(13))
                        .foregroundStyle(IOSDesign.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        pricePoints = []
                        Task { await loadPriceHistory() }
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(IOSDesign.sansBody(13, weight: .medium))
                            .foregroundStyle(IOSDesign.accent)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, IOSDesign.spaceL)
            } else {
                IOSPriceTrendChart(points: pricePoints, costPrice: row.costPrice)
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
            }
        }
    }

    // MARK: - AI 观点（匹配趋势报告里的单标的观点）

    @ViewBuilder
    private var aiOpinionSection: some View {
        if let assetView = matchedAssetTrend {
            IOSSectionCard(title: "AI 观点", subtitle: assetView.sector, icon: "sparkles") {
                VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
                    if !assetView.impactText.isEmpty {
                        IOSTintedBadge(text: assetView.impactText, tone: .neutral)
                    }
                    // 周期研判
                    if !assetView.horizons.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(assetView.horizons, id: \.horizon) { horizon in
                                HStack(spacing: IOSDesign.spaceS) {
                                    Text(horizonLabel(horizon.horizon)).font(IOSDesign.sansBody(12, weight: .medium)).foregroundStyle(IOSDesign.ink)
                                    Spacer()
                                    Text(directionLabel(horizon.direction))
                                        .font(IOSDesign.sansBody(12, weight: .semibold))
                                        .foregroundStyle(directionColor(horizon.direction))
                                }
                            }
                        }
                    }
                    if !assetView.rationale.isEmpty {
                        Text(assetView.rationale)
                            .font(IOSDesign.sansBody(13))
                            .foregroundStyle(IOSDesign.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !assetView.counterSignals.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("反向信号").font(IOSDesign.sansBody(11, weight: .semibold)).foregroundStyle(AppPalette.warning)
                            ForEach(assetView.counterSignals, id: \.self) { signal in
                                Text("· \(signal)").font(IOSDesign.sansBody(11)).foregroundStyle(IOSDesign.muted)
                            }
                        }
                    }
                }
            }
        }
    }

    /// 从趋势报告里按 code/name 匹配当前标的的 AI 观点
    private var matchedAssetTrend: TrendAssetView? {
        guard let trends = model.trendReport?.assetTrends, !trends.isEmpty else { return nil }
        // 优先按代码匹配
        if let code = row.fundCode, !code.isEmpty {
            let lower = code.lowercased()
            if let m = trends.first(where: { ($0.code ?? "").lowercased() == lower }) {
                return m
            }
        }
        // 退而按名称包含匹配
        let name = row.fundName
        return trends.first(where: { $0.name.contains(name) || name.contains($0.name) })
    }

    private func horizonLabel(_ h: TrendHorizon) -> String {
        switch h {
        case .short: return "短期"
        case .medium: return "中期"
        case .long: return "长期"
        }
    }

    private func directionLabel(_ d: TrendDirection) -> String {
        switch d {
        case .bullish: return "看多"
        case .neutralPositive: return "偏多"
        case .neutral: return "中性"
        case .neutralNegative: return "偏空"
        case .bearish: return "看空"
        case .uncertain: return "不确定"
        }
    }

    private func directionColor(_ d: TrendDirection) -> Color {
        switch d {
        case .bullish, .neutralPositive: return AppPalette.marketGain
        case .bearish, .neutralNegative: return AppPalette.marketLoss
        case .neutral, .uncertain: return AppPalette.muted
        }
    }

    // MARK: - 关注项(计划/待确认提醒)

    private var attentionSection: some View {
        Group {
            if !summary.attentionItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("持仓提醒")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppPalette.muted)
                    ForEach(Array(summary.attentionItems.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(AppPalette.warning)
                                .padding(.top, 6)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(AppPalette.ink)
                                if !item.detail.isEmpty {
                                    Text(item.detail)
                                        .font(.system(size: 12))
                                        .foregroundStyle(AppPalette.muted)
                                }
                            }
                            Spacer()
                            if !item.metric.isEmpty {
                                Text(item.metric)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(AppPalette.warning)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 待确认交易

    private var pendingTradesSection: some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            HStack {
                Text("待确认交易").font(IOSDesign.serifHeading(16)).foregroundStyle(IOSDesign.ink)
                Spacer()
                Button { showingAddTrade = true } label: {
                    Image(systemName: "plus.circle.fill").foregroundStyle(IOSDesign.accent)
                }
            }
            if row.pendingTrades.isEmpty {
                Text("暂无待确认交易").font(IOSDesign.sansBody(13)).foregroundStyle(IOSDesign.muted)
            } else {
                ForEach(row.pendingTrades) { trade in
                    tradeRow(trade)
                }
            }
        }
    }

    private func tradeRow(_ trade: PersonalPendingTrade) -> some View {
        Button { editingTrade = trade } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(trade.displayTitle).font(IOSDesign.sansBody(14, weight: .medium)).foregroundStyle(IOSDesign.ink).lineLimit(1)
                    Text("\(String(trade.occurredAt.prefix(10))) · \(trade.status)").font(IOSDesign.sansBody(11)).foregroundStyle(IOSDesign.muted)
                }
                Spacer()
                Text(trade.amountText).font(IOSDesign.monoNumber(13)).foregroundStyle(IOSDesign.ink)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { model.deletePendingTrade(trade.id) } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: - 投资计划

    private var plansSection: some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            HStack {
                Text("投资计划").font(IOSDesign.serifHeading(16)).foregroundStyle(IOSDesign.ink)
                Spacer()
                Button { showingAddPlan = true } label: {
                    Image(systemName: "plus.circle.fill").foregroundStyle(IOSDesign.accent)
                }
            }
            if row.plans.isEmpty {
                Text("暂无投资计划").font(IOSDesign.sansBody(13)).foregroundStyle(IOSDesign.muted)
            } else {
                ForEach(row.plans) { plan in
                    planRow(plan)
                }
            }
        }
    }

    private func planRow(_ plan: PersonalInvestmentPlan) -> some View {
        Button { editingPlan = plan } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(plan.planTypeLabel) · \(plan.scheduleText)").font(IOSDesign.sansBody(14, weight: .medium)).foregroundStyle(IOSDesign.ink).lineLimit(1)
                    Text("\(plan.status) · 每期 \(plan.amountText)").font(IOSDesign.sansBody(11)).foregroundStyle(IOSDesign.muted)
                }
                Spacer()
                if let next = plan.nextExecutionDate.isEmpty ? nil : String(plan.nextExecutionDate.prefix(10)) {
                    Text("下次 \(next)").font(IOSDesign.sansBody(11)).foregroundStyle(IOSDesign.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { model.deleteInvestmentPlan(plan.id) } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: - 估值告警入口

    private var valuationAlertEntry: some View {
        Button { showingValuationAlert = true } label: {
            HStack {
                Image(systemName: "bell.badge").foregroundStyle(IOSDesign.accent)
                Text("估值告警规则").font(IOSDesign.sansBody(14, weight: .medium)).foregroundStyle(IOSDesign.ink)
                Spacer()
                let count = (row.fundCode.flatMap { model.portfolioValuationAlertProfile(for: $0).rules.count }) ?? 0
                Text(count > 0 ? "\(count) 条" : "未设置").font(IOSDesign.sansBody(12)).foregroundStyle(IOSDesign.muted)
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(IOSDesign.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 辅助

    private func metricColor(_ tone: PersonalAssetDetailTone) -> Color {
        switch tone {
        case .neutral: return AppPalette.ink
        case .marketGain: return AppPalette.marketGain
        case .marketLoss: return AppPalette.marketLoss
        case .warning: return AppPalette.warning
        case .info: return AppPalette.info
        case .brand: return AppPalette.brand
        case .muted: return AppPalette.muted
        }
    }
}
#endif
