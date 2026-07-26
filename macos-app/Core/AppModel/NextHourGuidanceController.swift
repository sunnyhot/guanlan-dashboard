import Foundation

extension AppModel {
    var nextHourGuidanceScheduleText: String {
        "交易日 09:15、10:15、11:15、13:15、14:15；场外基金仅 14:50"
    }

    func loadNextHourGuidanceState() {
        guard let nextHourGuidanceFileURL else { return }
        do {
            nextHourGuidanceArchive = try NextHourGuidanceStore().load(from: nextHourGuidanceFileURL)
            if nextHourGuidanceReport != nil {
                nextHourGuidanceGenerationState = .succeeded
            }
        } catch {
            nextHourGuidanceError = "读取下一小时买卖建议失败：\(error.localizedDescription)"
        }
    }

    func restartNextHourGuidanceSchedulerLoop(immediate: Bool) {
        nextHourGuidanceSchedulerTask?.cancel()
        nextHourGuidanceSchedulerTask = Task { [weak self] in
            if immediate, let self {
                await self.runNextHourGuidanceIfNeeded()
                await self.runDailyTrendAnalysisIfNeeded()
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                await self.runNextHourGuidanceIfNeeded()
                await self.runDailyTrendAnalysisIfNeeded()
            }
        }
    }

    func runNextHourGuidanceIfNeeded(createdAt: String? = nil) async {
        guard trendSettings.provider.isConfigured else { return }
        guard trendGenerationState != .generating else { return }
        guard nextHourGuidanceGenerationState != .generating else { return }

        let timestamp = createdAt ?? Self.timestampString()
        guard let slot = NextHourGuidanceSchedule.default.dueSlot(
            at: timestamp,
            lastAttemptedSlotKey: nextHourGuidanceArchive.lastAttemptedSlotKey
        ) else {
            return
        }
        await generateNextHourGuidance(slot: slot, generatedAt: timestamp, userInitiated: false)
    }

    func startNextHourGuidance() {
        guard trendSettings.provider.isConfigured else {
            nextHourGuidanceError = NextHourGuidanceAgentError.missingConfiguration.localizedDescription
            return
        }
        let timestamp = Self.timestampString()
        let schedule = NextHourGuidanceSchedule.default
        guard let slot = schedule.dueSlot(
            at: timestamp,
            lastAttemptedSlotKey: nil
        ) ?? schedule.manualSlot(at: timestamp) else {
            nextHourGuidanceError = "无法识别当前时间，请稍后重试。"
            return
        }
        guard trendGenerationState != .generating,
              nextHourGuidanceGenerationState != .generating else {
            return
        }

        nextHourGuidanceGenerationTask?.cancel()
        nextHourGuidanceGenerationTask = Task { [weak self] in
            await self?.generateNextHourGuidance(
                slot: slot,
                generatedAt: timestamp,
                userInitiated: true
            )
            self?.nextHourGuidanceGenerationTask = nil
        }
    }

