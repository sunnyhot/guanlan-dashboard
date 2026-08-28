import SwiftUI

private enum MenuBarHoldingSortOption: String, CaseIterable, Identifiable {
    case dailyChange = "今日涨跌"
    case totalProfit = "总收益"
    case marketValue = "市值"

    var id: String { rawValue }
}

struct MenuBarPortfolioView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("menu.bar.holdings.sort") private var holdingSortRawValue = MenuBarHoldingSortOption.marketValue.rawValue

    @State private var pendingWatchlistDeletion: PersonalWatchlistQuoteRow?
    /// 弹框内嵌配置模式：把滚动区切换成板块开关/排序/行情勾选面板。
    @State private var isPresentingPopoverConfig = false

    private var holdingSort: MenuBarHoldingSortOption {
        MenuBarHoldingSortOption(rawValue: holdingSortRawValue) ?? .marketValue
    }

    private var orderedSections: [MenuBarPopoverSectionKind] {
        model.menuBarPopoverSections.visibleSections
    }

    private var isMarketIndexSectionVisible: Bool {
        !model.menuBarPopoverSections.isHidden(.marketIndices)
    }

    private var isGoldForexSectionVisible: Bool {
        !model.menuBarPopoverSections.isHidden(.goldForex)
    }

    private var hasPopoverQuoteSectionToRefresh: Bool {
        (isMarketIndexSectionVisible && !model.selectedMenuBarMarketIndexKinds.isEmpty)
            || (isGoldForexSectionVisible && !model.selectedMenuBarGoldForexKinds.isEmpty)
    }

    private var hasMarketIndexTickerSelection: Bool {
        model.menuBarTickerSettings.selections.contains {
            $0.kindValue?.marketIndexRequest != nil
        }
    }

    private var watchlistRows: [PersonalWatchlistQuoteRow] {
        model.personalWatchlistSnapshot?.rows
            ?? PersonalWatchlistSnapshot.local(records: model.personalWatchlistRecords).rows
    }

    private var isRefreshing: Bool {
        model.isRefreshingPortfolio
            || model.isRefreshingPersonalWatchlist
            || model.isRefreshingMarketIndices
            || model.isRefreshingGoldForex
    }

    private var refreshCaption: String {
        let portfolioRefresh = model.userPortfolioSnapshot?.refreshedAt
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !portfolioRefresh.isEmpty { return portfolioRefresh }

        let watchlistRefresh = model.personalWatchlistSnapshot?.refreshedAt
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !watchlistRefresh.isEmpty { return watchlistRefresh }

        return "点击刷新获取最新行情"
    }

    private var pendingWatchlistDeletionBinding: Binding<Bool> {
        Binding(
            get: { pendingWatchlistDeletion != nil },
            set: { isPresented in
                if !isPresented { pendingWatchlistDeletion = nil }
            }
        )
    }

    private var pendingWatchlistDeletionMessage: String {
        guard let pendingWatchlistDeletion else { return "" }
        let name = pendingWatchlistDeletion.item.normalizedName ?? pendingWatchlistDeletion.item.normalizedCode
        return "会删除 \(name) 的关注基准与本地每日价格记录，不会影响实际持仓。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if isPresentingPopoverConfig {
                popoverConfigPanel
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        if orderedSections.isEmpty {
                            MenuBarEmptyState(
                                icon: "eye.slash",
                                title: "所有板块都已隐藏",
                                subtitle: "点右上角的齿轮，重新开启需要的板块。"
                            )
                        } else {
                            ForEach(orderedSections) { section in
                                popoverSection(section)
                            }
                        }
                    }
                    .padding(.trailing, 2)
                }
            }

            Divider()

            HStack {
                Button("打开主界面") {
                    model.showMainWindow(section: .portfolio)
                }
                .buttonStyle(.appText)

                Button("配置菜单栏") {
                    model.showMainWindow(section: .settings)
                }
                .buttonStyle(.appText)

                Spacer()

                Button(model.isCheckingForUpdates ? "检测中…" : "检测更新") {
                    model.showMainWindow(section: .settings)
                    Task { await model.checkForUpdates(userInitiated: true) }
                }
                .buttonStyle(.appText)
                .disabled(model.isCheckingForUpdates)

                Button("退出应用") {
                    model.quitApplication()
                }
                .buttonStyle(.appText)
                .foregroundStyle(AppPalette.muted)
                .help("退出且慢主理人看板")
            }
        }
        .padding(14)
        .frame(width: 392, height: 720)
        .background(AppPalette.canvasGradient)
        .buttonStyle(.appSecondary)
        .preferredColorScheme(model.appearance.colorScheme)
        .respectsReducedMotion()
        // 刷新由 AppDelegate.togglePopover → model.onMenuBarPopoverPresented() 驱动，
        // 不再用 .task：popover 的 hosting controller 只创建一次，.task 不会每次开都重跑。
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("持仓与关注")
                    .font(AppPalette.appFont(.title3, weight: .bold))
                Text(refreshCaption)
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
            }
            Spacer()
            sectionOrderMenu
            Button {
                isPresentingPopoverConfig.toggle()
            } label: {
                Image(systemName: isPresentingPopoverConfig ? "xmark" : "slider.horizontal.3")
            }
            .buttonStyle(.appSecondary)
            .controlSize(.small)
            .help(isPresentingPopoverConfig ? "返回弹框内容" : "配置弹框内容板块")
            Button(isRefreshing ? "刷新中…" : "刷新") {
                Task {
                    if model.hasPersonalPortfolio {
                        try? await model.refreshUserPortfolio()
                    }
                    if model.hasPersonalWatchlist {
                        try? await model.refreshPersonalWatchlist()
                    }
                    if !model.hasPersonalPortfolio {
                        await model.refreshMarketIndices(kinds: MarketIndexKind.allCases, updateNotice: true)
                    }
                    if isMarketIndexSectionVisible, !model.selectedMenuBarMarketIndexKinds.isEmpty {
                        await model.refreshMarketIndices(updateNotice: false)
                    }
                    if isGoldForexSectionVisible, !model.selectedMenuBarGoldForexKinds.isEmpty {
                        await model.refreshGoldForexQuotes(updateNotice: false)
                    }
                }
            }
            .buttonStyle(.appPrimary)
            .controlSize(.small)
            .disabled(
                isRefreshing
                    || (!model.hasPersonalPortfolio
                        && !model.hasPersonalWatchlist
                        && !hasMarketIndexTickerSelection
                        && !hasPopoverQuoteSectionToRefresh)
            )
        }
    }

    private var sectionOrderMenu: some View {
        Menu {
            ForEach(orderedSections) { section in
                Button {
                    model.moveMenuBarPopoverSectionToTop(section)
                } label: {
                    if orderedSections.first == section {
                        Label("\(section.title)在上", systemImage: "checkmark")
                    } else {
                        Text("\(section.title)在上")
                    }
                }
            }
        } label: {
            Label("顺序", systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
        .help("把某个板块移到最上；隐藏/更多排序可用右键或齿轮配置")
    }

    @ViewBuilder
    private func sectionContextMenu(_ section: MenuBarPopoverSectionKind) -> some View {
        Button {
            model.moveMenuBarPopoverSectionToTop(section)
        } label: {
            Label("移到最上", systemImage: "arrow.up.to.line")
        }
        Button(role: .destructive) {
            model.setMenuBarPopoverSection(section, isHidden: true)
        } label: {
            Label("隐藏“\(section.title)”板块", systemImage: "eye.slash")
        }
    }

    @ViewBuilder
    private func popoverSection(_ section: MenuBarPopoverSectionKind) -> some View {
        switch section {
        case .portfolio:
            portfolioPanel
        case .watchlist:
            watchlistPanel(rows: watchlistRows)
        case .marketIndices:
            marketIndicesPanel
        case .goldForex:
            goldForexPanel
        }
    }

    private var portfolioPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "briefcase.fill")
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.info)
                Text("我的持仓")
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                TintedCapsuleBadge(
                    text: "\(model.userPortfolioSnapshot?.holdingCount ?? model.activePortfolioHoldingCount)",
                    tint: AppPalette.muted,
                    style: .neutral,
                    font: AppPalette.appFont(.footnote, weight: .bold, design: .rounded),
                    horizontalPadding: 8,
                    verticalPadding: 4
                )
                Spacer()
                if let snapshot = model.userPortfolioSnapshot, !snapshot.rows.isEmpty {
                    Picker("排序", selection: holdingSortBinding) {
                        ForEach(MenuBarHoldingSortOption.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                }
            }
            .contextMenu { sectionContextMenu(.portfolio) }

            if let snapshot = model.userPortfolioSnapshot, !snapshot.rows.isEmpty {
                MenuBarSummaryCard(
                    snapshot: snapshot,
                    personalSummary: model.personalAssetSummary
                )
                holdingsPanel(snapshot: snapshot)
            } else if model.hasPersonalPortfolio {
                MenuBarEmptyState(
                    icon: "waveform.path.ecg",
                    title: "还没有估值结果",
                    subtitle: "点一次刷新，就会拉到每只标的的实时估值和总收益。"
                )
            } else {
                MenuBarEmptyState(
                    icon: "briefcase",
                    title: model.hasInvestmentPlans ? "已有计划，但还没持仓估值" : "还没配置持仓",
                    subtitle: "去主界面的“我的持仓”录入后，这里会直接显示每只标的的实时估值和总收益。"
                )
            }
        }
    }

    private func holdingsPanel(snapshot: UserPortfolioSnapshot) -> some View {
        LazyVStack(spacing: 6) {
            ForEach(sortedHoldingRows(snapshot.rows)) { row in
                MenuBarHoldingRow(row: row)
            }
        }
    }

    private func sortedHoldingRows(_ rows: [UserPortfolioValuationRow]) -> [UserPortfolioValuationRow] {
        let value: (UserPortfolioValuationRow) -> Double? = switch holdingSort {
        case .dailyChange:
            { $0.estimatedDailyChangeAmount }
        case .totalProfit:
            { $0.profitAmount }
        case .marketValue:
            { $0.marketValue }
        }

        return rows.sorted {
            (value($0) ?? -.greatestFiniteMagnitude) > (value($1) ?? -.greatestFiniteMagnitude)
        }
    }

    private var holdingSortBinding: Binding<MenuBarHoldingSortOption> {
        Binding(
            get: { holdingSort },
            set: { holdingSortRawValue = $0.rawValue }
        )
    }

    private func watchlistPanel(rows: [PersonalWatchlistQuoteRow]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.warning)
                Text("我的关注")
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Text("\(rows.count)")
                    .font(AppPalette.appFont(.footnote, weight: .bold, design: .rounded))
                    .foregroundStyle(AppPalette.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AppPalette.cardStrong)
                    .clipShape(Capsule())
                Spacer()
                Button(rows.isEmpty ? "去添加" : "管理") {
                    model.showMainWindow(section: .portfolio)
                }
                .buttonStyle(.appText)
                .controlSize(.small)
            }
            .contextMenu { sectionContextMenu(.watchlist) }

            if rows.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "star")
                        .foregroundStyle(AppPalette.muted)
                    Text("还没有关注标的，可在主界面的“我的关注”中添加。")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(AppPalette.cardStrong)
                .clipShape(RoundedRectangle(cornerRadius: AppPalette.cardRadius))
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(rows) { row in
                        MenuBarWatchlistRow(row: row) {
                            pendingWatchlistDeletion = row
                        }
                    }
                }
            }
        }
        .alert("取消关注？", isPresented: pendingWatchlistDeletionBinding) {
            Button("取消关注", role: .destructive) {
                if let pendingWatchlistDeletion {
                    model.removePersonalWatchlistItem(pendingWatchlistDeletion.record.id)
                }
                pendingWatchlistDeletion = nil
            }
            Button("保留", role: .cancel) {
                pendingWatchlistDeletion = nil
            }
        } message: {
            Text(pendingWatchlistDeletionMessage)
        }
    }

    private var marketIndicesPanel: some View {
        let selectedKinds = model.menuBarPopoverSections.marketIndexKinds

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: MenuBarPopoverSectionKind.marketIndices.icon)
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.info)
                Text(MenuBarPopoverSectionKind.marketIndices.title)
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                if !selectedKinds.isEmpty {
                    Text("\(selectedKinds.count)")
                        .font(AppPalette.appFont(.footnote, weight: .bold, design: .rounded))
                        .foregroundStyle(AppPalette.muted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AppPalette.cardStrong)
                        .clipShape(Capsule())
                }
                Spacer()
                if model.isRefreshingMarketIndices {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .contextMenu { sectionContextMenu(.marketIndices) }

            if selectedKinds.isEmpty {
                quoteSectionEmptyState(text: "还没有勾选指数。") {
                    isPresentingPopoverConfig = true
                }
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(selectedKinds) { kind in
                        if let quote = model.marketIndexQuotes[kind] {
                            MenuBarMarketIndexRow(quote: quote)
                        } else {
                            MenuBarQuotePlaceholderRow(title: kind.label)
                        }
                    }
                }
            }
        }
    }

    private var goldForexPanel: some View {
        let selectedKinds = model.menuBarPopoverSections.goldForexKinds

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: MenuBarPopoverSectionKind.goldForex.icon)
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.brand)
                Text(MenuBarPopoverSectionKind.goldForex.title)
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                if !selectedKinds.isEmpty {
                    Text("\(selectedKinds.count)")
                        .font(AppPalette.appFont(.footnote, weight: .bold, design: .rounded))
                        .foregroundStyle(AppPalette.muted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AppPalette.cardStrong)
                        .clipShape(Capsule())
                }
                Spacer()
                if model.isRefreshingGoldForex {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .contextMenu { sectionContextMenu(.goldForex) }

            if selectedKinds.isEmpty {
                quoteSectionEmptyState(text: "还没有勾选黄金/汇率标的。") {
                    isPresentingPopoverConfig = true
                }
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(selectedKinds) { kind in
                        if let quote = model.goldForexQuotes[kind] {
                            MenuBarGoldForexRow(quote: quote)
                        } else {
                            MenuBarQuotePlaceholderRow(title: kind.label)
                        }
                    }
                }
            }
        }
    }

    private func quoteSectionEmptyState(text: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
            Spacer()
            Button("去勾选", action: action)
                .buttonStyle(.appText)
                .controlSize(.small)
        }
        .padding(10)
        .background(AppPalette.cardStrong)
        .clipShape(RoundedRectangle(cornerRadius: AppPalette.cardRadius))
    }

    private var popoverConfigPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("配置弹框内容")
                        .font(AppPalette.appFont(.title3, weight: .bold))
                    Text("开关控制板块显示，箭头调整上下顺序")
                        .font(AppPalette.appFont(.subheadline))
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer()
            }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.menuBarPopoverSections.order) { kind in
                        MenuBarPopoverSectionConfigCard(
                            kind: kind,
                            isFirst: model.menuBarPopoverSections.order.first == kind,
                            isLast: model.menuBarPopoverSections.order.last == kind
                        )
                    }

                    Button {
                        model.resetMenuBarPopoverSections()
                    } label: {
                        Label("恢复默认", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.appSecondary)
                    .controlSize(.small)
                }
                .padding(.trailing, 2)
            }
        }
    }
}

