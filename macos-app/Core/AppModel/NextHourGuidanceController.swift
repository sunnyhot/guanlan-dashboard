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
            nextHourGuidanceError = "读取下一小时指引失败：\(error.localizedDescription)"
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
        guard let slot = NextHourGuidanceSchedule.default.dueSlot(
            at: timestamp,
            lastAttemptedSlotKey: nil
        ) else {
            noticeMessage = "当前不在下一小时指引运行窗口（交易日 09:15–11:30、13:15–15:00）。"
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
            try? await refreshUserPortfolio(updateNotice: false)
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

            let context = makeNextHourGuidanceContext(
                rows: rows,
                slot: slot,
                generatedAt: generatedAt
            )
            let report = try await nextHourGuidanceAgent.run(
                context: context,
                settings: provider
            )
            nextHourGuidanceArchive.report = report
            nextHourGuidanceArchive.lastCompletedSlotKey = slot.key
            nextHourGuidanceGenerationState = .succeeded
            saveNextHourGuidanceArchive()
            if userInitiated {
                noticeMessage = "下一小时操作指引已更新。"
            }
            await nextHourGuidanceNotificationSender(report)
        } catch is CancellationError {
            nextHourGuidanceGenerationState = .failed
            nextHourGuidanceError = "下一小时操作指引生成已取消。"
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
        generatedAt: String
    ) -> NextHourGuidanceContext {
        let total = rows.reduce(0) { $0 + $1.effectiveHoldingAmount }
        let assets = rows.map { row in
            NextHourGuidanceAssetContext(
                id: row.key,
                name: row.fundName,
                code: row.fundCode,
                assetType: nextHourAssetTypeText(row),
                status: row.combinedStatusText,
                weightPct: total > 0 ? row.effectiveHoldingAmount / total * 100 : nil,
                currentPrice: row.currentPrice,
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
                    name: $0.name,
                    price: $0.price,
                    changePct: $0.changePct,
                    quotedAt: $0.quotedAt
                )
            }
        let latestActions = (trendReport?.actions ?? []).prefix(5).map {
            "\($0.title)：\($0.detail)"
        }
        let latestAssetConclusions = (trendReport?.assetTrends ?? []).prefix(12).map {
            "\($0.name)：\($0.impactText)；\($0.rationale)"
        }
        let rules = [
            "本次有效窗口：\(slot.timeString) 至 \(String(slot.validUntil.suffix(5)))。",
            slot.scope.includesOffExchangeFunds
                ? "这是 14:50 收盘前窗口；场外基金只能给出收盘前申赎或计划复核建议，不能描述为盘中成交。"
                : "本次只包含 A 股/股票和场内基金，不包含场外基金。",
            "缺少实时成交量、盘口或新闻时必须降低置信度，不得补造数据。",
        ]
        return NextHourGuidanceContext(
            generatedAt: generatedAt,
            slot: slot,
            assets: assets,
            market: market,
            latestTrendGeneratedAt: trendReport?.generatedAt,
            latestTrendHeadline: trendReport?.portfolio.headline,
            latestTrendActions: latestActions,
            latestAssetConclusions: latestAssetConclusions,
            dataRules: rules
        )
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
            nextHourGuidanceError = "保存下一小时指引失败：\(error.localizedDescription)"
        }
    }
}
