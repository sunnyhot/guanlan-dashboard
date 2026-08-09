import Foundation

// MARK: - Portfolio Refresh & Market Indices

extension AppModel {
    func refreshUserPortfolio(
        updateNotice: Bool = true,
        forceQuoteRefresh: Bool? = nil
    ) async throws {
        let holdings = activeUserPortfolioHoldings
        let telemetryStart = PerformanceTelemetry.start()
        var telemetryResult = "completed"
        defer {
            PerformanceTelemetry.record(
                "refresh.portfolio",
                startedAt: telemetryStart,
                metadata: [
                    "holdingCount": "\(holdings.count)",
                    "rowCount": "\(userPortfolioSnapshot?.rows.count ?? 0)",
                    "dailyChangeCoverage": "\(userPortfolioSnapshot?.dailyChangeCoverageCount ?? 0)",
                    "dailyChangePending": "\(userPortfolioSnapshot?.dailyChangePendingCount ?? 0)",
                    "result": telemetryResult,
                    "updateNotice": "\(updateNotice)"
                ]
            )
        }
        guard !holdings.isEmpty else {
            telemetryResult = "empty"
            userPortfolioSnapshot = nil
            rebuildAssetRows()
            await refreshMarketIndicesIfNeeded()
            return
        }
        guard !isRefreshingPortfolio else {
            telemetryResult = "alreadyRefreshing"
            return
        }
        isRefreshingPortfolio = true
        defer { isRefreshingPortfolio = false }

        do {
            let snapshot = try await platformClient.fetchUserPortfolioSnapshot(
                holdings: holdings,
                forceQuoteRefresh: forceQuoteRefresh ?? updateNotice
            )
            userPortfolioSnapshot = snapshot
            rebuildAssetRows()
            recordPortfolioInsightSnapshotIfPossible(createdAt: snapshot.refreshedAt)
            lastPortfolioRefreshAt = Date()
            if updateNotice {
                noticeMessage = snapshot.refreshNoticeMessage
            }
            await refreshMarketIndicesIfNeeded()
        } catch {
            telemetryResult = "failed"
            throw error
        }
    }

    func refreshMarketIndices(kinds requestedKinds: [MarketIndexKind]? = nil, updateNotice: Bool = true) async {
        let telemetryStart = PerformanceTelemetry.start()
        var telemetryKindCount = 0
        var telemetryResult = "completed"
        defer {
            PerformanceTelemetry.record(
                "refresh.marketIndices",
                startedAt: telemetryStart,
                metadata: [
                    "kindCount": "\(telemetryKindCount)",
                    "quoteCount": "\(marketIndexQuotes.count)",
                    "result": telemetryResult,
                    "updateNotice": "\(updateNotice)"
                ]
            )
        }
        let kinds = requestedKinds ?? selectedMenuBarMarketIndexKinds
        telemetryKindCount = kinds.count
        guard !kinds.isEmpty else {
            telemetryResult = "empty"
            return
        }
        guard !isRefreshingMarketIndices else {
            telemetryResult = "alreadyRefreshing"
            return
        }

        isRefreshingMarketIndices = true
        defer { isRefreshingMarketIndices = false }

        let quotes = await platformClient.fetchMarketIndexQuotes(kinds: kinds)
        if !quotes.isEmpty {
            marketIndexQuotes.merge(quotes) { _, new in new }
            if updateNotice {
                noticeMessage = "大盘行情已刷新。"
            }
        } else if updateNotice {
            telemetryResult = "emptyResponse"
            errorMessage = "大盘行情暂时没有拉到可用数据。"
        }
    }

    func refreshMarketIndicesIfNeeded() async {
        guard menuBarTickerSettings.isEnabled, !selectedMenuBarMarketIndexKinds.isEmpty else { return }
        await refreshThrottle.throttle(key: "marketIndices") { [weak self] in
            await self?.refreshMarketIndices(updateNotice: false)
        }
    }

    /// 用户打开菜单栏 popover 时触发：5 秒节流防抖，通过则刷新持仓/关注/指数。
    /// 忽略 120 秒新鲜度——打开就是要新数据；节流兜底防止连点抖动。
    func onMenuBarPopoverPresented() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // throttle 的 action 是 @Sendable 闭包，运行在 RefreshThrottle actor 上；
            // 这里先在 main actor 取好判断值，闭包内只调 @MainActor 方法（编译器自动 hop）。
            let hasPortfolio = self.hasPersonalPortfolio
            let hasWatchlist = self.hasPersonalWatchlist
            await self.refreshThrottle.throttle(key: "menuBarPopover") { [weak self] in
                guard let self else { return }
                if hasPortfolio {
                    try? await self.refreshUserPortfolio(updateNotice: false)
                }
                if hasWatchlist {
                    try? await self.refreshPersonalWatchlist(updateNotice: false)
                }
                await self.refreshMarketIndicesIfNeeded()
            }
        }
    }

    var selectedMenuBarMarketIndexKinds: [MarketIndexKind] {
        var seen = Set<MarketIndexKind>()
        let selected = menuBarTickerSettings.selections.compactMap { selection -> MarketIndexKind? in
            guard let kind = selection.kindValue,
                  let indexKind = kind.marketIndexRequest?.kind else { return nil }
            return seen.insert(indexKind).inserted ? indexKind : nil
        }
        return selected.sorted { left, right in
            let all = MarketIndexKind.allCases
            return (all.firstIndex(of: left) ?? 0) < (all.firstIndex(of: right) ?? 0)
        }
    }

    func restartPortfolioAutoRefreshLoop() {
        portfolioAutoRefreshTask?.cancel()
        let interval = portfolioAutoRefreshIntervalSeconds * 1_000_000_000
        portfolioAutoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { return }
                guard let self else { return }
                // Skip if a manual refresh is already in progress; reschedule instead.
                guard !self.isRefreshingPortfolio else { continue }
                await self.refreshPortfolioIfAutoRefreshVisible()
            }
        }
    }

    func refreshPortfolioIfAutoRefreshVisible() async {
        let shouldRefreshPortfolio = hasPersonalPortfolio
            && !isRefreshingPortfolio
            && (selectedSection == .portfolio
                || selectedSection == .overview
                || menuBarTickerSettings.isEnabled)
        let shouldRefreshWatchlist = hasPersonalWatchlist
            && !isRefreshingPersonalWatchlist
            && (selectedSection == .portfolio || hasActivePersonalWatchlistAlerts)
        guard shouldRefreshPortfolio || shouldRefreshWatchlist else {
            await refreshMarketIndicesIfNeeded()
            return
        }

        if shouldRefreshPortfolio {
            do {
                try await refreshUserPortfolio(updateNotice: false)
            } catch {
                if selectedSection == .portfolio {
                    errorMessage = "个人持仓自动刷新失败：\(error.localizedDescription)"
                }
            }
        }

        if shouldRefreshWatchlist {
            do {
                try await refreshPersonalWatchlist(updateNotice: false)
            } catch {
                errorMessage = "我的关注自动刷新失败：\(error.localizedDescription)"
            }
        }

        // 估值预警评估：无论可见性，只要有持仓数据就评估（持仓刷新在 ticker 常驻时也会后台进行）
        if portfolioValuationAlertSettings.isEnabled, userPortfolioSnapshot != nil {
            await evaluatePortfolioValuationAlerts()
        }

        // 投资智能(Slice 1):集中度评估。gate 在 InvestmentIntelligence.enabled。
        await refreshConcentrationDecisionCases()
    }
}
