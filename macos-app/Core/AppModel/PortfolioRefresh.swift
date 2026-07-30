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

    @discardableResult
    func resolveAndPersistPortfolioNames() async -> Int {
        guard let portfolioFileURL else { return 0 }

        let missingNameHoldings = userPortfolioHoldings.filter {
            !$0.normalizedFundCode.isEmpty && $0.normalizedName == nil
        }
        guard !missingNameHoldings.isEmpty else { return 0 }

        isResolvingPortfolioNames = true
        defer { isResolvingPortfolioNames = false }

        let namesByHoldingID = await platformClient.resolveAssetNames(holdings: missingNameHoldings)
        guard !namesByHoldingID.isEmpty else { return 0 }

        var resolvedCount = 0
        let enrichedHoldings = userPortfolioHoldings.map { holding in
            guard holding.normalizedName == nil,
                  let resolvedName = namesByHoldingID[holding.id],
                  !resolvedName.isEmpty
            else {
                return holding
            }
            resolvedCount += 1
            return UserPortfolioHolding(
                id: holding.id,
                fundCode: holding.fundCode,
                assetType: holding.assetType,
                units: holding.units,
                costPrice: holding.costPrice,
                displayName: resolvedName,
                stockMarket: holding.stockMarket,
                fundMarket: holding.fundMarket,
                isArchived: holding.isArchived,
                archivedAt: holding.archivedAt
            )
        }

        guard resolvedCount > 0 else { return 0 }

        do {
            userPortfolioHoldings = enrichedHoldings
            rebuildAssetRows()
            try portfolioStore.save(enrichedHoldings, to: portfolioFileURL)
            return resolvedCount
        } catch {
            errorMessage = error.localizedDescription
            return 0
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
    }
}
