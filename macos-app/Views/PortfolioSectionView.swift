import Charts
import SwiftUI

// MARK: - Personal Portfolio

private enum PortfolioContentTab: String, CaseIterable, Identifiable {
    case analysis = "组合分析"
    case assets = "资产明细"
    case watchlist = "关注"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .analysis:
            return "chart.pie"
        case .assets:
            return "tablecells"
        case .watchlist:
            return "star"
        }
    }
}

struct PortfolioSectionView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedTab: PortfolioContentTab = .analysis
    @State private var isPresentingAddPendingTrade = false
    @State private var editingPendingTrade: PersonalPendingTrade?
    @State private var deletingPendingTrade: PersonalPendingTrade?
    @State private var isPresentingAddInvestmentPlan = false

    private var totalProfitAmount: Double? {
        model.userPortfolioSnapshot?.totalProfitAmount
    }

    private var totalProfitPct: Double? {
        model.userPortfolioSnapshot?.totalProfitPct
    }

    private var totalProfitTint: Color {
        AppPalette.marketTint(for: totalProfitAmount)
    }

    private var portfolioSummaryWideColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 180), spacing: 12, alignment: .top), count: 6)
    }

    private var portfolioSummaryMediumColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 180), spacing: 12, alignment: .top), count: 3)
    }

    private var portfolioSummaryCompactColumns: [GridItem] {
        [GridItem(.flexible(minimum: 180), spacing: 12, alignment: .top)]
    }

    var body: some View {
        VStack(spacing: 0) {
            portfolioTabBar

            ScrollView(.vertical, showsIndicators: false) {
                selectedTabContent
                    .padding(14)
            }
        }
        .sheet(isPresented: $isPresentingAddPendingTrade) {
            PersonalPendingTradeEditSheet()
        }
        .sheet(item: $editingPendingTrade) { trade in
            PersonalPendingTradeEditSheet(trade: trade)
        }
        .sheet(isPresented: $isPresentingAddInvestmentPlan) {
            PersonalInvestmentPlanAddSheet()
        }
        .alert("删除买入中记录？", isPresented: deletePendingConfirmationBinding) {
            Button("删除", role: .destructive) {
                if let deletingPendingTrade {
                    model.deletePendingTrade(deletingPendingTrade.id)
                }
                deletingPendingTrade = nil
            }
            Button("取消", role: .cancel) {
                deletingPendingTrade = nil
            }
        } message: {
            Text(deletePendingConfirmationMessage)
        }
    }

    private var portfolioTabBar: some View {
        ModuleTabBar(
            items: PortfolioContentTab.allCases,
            selection: $selectedTab,
            title: { $0.rawValue },
            systemImage: { $0.systemImage }
        )
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab {
        case .analysis:
            portfolioAnalysisContent
        case .assets:
            personalAssetsContent
        case .watchlist:
            PersonalWatchlistPanel()
        }
    }

    @ViewBuilder
    private var portfolioAnalysisContent: some View {
        if hasAnyPersonalData {
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    LazyVGrid(columns: portfolioSummaryWideColumns, alignment: .leading, spacing: 12) {
                        portfolioSummaryMetricCards
                    }

                    LazyVGrid(columns: portfolioSummaryMediumColumns, alignment: .leading, spacing: 12) {
                        portfolioSummaryMetricCards
                    }

                    LazyVGrid(columns: portfolioSummaryCompactColumns, alignment: .leading, spacing: 12) {
                        portfolioSummaryMetricCards
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        statusLineContent
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        statusLineContent
                    }
                }
                .font(AppPalette.appFont(.subheadline))
                .foregroundStyle(AppPalette.muted)

                PortfolioAllocationPanel()
                PortfolioDiagnosticsPanel(summary: model.portfolioDiagnosticsSummary)
                ProfitAttributionPanel(summary: model.profitAttributionSummary)
            }
        } else {
            PersonalPortfolioEmptyState()
        }
    }

    private var personalAssetsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionCard(title: "资产全貌总表", subtitle: "把「已持有 + 待确认 + 计划档案」聚合到同一行", icon: "tablecells", trailing: {
                PersonalAssetAddButtons()
            }) {
                PersonalAssetBrowser(rows: model.personalAssetRows, trendReport: model.trendReport)
            }

            pendingTradesSection
            investmentPlansSection
        }
    }

    private var pendingTradesSection: some View {
        SectionCard(title: "买入中", subtitle: "待确认交易单独展示，不并入已成交持仓收益", icon: "clock.badge.exclamationmark", trailing: {
            Spacer()
            Button {
                isPresentingAddPendingTrade = true
            } label: {
                Label("添加买入中", systemImage: "plus.circle")
            }
            .buttonStyle(.appSecondary)
            .controlSize(.small)
        }) {
            if let summary = model.pendingTradeSummary, !model.pendingTrades.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                        StatChip(title: "待确认金额", value: currencyText(summary.totalCashAmount))
                        StatChip(title: "现金单", value: "\(summary.cashTradeCount)")
                        if summary.unitTradeCount > 0 {
                            StatChip(title: "份额单", value: "\(summary.unitTradeCount)")
                        }
                    }

                    VStack(spacing: 10) {
                        ForEach(model.pendingTrades) { trade in
                            PendingTradeCard(
                                trade: trade,
                                onEdit: { editingPendingTrade = trade },
                                onDelete: { deletingPendingTrade = trade }
                            )
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("还没有买入中记录。可以直接手动添加待确认买入、定投或转换。")
                        .font(AppPalette.appFont(.body))
                        .foregroundStyle(AppPalette.muted)
                    Button {
                        isPresentingAddPendingTrade = true
                    } label: {
                        Label("添加买入中", systemImage: "plus.circle")
                    }
                    .buttonStyle(.appPrimary)
                    .tint(AppPalette.warning)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
            }
        }
    }

    private var investmentPlansSection: some View {
        SectionCard(title: "计划档案", subtitle: "按进行中、已暂停、已终止完整归档", icon: "calendar.badge.clock", trailing: {
            Spacer()
            Button {
                isPresentingAddInvestmentPlan = true
            } label: {
                Label("添加计划", systemImage: "plus.circle")
            }
            .buttonStyle(.appSecondary)
            .controlSize(.small)
            .keyboardShortcut("n", modifiers: .command)
        }) {
            if let summary = model.investmentPlanSummary, !model.investmentPlans.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                        StatChip(title: "累计投入", value: currencyText(summary.totalCumulativeInvestedAmount))
                        StatChip(title: "最近执行", value: summary.nextExecutionDate ?? "—")
                        StatChip(title: "计划状态", value: "进行中 \(summary.activePlanCount) · 暂停 \(summary.pausedPlanCount) · 终止 \(summary.endedPlanCount) · 总数 \(summary.planCount)")
                    }

                    if !model.activeInvestmentPlans.isEmpty {
                        PlanArchiveGroup(title: "进行中", tint: AppPalette.positive, plans: model.activeInvestmentPlans)
                    }

                    if !model.pausedInvestmentPlans.isEmpty {
                        PlanArchiveGroup(title: "已暂停", tint: AppPalette.warning, plans: model.pausedInvestmentPlans)
                    }

                    if !model.endedInvestmentPlans.isEmpty {
                        PlanArchiveGroup(title: "已终止", tint: AppPalette.muted, plans: model.endedInvestmentPlans)
                    }

                    if model.pausedInvestmentPlans.isEmpty && model.endedInvestmentPlans.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("当前还没有已暂停或已终止的计划明细。")
                                .font(AppPalette.appFont(.subheadline, weight: .medium))
                                .foregroundStyle(AppPalette.muted)
                            Text("把计划状态改成「已暂停」或「已终止」后，这里会自动归档。")
                                .font(AppPalette.appFont(.footnote))
                                .foregroundStyle(AppPalette.muted)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("还没有定投计划记录。可以直接手动添加计划档案。")
                        .font(AppPalette.appFont(.body))
                        .foregroundStyle(AppPalette.muted)
                    Button {
                        isPresentingAddInvestmentPlan = true
                    } label: {
                        Label("添加计划", systemImage: "plus.circle")
                    }
                    .buttonStyle(.appPrimary)
                    .tint(AppPalette.info)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
            }
        }
    }

    @ViewBuilder
    private var portfolioSummaryMetricCards: some View {
        let dailyChange = model.userPortfolioSnapshot?.dailyChangeSummary
        let dailyChangeTitle = model.userPortfolioSnapshot?.dailyChangeTitle ?? "今日涨跌"
        let dailyChangeTint = AppPalette.marketTint(for: dailyChange?.amount)

        MetricCard(
            title: "总持仓",
            value: model.personalAssetSummary.map { currencyText($0.totalEffectiveHoldingAmount) } ?? "—",
            subtitle: model.personalAssetSummary.map {
                "已持有 \(currencyText($0.totalMarketValue)) + 待确认 \(currencyText($0.totalPendingCashAmount)) + 下次计划 \(currencyText($0.totalEstimatedNextPlanAmount))"
            } ?? "自动聚合你的已持有、买入中和计划档案",
            icon: "yensign.circle",
            accent: AppPalette.brand
        )
        MetricCard(
            title: "总收益",
            value: signedCurrencyText(totalProfitAmount),
            subtitle: "收益率 \(percentOptional(totalProfitPct))",
            icon: "plusminus.circle",
            accent: totalProfitTint,
            valueTint: totalProfitTint
        )
        MetricCard(
            title: dailyChangeTitle,
            value: dailyChangeCurrencyText(dailyChange?.amount),
            subtitle: "\(dailyChangeTitle)率 \(dailyChangePercentText(dailyChange?.pct))",
            icon: "waveform.path.ecg",
            accent: dailyChangeTint,
            valueTint: dailyChangeTint
        )
        MetricCard(
            title: "待确认金额",
            value: model.personalAssetSummary.map { currencyText($0.totalPendingCashAmount) } ?? "—",
            subtitle: model.pendingTradeSummary.map { "\($0.actionCount) 笔交易进行中" } ?? "暂无待确认交易",
            icon: "clock.badge.exclamationmark",
            accent: AppPalette.warning
        )
        MetricCard(
            title: "计划档案",
            value: model.investmentPlanSummary.map { "\($0.activePlanCount) / \($0.pausedPlanCount) / \($0.endedPlanCount)" } ?? "—",
            subtitle: model.investmentPlanSummary.map { "进行中 / 暂停 / 终止 · 共 \($0.planCount)" } ?? "支持完整计划档案",
            icon: "calendar.badge.clock",
            accent: AppPalette.info
        )
        MetricCard(
            title: "覆盖标的",
            value: model.personalAssetSummary.map { "\($0.fundCount)" } ?? "0",
            subtitle: model.personalAssetSummary.map { "持有 \($0.holdingFundCount) · 待确认 \($0.pendingFundCount) · 有计划 \($0.activePlanFundCount)" } ?? "支持手动录入与维护",
            icon: "square.grid.3x2",
            accent: AppPalette.accentWarm
        )
    }

    @ViewBuilder
    private var statusLineContent: some View {
        Text(model.portfolioAutoRefreshStatusText)
        if let latestTime = model.pendingTradeSummary?.latestTime {
            Text("待确认最新：\(latestTime)")
        }
        if let nextDate = model.investmentPlanSummary?.nextExecutionDate {
            Text("下次定投：\(nextDate)")
        }
    }

    private var hasAnyPersonalData: Bool {
        model.hasAnyPortfolioRecords || model.hasPendingTrades || model.hasInvestmentPlans
    }

    private var deletePendingConfirmationBinding: Binding<Bool> {
        Binding(
            get: { deletingPendingTrade != nil },
            set: { isPresented in
                if !isPresented {
                    deletingPendingTrade = nil
                }
            }
        )
    }

    private var deletePendingConfirmationMessage: String {
        guard let deletingPendingTrade else { return "" }
        return "会从本地保存的数据中删除 \(deletingPendingTrade.displayTitle) 的这条买入中记录。"
    }
}

