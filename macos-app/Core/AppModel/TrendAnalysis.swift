import Foundation

extension AppModel {
    var enhancementTrendStatus: EnhancementTrendStatus {
        let generatedAt = lastTrendGeneratedAt ?? trendReport?.generatedAt
        let currentDay = trendDayString(from: Self.timestampString())
        let generatedDay = generatedAt.map { trendDayString(from: $0) }
        let stale = generatedDay.map { $0 != currentDay } ?? false
        let isProviderConfigured = trendSettings.provider.isConfigured
        let headline: String
        if let report = trendReport {
            headline = report.portfolio.headline
        } else if !lastTrendError.isEmpty {
            headline = lastTrendError
        } else {
            headline = isProviderConfigured ? "等待生成趋势分析" : "尚未配置趋势分析模型"
        }

        return EnhancementTrendStatus(
            isProviderConfigured: isProviderConfigured,
            generationState: trendGenerationState,
            lastGeneratedAt: generatedAt,
            headline: headline,
            externalSignalStatus: trendReport?.externalSignalStatus,
            isStale: stale
        )
    }

    var trendDashboardSummary: TrendDashboardSummary {
        TrendDashboardSummary.make(
            report: trendReport,
            trendStatus: enhancementTrendStatus,
            generationState: trendGenerationState,
            lastError: lastTrendError,
            progressLogs: trendProgressLogs
        )
    }