    func generateNextHourGuidance(
        slot: NextHourGuidanceSlot,
        generatedAt: String,
        userInitiated: Bool
    ) async {
        guard trendSettings.provider.isConfigured else {
            nextHourGuidanceGenerationState = .failed
            nextHourGuidanceError = NextHourGuidanceAgentError.missingConfiguration.localizedDescription
            return
        }
        guard nextHourGuidanceGenerationState != .generating else { return }

        nextHourGuidanceGenerationState = .generating
        nextHourGuidanceError = ""
        nextHourGuidanceArchive.lastAttemptedSlotKey = slot.key
        saveNextHourGuidanceArchive()

        if !activeUserPortfolioHoldings.isEmpty, !isRefreshingPortfolio {
            try? await refreshUserPortfolio(
                updateNotice: false,
                forceQuoteRefresh: true
            )
        }
        await refreshMarketIndices(
            kinds: [.sseComposite, .csi300, .chinext],
            updateNotice: false
        )

        let rows = nextHourEligibleRows(for: slot)
        guard !rows.isEmpty else {
            nextHourGuidanceGenerationState = .failed
            nextHourGuidanceError = slot.scope.includesOffExchangeFunds
                ? "当前没有可用于收盘前研判的持仓。"
                : "当前没有可盘中交易的 A 股、股票或场内基金持仓。"
            saveNextHourGuidanceArchive()
            return
        }

        let provider = trendSettings.provider.upgradedForTrendGeneration
        do {
            if trendProviderCapabilities?.providerFingerprint != provider.fingerprint
                || trendProviderCapabilities?.supportsToolCalls != true {
                let capabilities = try await trendCapabilityProbe(provider)
                trendProviderCapabilities = capabilities
                guard capabilities.supportsToolCalls else {
                    throw NextHourGuidanceAgentError.invalidSubmission([
                        "当前模型不支持工具调用"
                    ])
                }
            }

            let lookThroughResult = await makeNextHourLookThrough(
                rows: rows,
                generatedAt: generatedAt
            )
            let context = makeNextHourGuidanceContext(
                rows: rows,
                slot: slot,
                generatedAt: generatedAt,
                additionalWarnings: lookThroughResult.warnings
            )
            let researchSnapshot = makeNextHourResearchSnapshot(
                rows: rows,
                generatedAt: generatedAt,
                lookThrough: lookThroughResult.snapshot,
                sourceWarnings: context.marketDataWarnings + lookThroughResult.warnings
            )
            let report = try await nextHourGuidanceAgent.run(
                context: context,
                researchSnapshot: researchSnapshot,
                settings: provider,
                webSearchSettings: trendSettings.webSearch
            )
            saveTrendAgentRunArtifact(
                TrendAgentRunArtifact.makeNextHour(
                    snapshot: researchSnapshot,
                    settings: provider,
                    report: report,
                    trigger: userInitiated ? "manual" : "scheduled"
                ),
                trigger: userInitiated ? "manual" : "scheduled"
            )
            nextHourGuidanceArchive.report = report
            nextHourGuidanceArchive.lastCompletedSlotKey = slot.key
            nextHourGuidanceGenerationState = .succeeded
            saveNextHourGuidanceArchive()
            if userInitiated {
                noticeMessage = "下一小时买卖建议已更新。"
            }
            await nextHourGuidanceNotificationSender(report)
        } catch is CancellationError {
            nextHourGuidanceGenerationState = .failed
            nextHourGuidanceError = "下一小时买卖建议生成已取消。"
            saveNextHourGuidanceArchive()
        } catch {
            nextHourGuidanceGenerationState = .failed
            nextHourGuidanceError = error.localizedDescription
            saveNextHourGuidanceArchive()
        }
    }

    private func nextHourEligibleRows(
        for slot: NextHourGuidanceSlot
    ) -> [PersonalAssetAggregateRow] {
        personalAssetRows
            .filter { row in
                guard row.hasHolding || row.hasPending || row.activePlanCount > 0 else {
                    return false
                }
                if row.assetType == .stock {
                    return row.detectedMarket != .us && row.detectedMarket != .hk
                }
                if row.isOnExchangeFund {
                    return true
                }
                return slot.scope.includesOffExchangeFunds
                    && row.assetType == .fund
                    && row.detectedFundMarket != .onExchange
            }
            .sorted { $0.effectiveHoldingAmount > $1.effectiveHoldingAmount }
    }