private extension PortfolioDiagnosticLevel {
    var color: Color {
        switch self {
        case .risk:
            return AppPalette.danger
        case .watch:
            return AppPalette.warning
        case .info:
            return AppPalette.info
        case .good:
            return AppPalette.positive
        }
    }

    var label: String {
        switch self {
        case .risk:
            return "风险"
        case .watch:
            return "留意"
        case .info:
            return "观察"
        case .good:
            return "正常"
        }
    }
}

struct PortfolioDiagnosticsPanel: View {
    let summary: PortfolioDiagnosticsSummary

    private func portfolioDiagnosticWideColumns(count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 168), spacing: 10, alignment: .top), count: max(1, min(5, count)))
    }

    private func portfolioDiagnosticMediumColumns(count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 168), spacing: 10, alignment: .top), count: max(1, min(3, count)))
    }

    private var portfolioDiagnosticCompactColumns: [GridItem] {
        [GridItem(.flexible(minimum: 168), spacing: 10, alignment: .top)]
    }

    var body: some View {
        SectionCard(title: "组合诊断", subtitle: summary.headline, icon: "stethoscope") {
            VStack(alignment: .leading, spacing: 12) {
                Text(summary.headline)
                    .font(AppPalette.appFont(.title2, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                ViewThatFits(in: .horizontal) {
                    LazyVGrid(columns: portfolioDiagnosticWideColumns(count: summary.items.count), alignment: .leading, spacing: 10) {
                        ForEach(summary.items) { item in
                            PortfolioDiagnosticTile(item: item)
                        }
                    }

                    LazyVGrid(columns: portfolioDiagnosticMediumColumns(count: summary.items.count), alignment: .leading, spacing: 10) {
                        ForEach(summary.items) { item in
                            PortfolioDiagnosticTile(item: item)
                        }
                    }

                    LazyVGrid(columns: portfolioDiagnosticCompactColumns, alignment: .leading, spacing: 10) {
                        ForEach(summary.items) { item in
                            PortfolioDiagnosticTile(item: item)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct PortfolioDiagnosticTile: View {
    let item: PortfolioDiagnosticItem

    private var iconName: String {
        switch item.kind {
        case .concentration:
            return "scope"
        case .pendingExposure:
            return "clock.badge.exclamationmark"
        case .planCoverage:
            return "calendar.badge.clock"
        case .dailyMovement:
            return "waveform.path.ecg"
        case .quoteCoverage:
            return "dot.radiowaves.left.and.right"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(item.level.color)
                    .frame(width: 28, height: 28)
                    .background(item.level.color.opacity(0.10), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Text(item.level.label)
                        .font(AppPalette.appFont(.caption, weight: .semibold))
                        .foregroundStyle(item.level.color)
                }

                Spacer(minLength: 4)

                Text(item.metric)
                    .font(AppPalette.appFont(.title3, weight: .bold, design: .rounded))
                    .foregroundStyle(item.level.color)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Text(item.detail)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding(12)
        .staticSurface(
            tint: item.level.color,
            fill: AppPalette.cardStrong.opacity(0.74),
            strokeOpacity: 0.18,
            activeStrokeOpacity: 0.38
        )
    }
}

private extension ProfitAttributionKind {
    var color: Color {
        switch self {
        case .gain:
            return AppPalette.marketGain
        case .drag:
            return AppPalette.marketLoss
        case .neutral:
            return AppPalette.muted
        }
    }

    var label: String {
        switch self {
        case .gain:
            return "贡献"
        case .drag:
            return "拖累"
        case .neutral:
            return "持平"
        }
    }
}

struct ProfitAttributionPanel: View {
    let summary: ProfitAttributionSummary
    @State private var isAttributionDetailExpanded = false

    private var totalTint: Color {
        AppPalette.marketTint(for: summary.totalProfitValue)
    }

    private var gainEntries: [ProfitAttributionEntry] {
        summary.entries
            .filter { $0.kind == .gain }
            .sorted { abs($0.amountValue) > abs($1.amountValue) }
    }

    private var dragEntries: [ProfitAttributionEntry] {
        summary.entries
            .filter { $0.kind == .drag }
            .sorted { abs($0.amountValue) > abs($1.amountValue) }
    }

    private struct ProfitMetricItem: Identifiable {
        let id: Int
        let title: String
        let value: String
        let tint: Color
    }

    private var metricItems: [ProfitMetricItem] {
        [
            .init(id: 0, title: "总收益", value: summary.totalProfitText, tint: totalTint),
            .init(id: 1, title: "总收益率", value: summary.totalProfitRateText, tint: totalTint),
            .init(id: 2, title: "收益覆盖", value: summary.coverageText, tint: AppPalette.info),
            .init(id: 3, title: "待确认", value: summary.pendingExposureText, tint: AppPalette.warning),
            .init(id: 4, title: "下次计划", value: summary.plannedExposureText, tint: AppPalette.info)
        ]
    }

    private func metricGrid() -> some View {
        ViewThatFits(in: .horizontal) {
            EqualHeightGrid(items: metricItems, columnsCount: 5) { ProfitAttributionMetric(title: $0.title, value: $0.value, tint: $0.tint) }
            EqualHeightGrid(items: metricItems, columnsCount: 3) { ProfitAttributionMetric(title: $0.title, value: $0.value, tint: $0.tint) }
            EqualHeightGrid(items: metricItems, columnsCount: 2) { ProfitAttributionMetric(title: $0.title, value: $0.value, tint: $0.tint) }
        }
    }

    var body: some View {
        SectionCard(title: "收益归因", subtitle: summary.headline, icon: "chart.pie") {
            VStack(alignment: .leading, spacing: 12) {
                metricGrid()

                if summary.entries.isEmpty {
                    Text("等待收益数据")
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(AppPalette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(AppPalette.cardStrong.opacity(0.72), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 10) {
                            attributionDonutCharts
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            attributionDonutCharts
                        }
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isAttributionDetailExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Label(
                                isAttributionDetailExpanded ? "收起明细" : "查看全部明细",
                                systemImage: "list.bullet"
                            )
                            .font(AppPalette.appFont(.footnote, weight: .semibold))
                            .foregroundStyle(AppPalette.info)

                            Spacer()

                            Text("\(summary.entries.count) 项")
                                .font(AppPalette.appFont(.caption, weight: .medium))
                                .foregroundStyle(AppPalette.muted)

                            Image(systemName: "chevron.down")
                                .font(AppPalette.appFont(.caption, weight: .semibold))
                                .foregroundStyle(AppPalette.muted)
                                .rotationEffect(.degrees(isAttributionDetailExpanded ? 180 : 0))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(AppPalette.cardStrong.opacity(0.42), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                    .accessibilityLabel("归因明细")
                    .accessibilityValue(isAttributionDetailExpanded ? "已展开，共 \(summary.entries.count) 项" : "已收起，共 \(summary.entries.count) 项")

                    if isAttributionDetailExpanded {
                        VStack(spacing: 8) {
                            ForEach(summary.entries) { entry in
                                ProfitAttributionEntryRow(entry: entry)
                            }
                        }
                        .clipped()
                        .transition(.opacity)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var attributionDonutCharts: some View {
        ProfitAttributionDonutCard(
            title: "收益贡献",
            entries: gainEntries,
            tint: AppPalette.marketGain,
            emptyMessage: "暂无正收益标的"
        )
        ProfitAttributionDonutCard(
            title: "收益拖累",
            entries: dragEntries,
            tint: AppPalette.marketLoss,
            emptyMessage: "暂无负收益标的"
        )
    }
}

struct ProfitAttributionDonutSlice: Identifiable {
    let id: String
    let title: String
    let amount: Double
    let color: Color
}

struct ProfitAttributionDonutCard: View {
    let title: String
    let entries: [ProfitAttributionEntry]
    let tint: Color
    let emptyMessage: String

    private var totalMagnitude: Double {
        entries.reduce(0) { $0 + abs($1.amountValue) }
    }

    private var signedTotal: Double {
        entries.reduce(0) { $0 + $1.amountValue }
    }

    private var slices: [ProfitAttributionDonutSlice] {
        let primaryEntries = Array(entries.prefix(4))
        let opacitySteps = [1.0, 0.78, 0.60, 0.44]
        var result = primaryEntries.enumerated().map { index, entry in
            ProfitAttributionDonutSlice(
                id: entry.id,
                title: entry.title,
                amount: abs(entry.amountValue),
                color: tint.opacity(opacitySteps[index])
            )
        }

        let remaining = Array(entries.dropFirst(4))
        if !remaining.isEmpty {
            result.append(
                ProfitAttributionDonutSlice(
                    id: "other-\(title)",
                    title: "其他 \(remaining.count) 项",
                    amount: remaining.reduce(0) { $0 + abs($1.amountValue) },
                    color: tint.opacity(0.28)
                )
            )
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Text("\(entries.count) 项")
                    .font(AppPalette.appFont(.caption, weight: .medium))
                    .foregroundStyle(AppPalette.muted)
                Spacer()
            }

            if entries.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "chart.pie")
                        .font(AppPalette.appFont(.title2, weight: .semibold))
                        .foregroundStyle(tint.opacity(0.72))
                    Text(emptyMessage)
                        .font(AppPalette.appFont(.footnote, weight: .medium))
                        .foregroundStyle(AppPalette.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 142, alignment: .center)
            } else {
                HStack(alignment: .center, spacing: 16) {
                    ZStack {
                        Chart {
                            ForEach(slices) { slice in
                                SectorMark(
                                    angle: .value("影响金额", slice.amount),
                                    innerRadius: .ratio(0.64),
                                    angularInset: 1.5
                                )
                                .foregroundStyle(slice.color)
                                .cornerRadius(3)
                            }
                        }
                        .chartLegend(.hidden)

                        VStack(spacing: 2) {
                            Text(compactAttributionAmount(signedTotal))
                                .font(AppPalette.appFont(.subheadline, weight: .bold, design: .rounded))
                                .foregroundStyle(tint)
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                            Text("合计")
                                .font(AppPalette.appFont(.caption2, weight: .medium))
                                .foregroundStyle(AppPalette.muted)
                        }
                        .frame(width: 72)
                    }
                    .frame(width: 142, height: 142)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(slices) { slice in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(slice.color)
                                    .frame(width: 7, height: 7)
                                Text(slice.title)
                                    .font(AppPalette.appFont(.caption, weight: .medium))
                                    .foregroundStyle(AppPalette.ink.opacity(0.84))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(percentText(slice.amount))
                                    .font(AppPalette.appFont(.caption2, weight: .medium, design: .rounded))
                                    .foregroundStyle(AppPalette.muted)
                                    .monospacedDigit()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 300, maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(tint.opacity(0.045), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title)饼图")
    }

    private func percentText(_ amount: Double) -> String {
        guard totalMagnitude > 0 else { return "0%" }
        return String(format: "%.1f%%", amount / totalMagnitude * 100)
    }

    private func compactAttributionAmount(_ amount: Double) -> String {
        let absolute = abs(amount)
        let sign = amount > 0 ? "+" : amount < 0 ? "-" : ""
        if absolute >= 10_000 {
            return "\(sign)¥\(String(format: "%.1f", absolute / 10_000))万"
        }
        if absolute >= 1_000 {
            return "\(sign)¥\(String(format: "%.1f", absolute / 1_000))千"
        }
        return "\(sign)¥\(String(format: "%.0f", absolute))"
    }
}

struct ProfitAttributionMetric: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(AppPalette.appFont(.footnote, weight: .medium))
                .foregroundStyle(AppPalette.muted)
                .lineLimit(1)
            Text(value)
                .font(AppPalette.appFont(.body, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.66)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppPalette.cardStrong.opacity(0.72), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                .stroke(tint.opacity(0.14), lineWidth: 1)
        )
    }
}

struct ProfitAttributionEntryRow: View {
    let entry: ProfitAttributionEntry

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(entry.kind.label)
                .font(AppPalette.appFont(.footnote, weight: .bold))
                .foregroundStyle(entry.kind.color)
                .frame(width: 36, height: 24)
                .background(entry.kind.color.opacity(0.10), in: RoundedRectangle(cornerRadius: AppPalette.badgeRadius))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                    ToolbarBadge(title: entry.codeText, tint: AppPalette.info)
                }
                Text("市值 \(entry.marketValueText) · 影响 \(entry.impactShareText)")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                Text(entry.amountText)
                    .font(AppPalette.appFont(.headline, weight: .bold, design: .rounded))
                    .foregroundStyle(entry.kind.color)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(entry.rateText)
                    .font(AppPalette.appFont(.footnote, weight: .medium, design: .rounded))
                    .foregroundStyle(entry.kind.color.opacity(0.86))
                    .monospacedDigit()
            }
            .frame(width: 112, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .staticSurface(
            tint: entry.kind.color,
            radius: AppPalette.controlRadius,
            fill: AppPalette.cardStrong.opacity(0.56),
            strokeOpacity: 0.26,
            activeStrokeOpacity: 0.40
        )
    }
}