private struct MenuBarEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(AppPalette.appFont(.largeTitle))
                .foregroundStyle(AppPalette.muted)
            Text(title)
                .font(AppPalette.appFont(.title3, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
            Text(subtitle)
                .font(AppPalette.appFont(.subheadline))
                .foregroundStyle(AppPalette.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(AppPalette.cardStrong)
        .clipShape(RoundedRectangle(cornerRadius: AppPalette.cardRadius))
    }
}

private struct MenuBarSummaryCard: View {
    let snapshot: UserPortfolioSnapshot
    let personalSummary: PersonalAssetAggregateSummary?

    private var profitTint: Color {
        AppPalette.marketTint(for: snapshot.totalProfitAmount)
    }

    var body: some View {
        let dailyChange = snapshot.dailyChangeSummary
        let dailyTint = AppPalette.marketTint(for: dailyChange.amount)
        let changeTitle = snapshot.dailyChangeTitle

        VStack(alignment: .leading, spacing: 5) {
            Text(currencyText(personalSummary?.totalEffectiveHoldingAmount ?? snapshot.totalMarketValue))
                .font(AppPalette.appFont(.title2, weight: .bold, design: .rounded))
                .foregroundStyle(AppPalette.ink)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                SummaryPill(title: changeTitle, value: dailyChangeCurrencyText(dailyChange.amount), tint: dailyTint)
                SummaryPill(title: "\(changeTitle)率", value: dailyChangePercentText(dailyChange.pct), tint: dailyTint)
                SummaryPill(title: "总收益", value: signedCurrencyText(snapshot.totalProfitAmount), tint: profitTint)
                SummaryPill(title: "总收益率", value: percentOptional(snapshot.totalProfitPct), tint: profitTint)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.cardStrong)
        .clipShape(RoundedRectangle(cornerRadius: AppPalette.panelRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.panelRadius)
                .stroke(AppPalette.line.opacity(0.7), lineWidth: 1)
        )
    }
}

private struct SummaryPill: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(value)
                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
        .padding(.horizontal, 7)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: AppPalette.cardRadius))
    }
}