    private func makeNextHourGuidanceContext(
        rows: [PersonalAssetAggregateRow],
        slot: NextHourGuidanceSlot,
        generatedAt: String,
        additionalWarnings: [String]
    ) -> NextHourGuidanceContext {
        let total = rows.reduce(0) { $0 + $1.effectiveHoldingAmount }
        let assets = rows.map { row in
            let quoteTime = nextHourQuoteTime(row)
            let quoteType = nextHourQuoteType(row)
            return NextHourGuidanceAssetContext(
                id: row.key,
                evidenceID: "local:next-hour:asset:\(row.key)",
                name: row.fundName,
                code: row.fundCode,
                assetType: nextHourAssetTypeText(row),
                status: row.combinedStatusText,
                weightPct: total > 0 ? row.effectiveHoldingAmount / total * 100 : nil,
                currentPrice: row.currentEstimatePrice ?? row.currentPrice,
                quoteTime: quoteTime,
                quoteSource: nextHourQuoteSource(row),
                quoteAssessment: TrendSourceFreshnessPolicy.assess(
                    quoteType: quoteType,
                    asOf: quoteTime,
                    receivedAt: generatedAt
                ),
                profitPct: row.profitPct,
                estimateChangePct: row.estimateChangePct,
                pendingTradeCount: row.pendingTradeCount,
                activePlanCount: row.activePlanCount
            )
        }
        let market = marketIndexQuotes.values
            .filter { [.sseComposite, .csi300, .chinext].contains($0.kind) }
            .sorted { $0.kind.rawValue < $1.kind.rawValue }
            .map {
                NextHourGuidanceMarketContext(
                    evidenceID: "market:index:\($0.kind.rawValue):\($0.quotedAt)",
                    name: $0.name,
                    price: $0.price,
                    changePct: $0.changePct,
                    quotedAt: $0.quotedAt,
                    sourceLabel: $0.sourceLabel,
                    quoteAssessment: TrendSourceFreshnessPolicy.assess(
                        quoteType: .indexQuote,
                        asOf: $0.quotedAt,
                        receivedAt: generatedAt
                    )
                )
            }
        let freshMarketCount = market.filter(\.quoteAssessment.isFreshForExecution).count
        let hasFreshAssetQuotes = assets.contains(where: \.quoteIsFresh)
        let marketDataIsFresh = freshMarketCount > 0 || hasFreshAssetQuotes
        var marketDataWarnings = additionalWarnings
        if market.isEmpty, !hasFreshAssetQuotes {
            marketDataWarnings.append("未取得上证、沪深300或创业板指数行情，风控规则禁止输出买入或卖出。")
        } else if freshMarketCount == 0, !hasFreshAssetQuotes {
            marketDataWarnings.append("大盘行情时间距当前超过 20 分钟，风控规则禁止输出买入或卖出。")
        } else if freshMarketCount == 0 {
            marketDataWarnings.append("大盘指数行情不够新；仅报价在 20 分钟内的标的可形成买卖建议，并应降低置信度。")
        }
        let staleAssetNames = assets.filter { !$0.quoteIsFresh }.map(\.name)
        if !staleAssetNames.isEmpty {
            marketDataWarnings.append(
                "以下标的报价超过 20 分钟或缺少准确时间，只允许持有：\(staleAssetNames.prefix(8).joined(separator: "、"))"
            )
        }
        if !trendSettings.webSearch.isConfigured {
            marketDataWarnings.append("未配置 Tavily 联网搜索，风控规则禁止输出买入或卖出。")
        }
        let latestActions = (trendReport?.actions ?? []).prefix(5).map {
            "\($0.title)：\($0.detail)"
        }
        let latestAssetConclusions = (trendReport?.assetTrends ?? []).prefix(12).map {
            "\($0.name)：\($0.impactText)；\($0.rationale)"
        }
        let scopeRule: String
        switch slot.scope {
        case .marketTrading:
            scopeRule = "本次只包含 A 股/股票和场内基金，不包含场外基金。"
        case .closingWindow:
            scopeRule = "这是 14:50 收盘前窗口；场外基金只能给出收盘前申赎或计划复核建议，不能描述为盘中成交。"
        case .manual:
            scopeRule = "这是用户手动触发的研判，已纳入场外基金；非交易时段不得把静态净值或估值描述为实时成交价格。"
        }
        let rules = [
            "本次有效窗口：\(slot.timeString) 至 \(String(slot.validUntil.suffix(5)))。",
            scopeRule,
            "缺少实时成交量、盘口或新闻时必须降低置信度，不得补造数据。",
        ]
        return NextHourGuidanceContext(
            generatedAt: generatedAt,
            slot: slot,
            assets: assets,
            market: market,
            marketDataIsFresh: marketDataIsFresh,
            marketDataWarnings: marketDataWarnings,
            latestTrendGeneratedAt: trendReport?.generatedAt,
            latestTrendHeadline: trendReport?.portfolio.headline,
            latestTrendActions: latestActions,
            latestAssetConclusions: latestAssetConclusions,
            dataRules: rules
        )
    }