    func loadTrendAnalysisState() {
        if let trendAnalysisSettingsFileURL {
            do {
                trendSettings = try TrendAnalysisSettingsStore().load(from: trendAnalysisSettingsFileURL)
                trendPrivacyMode = trendSettings.defaultPrivacyMode
            } catch {
                lastTrendError = error.localizedDescription
            }
        }

        if let trendAnalysisReportFileURL {
            do {
                trendReport = try TrendAnalysisReportStore().load(from: trendAnalysisReportFileURL)
                lastTrendGeneratedAt = trendReport?.generatedAt
            } catch {
                lastTrendError = error.localizedDescription
            }
        }

        if let trendAgentRunLogFileURL {
            do {
                let logs = try TrendAgentRunLogStore().load(from: trendAgentRunLogFileURL)
                if let last = logs.last {
                    trendProgressLogs = logs
                    switch last.level {
                    case .error, .warning:
                        trendGenerationState = .failed
                        if lastTrendError.isEmpty {
                            lastTrendError = last.detail ?? last.message
                        }
                    case .success where last.message == "趋势分析完成":
                        trendGenerationState = .succeeded
                    case .info, .activity, .success:
                        trendGenerationState = .failed
                        if lastTrendError.isEmpty {
                            lastTrendError = "上次趋势分析未正常结束，最后阶段：\(last.message)"
                        }
                    }
                }
            } catch {
                if lastTrendError.isEmpty {
                    lastTrendError = "读取上次 Agent 日志失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func saveTrendAnalysisSettings() {
        trendSettings.normalizeDailyAutoAnalysisTimes()
        guard let trendAnalysisSettingsFileURL else { return }
        do {
            try TrendAnalysisSettingsStore().save(trendSettings, to: trendAnalysisSettingsFileURL)
        } catch {
            lastTrendError = error.localizedDescription
        }
    }

    func saveTrendAnalysisReport(_ report: TrendAnalysisReport) {
        guard let trendAnalysisReportFileURL else { return }
        do {
            try TrendAnalysisReportStore().save(report, to: trendAnalysisReportFileURL)
        } catch {
            lastTrendError = error.localizedDescription
        }
    }

    // MARK: - 连通性与能力检测

    /// 检测模型是否支持原生工具调用（内嵌 Agent 的硬性前提）。
    func checkTrendAIConnection() async {
        guard trendSettings.provider.isConfigured else {
            trendConnectionState = .failed
            trendProviderCapabilities = nil
            lastTrendConnectionMessage = OpenAICompatibleAgentClientError.missingConfiguration.localizedDescription
            lastTrendError = lastTrendConnectionMessage
            return
        }

        saveTrendAnalysisSettings()
        trendConnectionState = .checking
        lastTrendConnectionMessage = "正在检测 \(trendSettings.provider.model) 的工具调用能力..."
        lastTrendError = ""

        do {
            let capabilities = try await trendCapabilityProbe(trendSettings.provider)
            trendProviderCapabilities = capabilities
            if capabilities.supportsToolCalls {
                trendConnectionState = .succeeded
                let forced = capabilities.supportsForcedToolChoice ? "（支持指定函数 tool_choice）" : "（仅 auto 工具调用）"
                lastTrendConnectionMessage = "模型可用，支持工具调用：\(trendSettings.provider.model)\(forced)。"
            } else {
                trendConnectionState = .failed
                lastTrendConnectionMessage = "该模型仅返回普通文本，不支持工具调用，无法启动内嵌趋势 Agent。\(capabilities.detail)"
                lastTrendError = lastTrendConnectionMessage
            }
        } catch {
            trendConnectionState = .failed
            trendProviderCapabilities = nil
            lastTrendConnectionMessage = error.localizedDescription
            lastTrendError = error.localizedDescription
        }
    }

    // MARK: - 趋势分析主入口（内嵌 Agent）

    func generateTrendAnalysis(userInitiated: Bool, createdAt: String? = nil) async {
        let telemetryStart = PerformanceTelemetry.start()
        var telemetryResult = "completed"
        var telemetryProvider = "unknown"
        let telemetryTrigger = userInitiated ? "manual" : "scheduled"
        defer {
            PerformanceTelemetry.record(
                "trend.generate",
                startedAt: telemetryStart,
                metadata: [
                    "result": telemetryResult,
                    "provider": telemetryProvider,
                    "trigger": telemetryTrigger,
                    "toolCalls": "\(trendProviderCapabilities?.supportsToolCalls ?? false)"
                ]
            )
        }
        guard trendSettings.provider.isConfigured else {
            telemetryResult = "notConfigured"
            trendGenerationState = .failed
            lastTrendError = OpenAICompatibleAgentClientError.missingConfiguration.localizedDescription
            return
        }
        let generatedAt = createdAt ?? Self.timestampString()
        let autoAnalysisSlot = userInitiated ? nil : trendSettings.dueAutoAnalysisSlot(at: generatedAt)
        let provider = trendSettings.provider.upgradedForTrendGeneration
        telemetryProvider = provider.model
        trendGenerationState = .generating
        lastTrendError = ""
        trendProgressLogs = []
        trendSettings.defaultPrivacyMode = trendPrivacyMode
        let triggerText = userInitiated ? "手动分析" : "定时自动分析"
        if let trendAgentRunLogFileURL {
            try? TrendAgentRunLogStore().beginRun(
                at: trendAgentRunLogFileURL,
                trigger: userInitiated ? "manual" : "scheduled",
                model: provider.model,
                startedAt: generatedAt
            )
        }
        appendTrendProgress(
            "\(triggerText)已启动",
            detail: "模型：\(provider.model)；隐私：\(trendPrivacyMode.rawValue)；SEC：\(trendSettings.officialSources.isSECConfigured ? "已配置" : "未配置")；Alpha Vantage：\(trendSettings.alphaVantage.isConfigured ? "已配置" : "未配置")；Tavily：\(trendSettings.webSearch.isConfigured ? "已配置" : "未配置")",
            level: .activity
        )

        // 能力检测 fail-closed：仅当「当前 Provider 指纹对应 supportsToolCalls==true」才启动；
        // 指纹不符（首次或改了 Base URL/模型/Key）或尚无结果时，先自动探测一次。
        if trendProviderCapabilities?.providerFingerprint != provider.fingerprint
            || trendProviderCapabilities?.supportsToolCalls != true {
            appendTrendProgress("检测 \(provider.model) 的工具调用能力", level: .activity)
            do {
                let capabilities = try await trendCapabilityProbe(provider)
                trendProviderCapabilities = capabilities
                guard capabilities.supportsToolCalls else {
                    telemetryResult = "unsupportedModel"
                    trendGenerationState = .failed
                    lastTrendError = "该模型不支持工具调用，无法启动趋势 Agent。\(capabilities.detail)"
                    appendTrendProgress("模型不支持 Agent 工具调用", detail: lastTrendError, level: .error)
                    return
                }
                appendTrendProgress(
                    "模型工具调用能力可用",
                    detail: capabilities.detail,
                    level: .success
                )
            } catch {
                telemetryResult = "capabilityProbeFailed"
                trendGenerationState = .failed
                lastTrendError = "工具调用能力检测失败：\(error.localizedDescription)"
                appendTrendProgress("工具调用能力检测失败", detail: lastTrendError, level: .error)
                return
            }
        }

        appendTrendProgress("开始内嵌趋势 Agent：\(provider.model)", level: .activity)

        let marketSourceStatuses = await refreshTrendResearchMarketData(
            generatedAt: generatedAt
        )

        let fundCodes = personalAssetRows.compactMap { row -> String? in
            guard row.assetType == .fund,
                  row.effectiveHoldingAmount > 0.001,
                  let code = row.fundCode,
                  !code.isEmpty else {
                return nil
            }
            return code
        }
        var lookThrough: PortfolioLookThroughSnapshot?
        var lookThroughWarnings: [String] = []
        var fundDisclosureStatus = TrendSourceStatus(
            source: .fundDisclosure,
            status: .notRequested,
            receivedAt: generatedAt,
            detail: "当前组合没有需要穿透的基金持仓。"
        )
        if !fundCodes.isEmpty {
            appendTrendProgress(
                "读取基金底层资产披露",
                detail: "\(Set(fundCodes).count) 只基金；股票、债券、行业与资产配置",
                level: .activity
            )
            let batch = await fundLookThroughClient.fetchDisclosures(fundCodes: fundCodes)
            lookThrough = PortfolioLookThroughCalculator.make(
                rows: personalAssetRows,
                disclosures: batch.disclosures,
                generatedAt: generatedAt
            )
            lookThroughWarnings = batch.warnings
            let disclosureDates = batch.disclosures.values
                .map(\.asOf)
                .filter { !$0.isEmpty }
            let disclosureState: TrendDataSourceState
            if batch.disclosures.isEmpty {
                disclosureState = batch.warnings.isEmpty ? .successEmpty : .failed
            } else {
                disclosureState = .success
            }
            fundDisclosureStatus = TrendSourceStatus(
                source: .fundDisclosure,
                status: disclosureState,
                asOf: disclosureDates.max(),
                receivedAt: Self.timestampString(),
                errorCode: disclosureState == .failed ? "no_usable_disclosure" : nil,
                itemCount: batch.disclosures.count,
                detail: batch.warnings.isEmpty
                    ? nil
                    : "\(batch.warnings.count) 只基金披露读取失败或不完整。"
            )
            if let lookThrough {
                appendTrendProgress(
                    "基金穿透快照已生成",
                    detail: "覆盖 \(lookThrough.coveredFundCount)/\(lookThrough.expectedFundCount) 只基金；底层证券覆盖组合 \(String(format: "%.2f%%", lookThrough.disclosedSecurityCoveragePct))",
                    level: lookThrough.coveredFundCount > 0 ? .success : .warning
                )
            }
        }
        // 让投资方向模块复用本次冻结前生成的同一份穿透快照，避免 UI 再次抓取，
        // 也避免把报告中的一般板块观点误判成用户已持有板块。
        portfolioLookThroughSnapshot = lookThrough
        portfolioLookThroughSourceWarnings = lookThroughWarnings

        let snapshot = makeTrendResearchSnapshot(
            generatedAt: generatedAt,
            lookThrough: lookThrough,
            additionalSourceWarnings: lookThroughWarnings,
            sourceStatuses: marketSourceStatuses + [fundDisclosureStatus]
        )
        let officialText = trendSettings.officialSources.isSECConfigured
            ? "SEC 官方源已配置"
            : "SEC 官方源未配置"
        let searchText = trendSettings.webSearch.isConfigured ? "Tavily 联网搜索已配置" : "未配置联网搜索"
        let alphaText = trendSettings.alphaVantage.isConfigured
            ? "Alpha Vantage 已配置"
            : "Alpha Vantage 未配置"
        appendTrendProgress(
            "分析快照已冻结",
            detail: "\(snapshot.assets.count) 个标的；\(snapshot.marketQuotes.count) 条行情；\(officialText)；\(alphaText)；\(searchText)；隐私 \(snapshot.privacyMode.rawValue)",
            level: .success
        )

        appendTrendProgress(
            "准备请求模型：\(provider.model)",
            detail: trendTimeoutText(provider),
            level: .activity
        )

        do {
            let report = try await trendResearchAgent.run(
                snapshot: snapshot,
                settings: provider,
                webSearchSettings: trendSettings.webSearch,
                officialSourceSettings: trendSettings.officialSources,
                alphaVantageSettings: trendSettings.alphaVantage,
                eventHandler: { [weak self] event in
                    if case .auditArtifactReady(let artifact) = event {
                        self?.saveTrendAgentRunArtifact(
                            artifact,
                            trigger: userInitiated ? "manual" : "scheduled"
                        )
                    }
                    self?.handleTrendAgentEvent(event)
                }
            )
            trendReport = report
            lastTrendGeneratedAt = report.generatedAt
            if !userInitiated {
                trendSettings.lastAutoAnalysisDay = trendDayString(from: generatedAt)
                trendSettings.lastAutoAnalysisSlotKey = autoAnalysisSlot?.key
            }
            appendTrendProgress("保存趋势报告", level: .activity)
            saveTrendAnalysisReport(report)
            saveTrendAnalysisSettings()
            trendGenerationState = .succeeded
            appendTrendProgress("趋势分析完成", level: .success)
        } catch is CancellationError {
            telemetryResult = "cancelled"
            trendGenerationState = .failed
            lastTrendError = "趋势分析已取消。"
            appendTrendProgress("趋势分析已取消，保留上一次报告", level: .warning)
        } catch {
            telemetryResult = "failed"
            trendGenerationState = .failed
            lastTrendError = error.localizedDescription
            let failureAlreadyLogged = trendProgressLogs.last.map {
                $0.level == .error && $0.detail == error.localizedDescription
            } ?? false
            if !failureAlreadyLogged {
                appendTrendProgress(
                    "趋势分析失败",
                    detail: error.localizedDescription,
                    level: .error
                )
            }
        }
    }

    // MARK: - 生成任务管理（支持取消）

    /// 由 UI 触发：取消上一次（若有）并启动新的趋势分析任务。
    func startTrendAnalysis(userInitiated: Bool) {
        trendGenerationTask?.cancel()
        trendGenerationTask = Task { [weak self] in
            await self?.generateTrendAnalysis(userInitiated: userInitiated, createdAt: nil)
            self?.trendGenerationTask = nil
        }
    }

    /// 取消正在进行的趋势分析；Agent 循环会在下一个取消点停止，并保留上一次报告。
    func cancelTrendAnalysis() {
        trendGenerationTask?.cancel()
    }

    func runDailyTrendAnalysisIfNeeded(createdAt: String? = nil) async {
        guard trendSettings.dailyAutoAnalysisEnabled else { return }
        guard trendSettings.provider.isConfigured else { return }
        guard trendGenerationState != .generating else { return }
        guard nextHourGuidanceGenerationState != .generating else { return }
        guard decisionCaseResearchState != .generating else { return }

        let generatedAt = createdAt ?? Self.timestampString()
        trendSettings.normalizeDailyAutoAnalysisTimes()
        guard trendSettings.dueAutoAnalysisSlot(at: generatedAt) != nil else { return }

        await generateTrendAnalysis(userInitiated: false, createdAt: generatedAt)
    }

    // MARK: - 快照组装

    private func makeTrendResearchSnapshot(
        generatedAt: String,
        lookThrough: PortfolioLookThroughSnapshot?,
        additionalSourceWarnings: [String],
        sourceStatuses: [TrendSourceStatus]
    ) -> TrendResearchSnapshot {
        let extendedSourceStatuses = sourceStatuses + trendSignalSourceStatuses(
            receivedAt: generatedAt
        ) + [
            TrendSourceStatus(
                source: .officialSource,
                status: trendSettings.officialSources.isSECConfigured ? .notRequested : .notConfigured,
                receivedAt: generatedAt,
                detail: trendSettings.officialSources.isSECConfigured
                    ? "等待 Agent 优先查询 SEC 官方披露。"
                    : "SEC 官方源需要启用并填写联系邮箱。"
            ),
            TrendSourceStatus(
                source: .webSearch,
                status: trendSettings.webSearch.isConfigured ? .notRequested : .notConfigured,
                receivedAt: generatedAt,
                detail: trendSettings.webSearch.isConfigured
                    ? "等待 Agent 按研究目标发起联网搜索。"
                    : "未配置 Tavily API Key。"
            ),
            TrendSourceStatus(
                source: .alphaVantage,
                status: trendSettings.alphaVantage.isConfigured ? .notRequested : .notConfigured,
                receivedAt: generatedAt,
                detail: trendSettings.alphaVantage.isConfigured
                    ? "等待 Agent 在官方源之后选择结构化数据补充。"
                    : "未启用或未填写 Alpha Vantage API Key。"
            )
        ]
        var sourceWarnings = extendedSourceStatuses.compactMap(\.warningText)
        sourceWarnings.append(contentsOf: additionalSourceWarnings)
        sourceWarnings.append(contentsOf: lookThrough?.warnings ?? [])
        sourceWarnings = Array(Set(sourceWarnings)).sorted()

        let sourceAsOf = extendedSourceStatuses.compactMap(\.asOf).max()

        return TrendResearchSnapshotBuilder().build(
            rows: personalAssetRows,
            summary: personalAssetSummary,
            platformPayload: platformPayload,
            alfaPayload: alfaPayload,
            managerWatchEvents: managerWatchTimelineEvents,
            marketIndexQuotes: marketIndexQuotes,
            fundEstimates: makeTrendResearchFundEstimates(generatedAt: generatedAt),
            lookThrough: lookThrough,
            watchSummary: managerWatchTimelineSummary,
            insightSummary: portfolioSnapshotInsightSummary,
            privacyMode: trendPrivacyMode,
            runID: UUID(),
            createdAt: generatedAt,
            dataAsOf: sourceAsOf ?? generatedAt,
            sourceWarnings: sourceWarnings,
            sourceStatuses: extendedSourceStatuses
        )
    }

    /// 从个人持仓估值行组装基金估值（已持有基金的最可靠来源）。非持有标的不纳入。
    private func makeTrendResearchFundEstimates(
        generatedAt: String
    ) -> [String: TrendResearchFundEstimate] {
        var estimates: [String: TrendResearchFundEstimate] = [:]
        for row in personalAssetRows {
            guard let code = row.fundCode, !code.isEmpty, estimates[code] == nil else { continue }
            let quote = trendFundQuote(row)
            estimates[code] = TrendResearchFundEstimate(
                code: code,
                name: row.fundName,
                estimateChangePct: row.estimateChangePct,
                price: quote.price,
                quotedAt: quote.time,
                sourceLabel: quote.source,
                quoteType: quote.type
            )
        }
        return estimates
    }

    private func refreshTrendResearchMarketData(
        generatedAt: String
    ) async -> [TrendSourceStatus] {
        var statuses: [TrendSourceStatus] = []

        appendTrendProgress(
            "刷新趋势研判行情",
            detail: "个人持仓报价与主要市场指数",
            level: .activity
        )

        if activeUserPortfolioHoldings.isEmpty {
            statuses.append(
                TrendSourceStatus(
                    source: .portfolioQuote,
                    status: .successEmpty,
                    receivedAt: generatedAt,
                    itemCount: 0,
                    detail: "当前没有有效个人持仓。"
                )
            )
        } else if isRefreshingPortfolio {
            statuses.append(
                TrendSourceStatus(
                    source: .portfolioQuote,
                    status: .fetching,
                    asOf: personalAssetRows.compactMap(trendQuoteTime).max(),
                    receivedAt: generatedAt,
                    itemCount: personalAssetRows.filter {
                        $0.currentPrice != nil || $0.currentEstimatePrice != nil
                    }.count,
                    detail: "已有持仓刷新仍在进行，本次不会把旧报价标记为刷新成功。"
                )
            )
        } else {
            do {
                try await refreshUserPortfolio(
                    updateNotice: false,
                    forceQuoteRefresh: true
                )
                let quotedRows = personalAssetRows.filter {
                    $0.currentPrice != nil || $0.currentEstimatePrice != nil
                }
                statuses.append(
                    TrendSourceStatus(
                        source: .portfolioQuote,
                        status: quotedRows.isEmpty ? .successEmpty : .success,
                        asOf: personalAssetRows.compactMap(trendQuoteTime).max(),
                        receivedAt: Self.timestampString(),
                        itemCount: quotedRows.count
                    )
                )
            } catch {
                statuses.append(
                    TrendSourceStatus(
                        source: .portfolioQuote,
                        status: .failed,
                        asOf: personalAssetRows.compactMap(trendQuoteTime).max(),
                        receivedAt: Self.timestampString(),
                        errorCode: "portfolio_refresh_failed",
                        itemCount: personalAssetRows.filter {
                            $0.currentPrice != nil || $0.currentEstimatePrice != nil
                        }.count,
                        detail: error.localizedDescription
                    )
                )
                appendTrendProgress(
                    "个人持仓行情刷新失败，继续使用已有快照并降级",
                    detail: error.localizedDescription,
                    level: .warning
                )
            }
        }

        await refreshMarketIndices(
            kinds: MarketIndexKind.allCases,
            updateNotice: false
        )
        let indexReceivedAt = Self.timestampString()
        let availableIndices = MarketIndexKind.allCases.compactMap {
            marketIndexQuotes[$0]
        }
        statuses.append(
            TrendSourceStatus(
                source: .marketIndex,
                status: availableIndices.isEmpty ? .failed : .success,
                asOf: availableIndices.map(\.quotedAt).filter { !$0.isEmpty }.max(),
                receivedAt: indexReceivedAt,
                errorCode: availableIndices.isEmpty ? "empty_index_response" : nil,
                itemCount: availableIndices.count,
                detail: availableIndices.isEmpty
                    ? "主要市场指数刷新没有取得可用报价。"
                    : nil
            )
        )

        let fundQuotes = personalAssetRows.filter {
            $0.assetType == .fund
                && ($0.currentPrice != nil || $0.currentEstimatePrice != nil)
        }
        statuses.append(
            TrendSourceStatus(
                source: .fundNAV,
                status: fundQuotes.isEmpty ? .successEmpty : .success,
                asOf: fundQuotes.compactMap(trendQuoteTime).max(),
                receivedAt: Self.timestampString(),
                itemCount: fundQuotes.count
            )
        )

        appendTrendProgress(
            "趋势研判行情刷新完成",
            detail: "持仓报价 \(statuses.first { $0.source == .portfolioQuote }?.itemCount ?? 0) 条；指数 \(availableIndices.count) 条",
            level: availableIndices.isEmpty ? .warning : .success
        )
        return statuses
    }

    private func trendSignalSourceStatuses(
        receivedAt: String
    ) -> [TrendSourceStatus] {
        [
            platformSourceStatus(
                source: .qiemanAdjustment,
                payload: platformPayload,
                receivedAt: receivedAt
            ),
            platformSourceStatus(
                source: .alfaAdjustment,
                payload: alfaPayload,
                receivedAt: receivedAt
            ),
            managerSourceStatus(receivedAt: receivedAt),
        ]
    }

    private func platformSourceStatus(
        source: TrendDataSource,
        payload: PlatformPayload?,
        receivedAt: String
    ) -> TrendSourceStatus {
        guard let payload else {
            return TrendSourceStatus(
                source: source,
                status: .notRequested,
                receivedAt: receivedAt,
                detail: "本次分析没有主动刷新该平台信号，仅读取当前 App 快照。"
            )
        }
        let actions = payload.actions ?? []
        if let error = payload.error?.trimmingCharacters(in: .whitespacesAndNewlines),
           !error.isEmpty {
            return TrendSourceStatus(
                source: source,
                status: .failed,
                asOf: actions.compactMap { $0.txnDate ?? $0.createdAt }.max(),
                receivedAt: receivedAt,
                errorCode: "platform_payload_error",
                itemCount: actions.count,
                detail: error
            )
        }
        return TrendSourceStatus(
            source: source,
            status: actions.isEmpty ? .successEmpty : .success,
            asOf: actions.compactMap { $0.txnDate ?? $0.createdAt }.max(),
            receivedAt: receivedAt,
            itemCount: actions.count
        )
    }

    private func managerSourceStatus(
        receivedAt: String
    ) -> TrendSourceStatus {
        guard managerWatchSettings.isEnabled else {
            return TrendSourceStatus(
                source: .managerWatch,
                status: .notConfigured,
                receivedAt: receivedAt,
                detail: "主理人巡检未启用。"
            )
        }
        let events = managerWatchTimelineEvents
        let latest = events.max { $0.occurredAt < $1.occurredAt }
        let status: TrendDataSourceState
        if managerWatchSettings.lastErrorMessage != nil || latest?.kind == .failed {
            status = .failed
        } else if managerWatchSettings.lastCheckedAt == nil {
            status = .notRequested
        } else {
            status = events.isEmpty ? .successEmpty : .success
        }
        return TrendSourceStatus(
            source: .managerWatch,
            status: status,
            asOf: latest.map { ISO8601DateFormatter().string(from: $0.occurredAt) },
            receivedAt: receivedAt,
            errorCode: status == .failed ? "manager_watch_failed" : nil,
            itemCount: events.count,
            detail: managerWatchSettings.lastErrorMessage ?? latest?.errorMessage
        )
    }

    private func trendFundQuote(
        _ row: PersonalAssetAggregateRow
    ) -> (price: Double?, time: String?, source: String?, type: TrendQuoteType) {
        guard let holding = row.holdingRow else {
            return (row.currentPrice, nil, "本地持仓快照", .unknown)
        }
        if row.detectedFundMarket == .offExchange {
            if let estimate = holding.estimatePrice {
                return (
                    estimate,
                    holding.estimatePriceTime,
                    "场外基金盘中估值",
                    .intradayEstimate
                )
            }
            if let official = holding.officialNav {
                return (
                    official,
                    holding.officialNavDate,
                    holding.resolvedPriceSource ?? "场外基金官方净值",
                    .officialNAV
                )
            }
        }
        return (
            holding.currentPrice ?? holding.officialNav,
            holding.priceTime ?? holding.officialNavDate,
            holding.resolvedPriceSource ?? "本地持仓行情",
            row.usesMarketTradeColumns ? .lastTrade : .officialNAV
        )
    }

    private func trendQuoteTime(
        _ row: PersonalAssetAggregateRow
    ) -> String? {
        if row.assetType == .fund {
            return trendFundQuote(row).time
        }
        return row.holdingRow?.priceTime ?? row.holdingRow?.resolvedPriceTime
    }

    // MARK: - Agent 事件 → 进度日志

    @MainActor
    private func handleTrendAgentEvent(_ event: TrendResearchAgentEvent) {
        switch event {
        case .started:
            appendTrendProgress("内嵌趋势 Agent 已启动", level: .activity)
        case .harnessConfigured(
            let maxTurns,
            let maxToolCalls,
            let preferredWebSearches,
            let maxWebSearches
        ):
            appendTrendProgress(
                "Agent Harness 预算已配置",
                detail: "最多 \(maxTurns) 轮、\(maxToolCalls) 次工具调用；Tavily 建议 \(preferredWebSearches) 次、硬上限 \(maxWebSearches) 次；提交与修复预算已预留。",
                level: .info
            )
        case .harnessGuidance(let message):
            appendTrendProgress("Harness 正在收敛研究", detail: message, level: .warning)
        case .turnStarted(let turn):
            appendTrendProgress("进入第 \(turn) 轮", level: .info)
        case .modelRequestStarted:
            appendTrendProgress("正在等待模型响应", level: .activity)
        case .modelRequestTimedOut(let turn, let timeout, let recoveryAttempt, let maxRecoveryAttempts):
            appendTrendProgress(
                "模型请求超时，正在自动收敛重试",
                detail: "第 \(turn) 轮在 \(Int(timeout.rounded())) 秒内未完成；恢复 \(recoveryAttempt)/\(maxRecoveryAttempts)",
                level: .warning
            )
        case .modelStreamProgress(let turn, let progress):
            switch progress {
            case .firstChunk(let elapsed):
                appendTrendProgress(
                    "已收到首个流式分片",
                    detail: "第 \(turn) 轮；首包耗时 \(String(format: "%.1f", elapsed)) 秒",
                    level: .info
                )
            case .active(let chunkCount, let elapsed):
                appendTrendProgress(
                    "模型仍在流式生成",
                    detail: "第 \(turn) 轮；已收到 \(chunkCount) 个分片；耗时 \(String(format: "%.1f", elapsed)) 秒",
                    level: .activity
                )
            case .finished(let chunkCount, let elapsed, let finishReason):
                appendTrendProgress(
                    "模型流式输出已结束",
                    detail: "第 \(turn) 轮；\(chunkCount) 个分片；耗时 \(String(format: "%.1f", elapsed)) 秒；结束原因 \(finishReason ?? "未提供")",
                    level: .success
                )
            }
        case .modelResponseReceived(_, let duration):
            appendTrendProgress(
                "已收到模型响应",
                detail: "耗时 \(String(format: "%.1f", duration)) 秒",
                level: .success
            )
        case .modelCorrection(let message):
            appendTrendProgress("模型输出需要修正", detail: message, level: .warning)
        case .toolStarted(let name):
            appendTrendProgress(
                "开始：\(trendToolDisplayName(name))",
                detail: "工具：\(name)",
                level: .activity
            )
        case .toolFinished(let name, let summary):
            let displayName = trendToolDisplayName(name)
            let level: TrendProgressLog.Level = summary.hasPrefix("失败") ? .warning : .success
            let startedMessage = "开始：\(displayName)"
            // 把对应的"开始"条目原地更新为"完成"：同一行、颜色/图标变化，不再追加新行。
            if let index = trendProgressLogs.lastIndex(where: { $0.message == startedMessage && $0.level == .activity }) {
                let original = trendProgressLogs[index]
                trendProgressLogs[index] = TrendProgressLog(
                    id: original.id,
                    timestamp: original.timestamp,
                    message: "完成：\(displayName)",
                    detail: summary.isEmpty ? original.detail : "结果：\(summary)",
                    level: level
                )
            } else {
                // "开始"条目可能已被裁剪，回退为追加。
                appendTrendProgress("完成：\(displayName)", detail: "结果：\(summary)", level: level)
            }
        case .reportValidationFailed(let errors, let remaining):
            appendTrendProgress(
                "报告校验失败，正在自动修正",
                detail: "剩余 \(remaining) 次\n\(errors.joined(separator: "\n"))",
                level: .warning
            )
        case .auditArtifactReady:
            break
        case .completed(let duration):
            appendTrendProgress(
                "Agent 已生成有效报告",
                detail: "总耗时 \(String(format: "%.1f", duration)) 秒",
                level: .success
            )
        case .failed(let message):
            appendTrendProgress("Agent 执行失败", detail: message, level: .error)
        case .cancelled:
            appendTrendProgress("Agent 已取消", level: .warning)
        }
    }

    func saveTrendAgentRunArtifact(
        _ artifact: TrendAgentRunArtifact,
        trigger: String
    ) {
        guard let trendAgentRunArtifactsDirectoryURL else { return }
        do {
            try TrendAgentRunArtifactStore().save(
                artifact.replacingTrigger(trigger),
                in: trendAgentRunArtifactsDirectoryURL
            )
            appendTrendProgress("结构化审计产物已保存", level: .success)
        } catch {
            appendTrendProgress(
                "结构化审计产物保存失败",
                detail: error.localizedDescription,
                level: .warning
            )
        }
    }

    // MARK: - 进度与工具方法

    private func trendDayString(from timestamp: String) -> String {
        let trimmed = timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return trimmed }
        return String(trimmed.prefix(10))
    }

    private func appendTrendProgress(
        _ message: String,
        detail: String? = nil,
        level: TrendProgressLog.Level = .info
    ) {
        let entry = TrendProgressLog(
            timestamp: Self.timestampString(),
            message: message,
            detail: detail,
            level: level
        )
        trendProgressLogs.append(entry)
        if trendProgressLogs.count > 50 {
            trendProgressLogs.removeFirst(trendProgressLogs.count - 50)
        }
        if let trendAgentRunLogFileURL {
            try? TrendAgentRunLogStore().append(entry, to: trendAgentRunLogFileURL)
        }
    }

    private func trendToolDisplayName(_ name: String) -> String {
        switch name {
        case "get_portfolio_overview":
            return "读取组合概览"
        case "get_portfolio_assets":
            return "读取持仓明细"
        case "get_fund_lookthrough":
            return "读取基金底层资产"
        case "get_market_snapshot":
            return "读取市场快照"
        case "web_search":
            return "Tavily 搜索行业与政策"
        case "submit_trend_report":
            return "校验并提交趋势报告"
        case TrendReportModuleToolName.overview:
            return "提交组合判断模块"
        case TrendReportModuleToolName.market:
            return "提交市场与板块模块"
        case TrendReportModuleToolName.assetBatch:
            return "分批提交持仓基金趋势"
        case TrendReportModuleToolName.actions:
            return "提交操作与风险模块"
        default:
            return name
        }
    }

    private func trendTimeoutText(_ settings: TrendAIProviderSettings) -> String {
        let perRequest = min(
            settings.timeoutSeconds,
            TrendResearchRunPolicy.defaultPerRequestTimeoutSeconds
        )
        return "单轮生成硬上限 \(Int(perRequest.rounded())) 秒；整体上限 \(Int(TrendResearchRunPolicy.defaultTotalTimeoutSeconds.rounded())) 秒；单轮超时自动收敛重试 \(TrendResearchRunPolicy.defaultMaxRequestTimeoutRecoveries) 次"
    }
}