private struct MenuBarHoldingRow: View {
    let row: UserPortfolioValuationRow

    private var dailyTint: Color {
        AppPalette.marketTint(for: row.estimatedDailyChangeAmount)
    }

    private var marketTint: Color {
        if let market = row.holding.detectedMarket {
            switch market {
            case .aShare: return AppPalette.info
            case .hk: return AppPalette.brand
            case .us: return AppPalette.positive
            }
        }
        if let fundMarket = row.holding.detectedFundMarket {
            switch fundMarket {
            case .offExchange: return Color.purple
            case .onExchange: return AppPalette.warning
            }
        }
        return AppPalette.muted
    }

    var body: some View {
        let quote = row.dropdownQuote

        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.fundName)
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                    .help(row.fundName)
                HStack(spacing: 4) {
                    Text(row.holding.normalizedFundCode)
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                        .monospacedDigit()
                    Text("· \(quote.compactText)")
                        .font(AppPalette.appFont(.caption, weight: .medium))
                        .foregroundStyle(AppPalette.ink.opacity(0.76))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 1) {
                Text(currencyOptional(row.marketValue, market: row.holding.detectedMarket))
                    .font(AppPalette.appFont(.body, weight: .bold, design: .rounded))
                    .foregroundStyle(AppPalette.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                Text("\(unitsText(row.holding.units)) 份")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .monospacedDigit()
            }
            .frame(width: 96, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 1) {
                Text(dailyChangeCurrencyText(row.estimatedDailyChangeAmount, market: row.holding.detectedMarket))
                    .font(AppPalette.appFont(.subheadline, weight: .bold))
                    .foregroundStyle(dailyTint)
                    .monospacedDigit()
                    .lineLimit(1)
                Text(changeCaption)
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(dailyTint)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(marketTint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                .stroke(marketTint.opacity(0.28), lineWidth: 1)
        )
    }

    private var latestNAVCaption: String {
        guard let date = row.officialNavDate, !date.isEmpty else { return "待公布" }
        return "截至 \(date.suffix(5))"
    }

    private var changeCaption: String {
        guard let changePct = row.estimateChangePct else { return latestNAVCaption }
        let changeText = dailyChangePercentText(changePct)
        guard row.changePeriodTitle == "最近涨跌", let date = row.changeDate else {
            return changeText
        }
        return "\(date.suffix(5)) · \(changeText)"
    }
}

private struct MenuBarWatchlistRow: View {
    let row: PersonalWatchlistQuoteRow
    let onDelete: () -> Void