    private func makeNextHourLookThrough(
        rows: [PersonalAssetAggregateRow],
        generatedAt: String
    ) async -> (snapshot: PortfolioLookThroughSnapshot?, warnings: [String]) {
        let fundCodes = rows.compactMap { row -> String? in
            guard row.assetType == .fund,
                  row.effectiveHoldingAmount > 0.001,
                  let code = row.fundCode,
                  !code.isEmpty else {
                return nil
            }
            return code
        }
        guard !fundCodes.isEmpty else { return (nil, []) }

        let batch = await fundLookThroughClient.fetchDisclosures(
            fundCodes: Array(Set(fundCodes)).sorted()
        )
        let snapshot = PortfolioLookThroughCalculator.make(
            rows: rows,
            disclosures: batch.disclosures,
            generatedAt: generatedAt
        )
        var warnings = batch.warnings
        if snapshot == nil {
            warnings.append("本次未形成可用的基金穿透快照；基金只能给出持有建议。")
        }
        return (snapshot, warnings)
    }

    private func makeNextHourResearchSnapshot(
        rows: [PersonalAssetAggregateRow],
        generatedAt: String,
        lookThrough: PortfolioLookThroughSnapshot?,
        sourceWarnings: [String]
    ) -> TrendResearchSnapshot {
        var fundEstimates: [String: TrendResearchFundEstimate] = [:]
        for row in rows {
            guard row.assetType == .fund,
                  let code = row.fundCode,
                  !code.isEmpty else {
                continue
            }
            fundEstimates[code] = TrendResearchFundEstimate(
                code: code,
                name: row.fundName,
                estimateChangePct: row.estimateChangePct,
                price: row.currentEstimatePrice ?? row.currentPrice,
                quotedAt: nextHourQuoteTime(row),
                sourceLabel: nextHourQuoteSource(row),
                quoteType: nextHourQuoteType(row)
            )
        }
        return TrendResearchSnapshotBuilder().build(
            rows: rows,
            summary: nil,
            platformPayload: nil,
            alfaPayload: nil,
            managerWatchEvents: [],
            marketIndexQuotes: marketIndexQuotes,
            fundEstimates: fundEstimates,
            lookThrough: lookThrough,
            watchSummary: managerWatchTimelineSummary,
            insightSummary: portfolioSnapshotInsightSummary,
            privacyMode: trendPrivacyMode,
            runID: UUID(),
            createdAt: generatedAt,
            dataAsOf: userPortfolioSnapshot?.refreshedAt ?? generatedAt,
            sourceWarnings: sourceWarnings,
            sourceStatuses: makeNextHourSourceStatuses(
                rows: rows,
                lookThrough: lookThrough,
                generatedAt: generatedAt
            )
        )
    }

