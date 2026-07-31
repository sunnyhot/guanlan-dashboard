import SwiftUI

private enum MenuBarHoldingSortOption: String, CaseIterable, Identifiable {
    case dailyChange = "今日涨跌"
    case totalProfit = "总收益"
    case marketValue = "市值"

    var id: String { rawValue }
}

private enum MenuBarPopoverSection: String, CaseIterable, Identifiable {
    case portfolio
    case watchlist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .portfolio: return "我的持仓"
        case .watchlist: return "我的关注"
        }
    }
}

struct MenuBarPortfolioView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("menu.bar.holdings.sort") private var holdingSortRawValue = MenuBarHoldingSortOption.marketValue.rawValue
    @AppStorage("menu.bar.popover.top-section") private var topSectionRawValue = MenuBarPopoverSection.portfolio.rawValue

    @State private var pendingWatchlistDeletion: PersonalWatchlistQuoteRow?

    private var holdingSort: MenuBarHoldingSortOption {
        MenuBarHoldingSortOption(rawValue: holdingSortRawValue) ?? .marketValue
    }

    private var topSection: MenuBarPopoverSection {
        MenuBarPopoverSection(rawValue: topSectionRawValue) ?? .portfolio
    }

    private var orderedSections: [MenuBarPopoverSection] {
        switch topSection {
        case .portfolio: return [.portfolio, .watchlist]
        case .watchlist: return [.watchlist, .portfolio]
        }
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

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(orderedSections) { section in
                        popoverSection(section)
                    }
                }
                .padding(.trailing, 2)
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
        .task {
            for action in MenuBarPortfolioRefreshDecision.onAppear(
                hasPortfolioSnapshot: model.userPortfolioSnapshot != nil,
                hasPersonalPortfolio: model.hasPersonalPortfolio,
                hasIncompletePortfolioValuation: model.userPortfolioSnapshot?.hasIncompleteValuationCoverage ?? false,
                lastPortfolioRefreshAt: model.lastPortfolioRefreshAt
            ) {
                switch action {
                case .refreshPortfolio:
                    try? await model.refreshUserPortfolio(updateNotice: false)
                case .refreshMarketIndicesIfNeeded:
                    await model.refreshMarketIndicesIfNeeded()
                }
            }
            if model.hasPersonalWatchlist {
                try? await model.refreshPersonalWatchlist(updateNotice: false)
            }
        }
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
                }
            }
            .buttonStyle(.appPrimary)
            .controlSize(.small)
            .disabled(
                isRefreshing
                    || (!model.hasPersonalPortfolio
                        && !model.hasPersonalWatchlist
                        && !hasMarketIndexTickerSelection)
            )
        }
    }

    private var sectionOrderMenu: some View {
        Menu {
            ForEach(MenuBarPopoverSection.allCases) { section in
                Button {
                    topSectionRawValue = section.rawValue
                } label: {
                    if topSection == section {
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
        .help("调整我的持仓与我的关注的上下顺序")
    }

    @ViewBuilder
    private func popoverSection(_ section: MenuBarPopoverSection) -> some View {
        switch section {
        case .portfolio:
            portfolioPanel
        case .watchlist:
            watchlistPanel(rows: watchlistRows)
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

    private var profitTint: Color {
        AppPalette.marketTint(for: row.profitAmount)
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

private struct HoldingMetricPill: View {
    let title: String
    let amount: String
    let pct: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(AppPalette.appFont(.caption2, weight: .medium))
                    .foregroundStyle(AppPalette.muted)
                Text(amount)
                    .font(AppPalette.appFont(.footnote, weight: .bold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .monospacedDigit()
                Text(pct)
                    .font(AppPalette.appFont(.caption, weight: .semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48, alignment: .leading)
        .padding(.horizontal, 7)
        .background(tint.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: AppPalette.cardRadius))
    }
}