    private var categoryTint: Color {
        switch row.category {
        case .offExchangeFund:
            return AppPalette.brand
        case .onExchangeFund:
            return AppPalette.warning
        case .stock:
            return AppPalette.info
        }
    }

    private var dailyTint: Color {
        AppPalette.marketTint(for: row.dailyChangePct)
    }

    private var followTint: Color {
        AppPalette.marketTint(for: row.changeSinceFollowPct)
    }

    private var currentPriceText: String {
        guard let currentPrice = row.currentPrice else { return "—" }
        if row.item.assetType == .stock {
            return currencyText(currentPrice, market: row.item.detectedStockMarket)
        }
        return decimalText(currentPrice)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName)
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                    .help(row.displayName)
                Text("\(row.item.normalizedCode) · \(row.item.marketLabel)")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(currentPriceText)
                    .font(AppPalette.appFont(.subheadline, weight: .bold, design: .rounded))
                    .foregroundStyle(AppPalette.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("最新价")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
            }
            .frame(width: 86, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 2) {
                Text(percentOptional(row.dailyChangePct))
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(dailyTint)
                    .monospacedDigit()
                    .lineLimit(1)
                Text("今日")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
            }
            .frame(width: 58, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 2) {
                Text(percentOptional(row.changeSinceFollowPct))
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(followTint)
                    .monospacedDigit()
                    .lineLimit(1)
                Text("关注以来")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
            }
            .frame(width: 68, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(categoryTint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                .stroke(categoryTint.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(row.displayName)，最新价 \(currentPriceText)，今日 \(percentOptional(row.dailyChangePct))，关注以来 \(percentOptional(row.changeSinceFollowPct))"
        )
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("取消关注", systemImage: "star.slash")
            }
        }
    }
}