    private func makeNextHourSourceStatuses(
        rows: [PersonalAssetAggregateRow],
        lookThrough: PortfolioLookThroughSnapshot?,
        generatedAt: String
    ) -> [TrendSourceStatus] {
        let quotedRows = rows.filter {
            $0.currentPrice != nil || $0.currentEstimatePrice != nil
        }
        let indexQuotes = marketIndexQuotes.values.filter {
            [.sseComposite, .csi300, .chinext].contains($0.kind)
        }
        let offExchangeFunds = rows.filter {
            $0.assetType == .fund && !$0.isOnExchangeFund
        }
        let offExchangeQuotes = offExchangeFunds.filter {
            $0.currentPrice != nil || $0.currentEstimatePrice != nil
        }
        let expectedDisclosureCount = Set(
            rows.compactMap { row -> String? in
                guard row.assetType == .fund else { return nil }
                return row.fundCode
            }
        ).count
        let disclosureState: TrendDataSourceState
        if expectedDisclosureCount == 0 {
            disclosureState = .notRequested
        } else if let lookThrough,
                  lookThrough.coveredFundCount == expectedDisclosureCount {
            disclosureState = .success
        } else {
            disclosureState = .failed
        }
        let disclosureAsOf = lookThrough?.disclosures.values
            .map(\.asOf)
            .filter { !$0.isEmpty }
            .max()

        return [
            TrendSourceStatus(
                source: .portfolioQuote,
                status: quotedRows.isEmpty ? .failed : .success,
                asOf: rows.compactMap { nextHourQuoteTime($0) }.max(),
                receivedAt: generatedAt,
                errorCode: quotedRows.isEmpty ? "no_eligible_quotes" : nil,
                itemCount: quotedRows.count
            ),
            TrendSourceStatus(
                source: .marketIndex,
                status: indexQuotes.isEmpty ? .failed : .success,
                asOf: indexQuotes.map(\.quotedAt).max(),
                receivedAt: generatedAt,
                errorCode: indexQuotes.isEmpty ? "no_index_quotes" : nil,
                itemCount: indexQuotes.count
            ),
            TrendSourceStatus(
                source: .fundNAV,
                status: offExchangeFunds.isEmpty
                    ? .notRequested
                    : (offExchangeQuotes.isEmpty ? .failed : .success),
                asOf: offExchangeFunds.compactMap { nextHourQuoteTime($0) }.max(),
                receivedAt: generatedAt,
                errorCode: !offExchangeFunds.isEmpty && offExchangeQuotes.isEmpty
                    ? "no_fund_nav_or_estimate"
                    : nil,
                itemCount: offExchangeQuotes.count
            ),
            TrendSourceStatus(
                source: .fundDisclosure,
                status: disclosureState,
                asOf: disclosureAsOf,
                receivedAt: generatedAt,
                errorCode: disclosureState == .failed ? "incomplete_fund_disclosure" : nil,
                itemCount: lookThrough?.coveredFundCount
            ),
            TrendSourceStatus(
                source: .qiemanAdjustment,
                status: .notRequested,
                receivedAt: generatedAt
            ),
            TrendSourceStatus(
                source: .alfaAdjustment,
                status: .notRequested,
                receivedAt: generatedAt
            ),
            TrendSourceStatus(
                source: .managerWatch,
                status: .notRequested,
                receivedAt: generatedAt
            ),
            TrendSourceStatus(
                source: .webSearch,
                status: trendSettings.webSearch.isConfigured ? .notRequested : .notConfigured,
                receivedAt: generatedAt
            ),
        ]
    }

    private func nextHourQuoteTime(_ row: PersonalAssetAggregateRow) -> String? {
        if row.assetType == .fund, !row.isOnExchangeFund {
            return row.holdingRow?.estimatePriceTime
                ?? row.holdingRow?.priceTime
                ?? row.holdingRow?.officialNavDate
        }
        return row.holdingRow?.priceTime ?? row.holdingRow?.resolvedPriceTime
    }

    private func nextHourQuoteSource(_ row: PersonalAssetAggregateRow) -> String? {
        if row.assetType == .fund,
           !row.isOnExchangeFund,
           row.holdingRow?.estimatePrice != nil {
            return "基金实时估值"
        }
        return row.holdingRow?.resolvedPriceSource ?? "本地持仓行情"
    }

    private func nextHourQuoteType(_ row: PersonalAssetAggregateRow) -> TrendQuoteType {
        guard row.assetType == .fund, !row.isOnExchangeFund else {
            return .lastTrade
        }
        if row.holdingRow?.estimatePrice != nil,
           row.holdingRow?.estimatePriceTime != nil {
            return .intradayEstimate
        }
        if row.holdingRow?.officialNavDate != nil {
            return .officialNAV
        }
        return .unknown
    }

    private func nextHourAssetTypeText(_ row: PersonalAssetAggregateRow) -> String {
        if row.assetType == .stock {
            return row.detectedMarket?.displayName ?? "A股"
        }
        return row.detectedFundMarket?.displayName ?? "场外基金"
    }

    private func saveNextHourGuidanceArchive() {
        guard let nextHourGuidanceFileURL else { return }
        do {
            try NextHourGuidanceStore().save(
                nextHourGuidanceArchive,
                to: nextHourGuidanceFileURL
            )
        } catch {
            nextHourGuidanceError = "保存下一小时买卖建议失败：\(error.localizedDescription)"
        }
    }
}