private struct MenuBarMarketIndexRow: View {
    let quote: MarketIndexQuote

    private var tint: Color {
        AppPalette.marketTint(for: quote.changePct ?? quote.changeAmount ?? 0)
    }

    private var displayName: String {
        quote.name.isEmpty ? quote.kind.label : quote.name
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                    .help(displayName)
                Text(quote.quotedAt)
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(levelText(quote.price))
                    .font(AppPalette.appFont(.subheadline, weight: .bold, design: .rounded))
                    .foregroundStyle(AppPalette.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("点位")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
            }
            .frame(width: 96, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 2) {
                Text(signedAmountText(quote.changeAmount))
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                    .lineLimit(1)
                Text(percentOptional(quote.changePct))
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                .stroke(tint.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(displayName)，点位 \(levelText(quote.price))，\(percentOptional(quote.changePct))"
        )
    }
}

private struct MenuBarGoldForexRow: View {
    let quote: GoldForexQuote

    private var tint: Color {
        AppPalette.marketTint(for: quote.changePct ?? quote.changeAmount ?? 0)
    }

    private var priceText: String {
        quote.kind.isForex ? decimalText(quote.price) : levelText(quote.price)
    }

    private var changeAmountText: String {
        signedAmountText(quote.changeAmount, fractionDigits: quote.kind.isForex ? 4 : 2)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(quote.name.isEmpty ? quote.kind.label : quote.name)
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                    .help(quote.kind.label)
                Text(quote.quotedAt)
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(priceText)
                    .font(AppPalette.appFont(.subheadline, weight: .bold, design: .rounded))
                    .foregroundStyle(AppPalette.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(quote.kind.isForex ? "CNY" : "USD/oz")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
            }
            .frame(width: 96, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 2) {
                Text(changeAmountText)
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                    .lineLimit(1)
                Text(percentOptional(quote.changePct))
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                .stroke(tint.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(quote.kind.label) \(priceText)，\(percentOptional(quote.changePct))"
        )
    }
}

private struct MenuBarQuotePlaceholderRow: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
                .lineLimit(1)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "clock")
                Text("待刷新")
            }
            .font(AppPalette.appFont(.footnote))
            .foregroundStyle(AppPalette.muted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.cardStrong)
        .clipShape(RoundedRectangle(cornerRadius: AppPalette.cardRadius))
    }
}

private struct MenuBarPopoverSectionConfigCard: View {
    @EnvironmentObject private var model: AppModel
    let kind: MenuBarPopoverSectionKind
    let isFirst: Bool
    let isLast: Bool

    private var isVisible: Bool {
        !model.menuBarPopoverSections.isHidden(kind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: kind.icon)
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.info)
                Text(kind.title)
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                Toggle("显示", isOn: Binding(
                    get: { isVisible },
                    set: { model.setMenuBarPopoverSection(kind, isHidden: !$0) }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                Button {
                    model.moveMenuBarPopoverSection(kind, offset: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
                .disabled(isFirst)
                Button {
                    model.moveMenuBarPopoverSection(kind, offset: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
                .disabled(isLast)
            }

            if isVisible {
                switch kind {
                case .marketIndices:
                    kindCheckboxGrid(
                        MarketIndexKind.allCases,
                        label: { $0.compactLabel },
                        help: { $0.label },
                        isEnabled: { model.isMenuBarPopoverMarketIndexKindEnabled($0) },
                        set: { model.setMenuBarPopoverMarketIndexKind($0, isEnabled: $1) }
                    )
                case .goldForex:
                    kindCheckboxGrid(
                        GoldForexKind.allCases,
                        label: { $0.compactLabel },
                        help: { $0.label },
                        isEnabled: { model.isMenuBarPopoverGoldForexKindEnabled($0) },
                        set: { model.setMenuBarPopoverGoldForexKind($0, isEnabled: $1) }
                    )
                case .portfolio, .watchlist:
                    EmptyView()
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.cardStrong)
        .clipShape(RoundedRectangle(cornerRadius: AppPalette.cardRadius))
    }

    private func kindCheckboxGrid<Kind: Identifiable>(
        _ kinds: [Kind],
        label: @escaping (Kind) -> String,
        help: @escaping (Kind) -> String,
        isEnabled: @escaping (Kind) -> Bool,
        set: @escaping (Kind, Bool) -> Void
    ) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(kinds) { kind in
                Toggle(label(kind), isOn: Binding(
                    get: { isEnabled(kind) },
                    set: { set(kind, $0) }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
                .help(help(kind))
                .fixedSize()
            }
        }
    }
}
