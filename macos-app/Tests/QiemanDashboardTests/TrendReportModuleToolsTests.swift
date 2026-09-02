import XCTest
@testable import QiemanDashboard

final class TrendReportModuleToolsTests: XCTestCase {
    func testAssetBatchDecodesCommonAgentDirectionAliases() throws {
        let json = """
        {
          "assetTrends": [{
            "name": "测试基金",
            "code": "000001",
            "sector": "A股",
            "impactText": "涨跌归因：底层半导体持仓上涨，带动基金净值走强。",
            "horizons": [{
              "horizon": "short",
              "direction": "up",
              "confidence": {"score": 70, "label": "中"},
              "rationale": "当日走势偏强。",
              "counterSignals": []
            }],
            "rationale": "结合当日行情判断。",
            "counterSignals": []
          }]
        }
        """

        let module = try JSONDecoder().decode(
            TrendReportAssetBatchModule.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(module.assetTrends.first?.horizons.first?.direction, .bullish)
    }

    func testUnknownAgentDirectionFallsBackToUncertainAndEncodingStaysCanonical() throws {
        let decoded = try JSONDecoder().decode(
            TrendDirection.self,
            from: Data("\"unexpected-direction\"".utf8)
        )
        XCTAssertEqual(decoded, .uncertain)

        let encoded = try JSONEncoder().encode(TrendDirection.neutralPositive)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"neutralPositive\"")
    }

    func testDraftAdvancesInOrderAndBatchesFundAssets() async throws {
        let codes = (1...10).map { String(format: "%06d", $0) }
        let store = TrendReportDraftStore(expectedFundCodes: codes)
        let base = TrendAnalysisReport.fixture(
            generatedAt: "2026-07-26 10:00:00",
            externalSignalStatus: .partial
        )

        var progress = await store.progress()
        XCTAssertEqual(progress.nextToolName, TrendReportModuleToolName.overview)
        XCTAssertEqual(progress.totalSections, 5)

        try await store.storeOverview(
            TrendReportOverviewModule(
                portfolio: base.portfolio,
                horizons: base.horizons
            )
        )
        progress = await store.progress()
        XCTAssertEqual(progress.nextToolName, TrendReportModuleToolName.market)

        try await store.storeMarket(
            TrendReportMarketModule(
                marketOutlook: [makeMarketOutlook()],
                sectors: [],
                opportunities: []
            )
        )
        progress = await store.progress()
        XCTAssertEqual(progress.nextToolName, TrendReportModuleToolName.assetBatch)
        XCTAssertEqual(progress.remainingFundCodes.count, 10)

        try await store.storeAssetBatch(
            TrendReportAssetBatchModule(
                assetTrends: codes.prefix(TrendReportDraftStore.assetBatchSize).map { makeAsset(code: $0) }
            )
        )
        progress = await store.progress()
        XCTAssertEqual(progress.nextToolName, TrendReportModuleToolName.assetBatch)
        XCTAssertEqual(progress.remainingFundCodes, [codes[8], codes[9]])

        try await store.storeAssetBatch(
            TrendReportAssetBatchModule(
                assetTrends: codes.suffix(2).map { makeAsset(code: $0) }
            )
        )
        progress = await store.progress()
        XCTAssertEqual(progress.nextToolName, TrendReportModuleToolName.actions)

        try await store.storeActions(
            TrendReportActionsModule(
                keyAssets: [],
                actions: [],
                warnings: [],
                disclaimer: "非投资建议，仅供个人研究参考。"
            )
        )
        progress = await store.progress()
        XCTAssertTrue(progress.isComplete)

        let snapshot = makeSnapshot(codes: codes)
        let assembled = await store.assembledReport(snapshot: snapshot)
        XCTAssertEqual(assembled?.assetTrends.compactMap(\.code), codes)
    }

    func testDraftRejectsEmptyMarketView() async throws {
        let store = TrendReportDraftStore(expectedFundCodes: [])

        do {
            try await store.storeMarket(
                TrendReportMarketModule(
                    marketOutlook: [],
                    sectors: [],
                    opportunities: []
                )
            )
            XCTFail("Expected empty market view rejection")
        } catch let error as TrendReportDraftError {
            XCTAssertTrue(error.localizedDescription.contains("至少提交一项"))
        }
    }

    func testDraftAcceptsOversizedAssetBatchInsteadOfRejecting() async throws {
        let codes = (1...9).map { String(format: "%06d", $0) }
        let store = TrendReportDraftStore(expectedFundCodes: codes)

        // 2026-09-01 根治:超批不再拒批(2026-08-31 实证模型把 24 只塞进一批,
        // 拒批后 fanout 修复轮 418s 仍失败,整段 874s 白烧)。照常逐只校验入库,
        // remaining 自然收缩;schema 的 maxItems 仍是输出规模指导。
        try await store.storeAssetBatch(
            TrendReportAssetBatchModule(
                assetTrends: codes.map { makeAsset(code: $0) }
            )
        )
        let progress = await store.progress()
        XCTAssertTrue(progress.remainingFundCodes.isEmpty, "9 只一批应全部入库")
    }

    func testDraftPrefixesMissingAttributionConservatively() async throws {
        // closeReview 基线预填 overview/market/actions,便于读回暂存后的条目。
        let store = TrendReportDraftStore(
            expectedFundCodes: ["000001"],
            scope: .closeReview,
            baselineReport: reportWithAssets([makeAsset(code: "000001")])
        )
        let invalid = TrendAssetView(
            id: "asset-000001",
            name: "测试基金",
            code: "000001",
            sector: "A股",
            impactText: "组合核心持仓，穿透集中于若干半导体股票。",
            horizons: [],
            rationale: "基于当前持仓观察。",
            counterSignals: ["若行情变化则重新评估。"]
        )

        // 2026-09-01 根治:无前缀不再拒批(2026-08-31 实证同一批 8 只基金连续
        // 4 轮不写前缀耗尽修复预算),由 App 保守补「原因待确认：」,原文保留。
        // (closeReview 已接管 market 模块,基线不再预填,需显式提交以便组装。)
        try await store.storeMarket(
            TrendReportMarketModule(marketOutlook: [makeMarketOutlook()], sectors: [], opportunities: [])
        )
        try await store.storeAssetBatch(TrendReportAssetBatchModule(assetTrends: [invalid]))

        let assembled = await store.assembledReport(snapshot: makeSnapshot(codes: ["000001"]))
        let stored = try XCTUnwrap(assembled?.assetTrends.first)
        XCTAssertTrue(stored.impactText.hasPrefix("原因待确认："))
        XCTAssertTrue(stored.impactText.contains("组合核心持仓"), "原文保留为描述")
        XCTAssertEqual(stored.horizons.count, 3, "缺 horizons 由 App 合成保守三周期")
    }

    func testDraftPrefixSelectionFollowsCausalEvidence() async throws {
        let store = TrendReportDraftStore(
            expectedFundCodes: ["000001", "000002"],
            scope: .closeReview,
            baselineReport: reportWithAssets([makeAsset(code: "000001"), makeAsset(code: "000002")])
        )
        let withCausal = TrendAssetView(
            id: "asset-000001",
            name: "基金一",
            code: "000001",
            sector: "A股",
            impactText: "重仓股上涨带动净值回升。",
            horizons: [],
            rationale: "观察。",
            counterSignals: [],
            claimEvidence: TrendClaimEvidence(
                supportingEvidenceIDs: ["market:stock:600519:2026-08-31 16:00:00"]
            )
        )
        let withoutCausal = TrendAssetView(
            id: "asset-000002",
            name: "基金二",
            code: "000002",
            sector: "A股",
            impactText: "净值微跌，来源不明。",
            horizons: [],
            rationale: "观察。",
            counterSignals: []
        )

        try await store.storeMarket(
            TrendReportMarketModule(marketOutlook: [makeMarketOutlook()], sectors: [], opportunities: [])
        )
        try await store.storeAssetBatch(
            TrendReportAssetBatchModule(assetTrends: [withCausal, withoutCausal])
        )

        // 前缀选择 = 因果证据判定:supporting 含 market:stock: → 「涨跌归因：」;
        // 否则 → 「原因待确认：」(与 validationMessage 同一规则,确定性推导)。
        let assembled = await store.assembledReport(
            snapshot: makeSnapshot(codes: ["000001", "000002"])
        )
        let trends = try XCTUnwrap(assembled?.assetTrends)
        XCTAssertEqual(trends.count, 2)
        XCTAssertEqual(trends[0].code, "000001")
        XCTAssertTrue(trends[0].impactText.hasPrefix("涨跌归因："), "实际：\(trends[0].impactText)")
        XCTAssertTrue(trends[1].impactText.hasPrefix("原因待确认："), "实际：\(trends[1].impactText)")
    }

    func testAssetViewDecodingMissingFieldsFallsBackToPlaceholders() throws {
        // 2026-08-31 实证:模型第 9 轮只交 code/id 元数据,「缺少字段 impactText」
        // 解码即整批报废。现在解码容错落到保守占位,入库时再补前缀/horizons。
        let json = #"{"assetTrends":[{"code":"000001","id":"fund:fundmkt:off_exchange:code:000001"}]}"#
        let module = try JSONDecoder().decode(
            TrendReportAssetBatchModule.self,
            from: Data(json.utf8)
        )
        let asset = try XCTUnwrap(module.assetTrends.first)
        XCTAssertEqual(asset.name, "000001", "name 缺失回退 code")
        XCTAssertEqual(asset.sector, "未分类")
        XCTAssertEqual(asset.impactText, "")
        XCTAssertFalse(asset.rationale.isEmpty, "rationale 缺失回退保守占位")
    }

    func testDegradedReportFillsRemainingFundsConservatively() async throws {
        let store = TrendReportDraftStore(
            expectedFundCodes: ["000001", "000002"],
            scope: .closeReview,
            baselineReport: reportWithAssets([makeAsset(code: "000001"), makeAsset(code: "000002")])
        )
        try await store.storeMarket(
            TrendReportMarketModule(marketOutlook: [makeMarketOutlook()], sectors: [], opportunities: [])
        )
        try await store.storeAssetBatch(
            TrendReportAssetBatchModule(assetTrends: [makeAsset(code: "000001")])
        )

        // W5:只覆盖 1/2 时,降级组装保留已暂存条目,为剩余基金合成保守条目。
        let degraded = await store.degradedReport(
            snapshot: makeSnapshot(codes: ["000001", "000002"]),
            reason: "本轮时间预算耗尽"
        )
        let trends = try XCTUnwrap(degraded?.assetTrends)
        XCTAssertEqual(trends.count, 2)
        XCTAssertEqual(trends[0].code, "000001")
        XCTAssertEqual(trends[0].impactText, "原因待确认：测试快照没有底层证券当日行情。")
        let filler = try XCTUnwrap(trends.last)
        XCTAssertEqual(filler.code, "000002")
        XCTAssertTrue(filler.impactText.hasPrefix("原因待确认："))
        XCTAssertTrue(filler.impactText.contains("本轮时间预算耗尽"))
        XCTAssertEqual(filler.horizons.count, 3)
        XCTAssertTrue(filler.horizons.allSatisfy { $0.direction == .uncertain })
    }

    func testDegradedReportRequiresAtLeastOneStagedFund() async throws {
        let store = TrendReportDraftStore(
            expectedFundCodes: ["000001"],
            scope: .closeReview,
            baselineReport: reportWithAssets([makeAsset(code: "000001")])
        )
        try await store.storeMarket(
            TrendReportMarketModule(marketOutlook: [makeMarketOutlook()], sectors: [], opportunities: [])
        )
        let degraded = await store.degradedReport(
            snapshot: makeSnapshot(codes: ["000001"]),
            reason: "本轮时间预算耗尽"
        )
        XCTAssertNil(degraded, "零暂存时维持失败契约,不产生降级报告")
    }

    func testMarketRadarOnlyRequestsMarketModuleAndReusesBaseline() async throws {
        let base = TrendAnalysisReport.fixture(
            generatedAt: "2026-07-26 10:00:00",
            externalSignalStatus: .partial
        )
        let codes = base.assetTrends.compactMap(\.code)
        let store = TrendReportDraftStore(
            expectedFundCodes: codes,
            scope: .marketRadar,
            baselineReport: base
        )

        var progress = await store.progress()
        XCTAssertEqual(progress.nextToolName, TrendReportModuleToolName.market)
        XCTAssertEqual(progress.totalSections, 1)

        try await store.storeMarket(
            TrendReportMarketModule(
                marketOutlook: [makeMarketOutlook()],
                sectors: [],
                opportunities: []
            )
        )
        progress = await store.progress()
        XCTAssertTrue(progress.isComplete)

        let assembled = await store.assembledReport(snapshot: makeSnapshot(codes: codes))
        XCTAssertEqual(assembled?.portfolio, base.portfolio)
        XCTAssertEqual(assembled?.assetTrends, base.assetTrends)
        XCTAssertEqual(assembled?.marketOutlook.first?.name, "市场环境")
    }

    func testCloseReviewRequestsMarketThenAssetBatches() async throws {
        // 2026-09-01 下线收编:closeReview 接管 market 模块(marketRadar 09:00 调度已停),
        // 大盘强弱随每日收盘复盘更新;基线 market 不再预填。
        let code = "000001"
        let base = reportWithAssets([makeAsset(code: code)])
        let store = TrendReportDraftStore(
            expectedFundCodes: [code],
            scope: .closeReview,
            baselineReport: base
        )

        var progress = await store.progress()
        XCTAssertEqual(progress.nextToolName, TrendReportModuleToolName.market)
        XCTAssertEqual(progress.totalSections, 2)

        try await store.storeMarket(
            TrendReportMarketModule(marketOutlook: [makeMarketOutlook()], sectors: [], opportunities: [])
        )
        progress = await store.progress()
        XCTAssertEqual(progress.nextToolName, TrendReportModuleToolName.assetBatch)

        try await store.storeAssetBatch(
            TrendReportAssetBatchModule(assetTrends: [makeAsset(code: code)])
        )
        progress = await store.progress()
        XCTAssertTrue(progress.isComplete)

        let assembled = await store.assembledReport(snapshot: makeSnapshot(codes: [code]))
        // market 用本次提交的;组合/行动仍从基线复用。
        XCTAssertEqual(assembled?.marketOutlook, TrendBaselineContractPatch.markets([makeMarketOutlook()]))
        XCTAssertEqual(assembled?.portfolio, base.portfolio)
        XCTAssertEqual(assembled?.assetTrends.count, 1)
    }

    private func makeAsset(code: String) -> TrendAssetView {
        TrendAssetView(
            id: "asset-\(code)",
            name: "基金\(code)",
            code: code,
            sector: "A股",
            impactText: "原因待确认：测试快照没有底层证券当日行情。",
            horizons: [],
            rationale: "基于当前持仓与行情观察。",
            counterSignals: ["若行情方向变化则重新评估。"]
        )
    }

    private func makeMarketOutlook() -> TrendMarketOutlook {
        TrendMarketOutlook(
            id: "market-environment",
            name: "市场环境",
            category: "index",
            direction: .uncertain,
            confidence: TrendConfidence(score: 40, label: "低"),
            rationale: "当前市场信号仍需进一步确认。",
            evidenceIDs: [],
            counterSignals: ["若主要指数趋势改变则重新评估。"]
        )
    }

    private func reportWithAssets(_ assets: [TrendAssetView]) -> TrendAnalysisReport {
        let base = TrendAnalysisReport.fixture(
            generatedAt: "2026-07-26 10:00:00",
            externalSignalStatus: .partial
        )
        return TrendAnalysisReport(
            id: base.id,
            generatedAt: base.generatedAt,
            dataAsOf: base.dataAsOf,
            privacyMode: base.privacyMode,
            externalSignalStatus: base.externalSignalStatus,
            portfolio: base.portfolio,
            horizons: base.horizons,
            marketOutlook: [makeMarketOutlook()],
            sectors: base.sectors,
            opportunities: base.opportunities,
            keyAssets: base.keyAssets,
            assetTrends: assets,
            actions: base.actions,
            evidence: base.evidence,
            warnings: base.warnings,
            disclaimer: base.disclaimer,
            schemaVersion: TrendAnalysisReport.currentSchemaVersion,
            disposition: base.disposition,
            sourceStatuses: base.sourceStatuses
        )
    }

    // MARK: - 2026-09-01 傍晚根治：W4 入库修补 / code 补写 / 降级合成（runID 4B624F1C）

    /// 模型自报 uncertain 且 rationale 无「待观察信号」出口、无方向词、whatWouldChange 空
    /// ——此前入库原样放行、终审必拒且修不掉(16 轮重发仍复现)。现在入库即由 App 修补。
    func testStoreOverviewPatchesW4ClarityOnEntry() async throws {
        let store = TrendReportDraftStore(expectedFundCodes: ["000001"])
        let base = TrendAnalysisReport.fixture(
            generatedAt: "2026-09-01 20:00:00",
            externalSignalStatus: .partial
        )
        let confidence = base.horizons.first?.confidence
            ?? TrendConfidence(score: 50, label: TrendConfidence.label(for: 50))
        let rawHorizons: [TrendHorizonView] = [
            TrendHorizonView(
                horizon: .short,
                direction: .uncertain,
                confidence: confidence,
                rationale: "多空交织，需要继续跟踪。",
                whatWouldChange: "",
                counterSignals: ["若量能放大则重估。"],
                claimEvidence: .empty
            )
        ] + base.horizons.filter { $0.horizon != .short }

        try await store.storeOverview(
            TrendReportOverviewModule(portfolio: base.portfolio, horizons: rawHorizons)
        )
        try await store.storeMarket(
            TrendReportMarketModule(marketOutlook: [makeMarketOutlook()], sectors: [], opportunities: [])
        )
        try await store.storeAssetBatch(
            TrendReportAssetBatchModule(assetTrends: [makeAsset(code: "000001")])
        )
        try await store.storeActions(
            TrendReportActionsModule(
                keyAssets: [],
                actions: [],
                warnings: [],
                disclaimer: "非投资建议，仅供个人研究参考。"
            )
        )

        let snapshot = makeSnapshot(codes: ["000001"])
        let assembledOptional = await store.assembledReport(snapshot: snapshot)
        let assembled = try XCTUnwrap(assembledOptional)
        let short = try XCTUnwrap(assembled.horizons.first { $0.horizon == .short })
        XCTAssertTrue(short.rationale.contains("待观察信号"), "uncertain 周期应补出口，实际：\(short.rationale)")
        XCTAssertTrue(
            TrendAnalysisValidator.directionLeadWords.contains {
                TrendVerdictPresentation.split(rationale: short.rationale).headline.contains($0)
            },
            "首句应补方向词，实际：\(short.rationale)"
        )
        XCTAssertFalse(
            short.whatWouldChange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "whatWouldChange 应兜底非空"
        )
    }

    /// 清洗器的 uncertain 早退分支同样补出口（与入库修补双保险）。
    func testSanitizedHorizonAppendsExitToSelfReportedUncertain() {
        let horizon = TrendHorizonView(
            horizon: .medium,
            direction: .uncertain,
            confidence: TrendConfidence(score: 40, label: TrendConfidence.label(for: 40)),
            rationale: "证据不足，暂难定向。",
            whatWouldChange: "",
            counterSignals: [],
            claimEvidence: .empty
        )
        let (result, _) = TrendReportEvidenceSanitizer.sanitizedHorizon(
            horizon,
            fundCode: nil,
            fundName: "测试",
            evidenceByID: [:]
        )
        XCTAssertTrue(result.rationale.contains("待观察信号"), "实际：\(result.rationale)")
        XCTAssertFalse(result.whatWouldChange.isEmpty)
        XCTAssertEqual(result.direction, .uncertain, "自报 uncertain 不改变方向")
    }

    /// 模型写 name 漏 code 时按冻结快照精确匹配补写，不再拒批烧修复预算。
    func testAssetBatchResolvesMissingCodeByName() {
        let snapshot = makeSnapshot(codes: ["000001", "000002"])
        let missingCode = TrendAssetView(
            id: "asset-missing",
            name: "基金000001",
            code: nil,
            sector: "A股",
            impactText: "涨跌归因：跟随板块上涨。",
            horizons: [],
            rationale: "观察。",
            counterSignals: ["若行情变化则重新评估。"],
            claimEvidence: .empty
        )
        let unknownName = TrendAssetView(
            id: "asset-unknown",
            name: "不存在的基金",
            code: nil,
            sector: "A股",
            impactText: "涨跌归因：跟随板块上涨。",
            horizons: [],
            rationale: "观察。",
            counterSignals: ["若行情变化则重新评估。"],
            claimEvidence: .empty
        )

        let (module, resolvedNames) = SubmitTrendAssetBatchTool.resolveMissingCodes(
            TrendReportAssetBatchModule(assetTrends: [missingCode, unknownName]),
            snapshot: snapshot
        )

        XCTAssertEqual(resolvedNames, ["基金000001"], "只补写能精确匹配的")
        XCTAssertEqual(module.assetTrends.first?.code, "000001")
        XCTAssertNil(module.assetTrends.last?.code, "匹配不到的保持原样，维持后续校验错误")
    }

    /// 2026-09-02 根治(runID AD2D63F9 第 15 轮):重交已入库基金不再整批拒——重复
    /// 条目跳过、同批健康基金照常入库,已暂存版本保留首次入库内容。此前重交 161725
    /// 连坐同批 8 只健康基金,把最后的修复预算烧在重抄上后撞预算止损。
    func testDuplicateFundSubmissionIsSkippedNotBatchRejected() async throws {
        let codes = ["000001", "000002", "000003"]
        let store = TrendReportDraftStore(expectedFundCodes: codes)
        try await store.storeMarket(
            TrendReportMarketModule(marketOutlook: [makeMarketOutlook()], sectors: [], opportunities: [])
        )
        try await store.storeAssetBatch(
            TrendReportAssetBatchModule(assetTrends: [makeAsset(code: "000001")])
        )
        let duplicateResubmission = TrendAssetView(
            id: "asset-000001-dup", name: "基金000001", code: "000001", sector: "A股",
            impactText: "原因待确认：重复提交。",
            horizons: [], rationale: "重复版本不应覆盖已暂存内容。",
            counterSignals: ["若行情方向变化则重新评估。"]
        )
        // 000001 已入库（重复）、000002 批内重复两次、000003 健康
        try await store.storeAssetBatch(
            TrendReportAssetBatchModule(assetTrends: [
                duplicateResubmission,
                makeAsset(code: "000002"),
                makeAsset(code: "000002"),
                makeAsset(code: "000003"),
            ])
        )
        let progress = await store.progress()
        XCTAssertEqual(progress.remainingFundCodes, [], "重复不再连坐，三只基金全部覆盖")

        let degradedOptional = await store.degradedReport(
            snapshot: makeSnapshot(codes: codes), reason: "预算耗尽"
        )
        let degraded = try XCTUnwrap(degradedOptional)
        XCTAssertEqual(degraded.assetTrends.count, 3)
        XCTAssertEqual(
            degraded.assetTrends.first { $0.code == "000001" }?.rationale,
            "基于当前持仓与行情观察。",
            "重复提交被丢弃，保留首次入库版本"
        )
    }

    /// 2026-09-02 根治(runID AD2D63F9):被 prepareRepairs 清空后模型用 code+name
    /// 短表单恢复覆盖,空壳条目的资产级 counterSignals 无人兜底,沉默到终审才爆并
    /// 连续拖死降级组装。现在归一化链保守补写。
    func testStubAssetBatchGetsCounterSignalsFallback() async throws {
        let store = TrendReportDraftStore(expectedFundCodes: ["000001"])
        try await store.storeMarket(
            TrendReportMarketModule(marketOutlook: [makeMarketOutlook()], sectors: [], opportunities: [])
        )
        let stub = TrendAssetView(
            id: "asset-000001", name: "基金000001", code: "000001", sector: "A股",
            impactText: "", horizons: [], rationale: "观察。", counterSignals: [], claimEvidence: .empty
        )
        try await store.storeAssetBatch(TrendReportAssetBatchModule(assetTrends: [stub]))
        let degradedOptional = await store.degradedReport(
            snapshot: makeSnapshot(codes: ["000001"]), reason: "预算耗尽"
        )
        let degraded = try XCTUnwrap(degradedOptional)
        let staged = try XCTUnwrap(degraded.assetTrends.first)
        XCTAssertFalse(staged.counterSignals.isEmpty, "空 counterSignals 应被保守兜底")
        XCTAssertTrue(staged.impactText.hasPrefix("原因待确认："), "空 impactText 仍由前缀兜底")
        XCTAssertTrue(
            staged.horizons.allSatisfy { $0.direction == .uncertain },
            "缺 horizons 仍由保守合成兜底"
        )
    }

    /// overview/actions 被 prepareRepairs 清空后预算耗尽：降级组装不再返回 nil，
    /// 29 只已暂存批次的运行不至于整 run 报废。
    func testDegradedReportSynthesizesMissingOverviewAndActions() async throws {
        let store = TrendReportDraftStore(expectedFundCodes: ["000001"])
        try await store.storeMarket(
            TrendReportMarketModule(marketOutlook: [makeMarketOutlook()], sectors: [], opportunities: [])
        )
        try await store.storeAssetBatch(
            TrendReportAssetBatchModule(assetTrends: [makeAsset(code: "000001")])
        )

        let snapshot = makeSnapshot(codes: ["000001"])
        let degradedOptional = await store.degradedReport(snapshot: snapshot, reason: "修复预算耗尽")
        let degraded = try XCTUnwrap(degradedOptional, "overview/actions 缺失时应保守合成而不是放弃降级")
        XCTAssertEqual(degraded.portfolio.headline, "组合研判未完成")
        XCTAssertTrue(degraded.disclaimer.contains("非投资建议"))
        XCTAssertTrue(
            degraded.horizons.allSatisfy { $0.direction == .uncertain && $0.rationale.contains("待观察信号") },
            "合成周期应保守 uncertain 且带出口"
        )
        XCTAssertEqual(degraded.assetTrends.count, 1, "已暂存批次保留真实分析")
    }

    private func makeSnapshot(codes: [String]) -> TrendResearchSnapshot {
        let assets = codes.map {
            TrendContextAsset(
                id: $0,
                name: "基金\($0)",
                code: $0,
                assetType: PersonalAssetType.fund.displayName,
                sector: "A股",
                statusText: "已持有",
                weightText: nil,
                profitPct: nil,
                estimateChangePct: nil,
                pendingTradeCount: 0,
                activePlanCount: 0,
                pausedPlanCount: 0,
                endedPlanCount: 0,
                marketValue: nil,
                costValue: nil,
                profitAmount: nil,
                pendingCashAmount: nil,
                estimatedNextPlanAmount: nil,
                totalCumulativePlanAmount: nil
            )
        }
        return TrendResearchSnapshot(
            runID: UUID(),
            createdAt: "2026-07-26 10:00:00",
            dataAsOf: "2026-07-26 09:58:00",
            privacyMode: .sanitized,
            portfolio: TrendContextPortfolio(
                assetCount: assets.count,
                holdingCount: assets.count,
                activePlanCount: 0,
                pendingAssetCount: 0,
                totalMarketValue: nil,
                totalPendingCashAmount: nil,
                totalEstimatedNextPlanAmount: nil,
                totalEffectiveHoldingAmount: nil
            ),
            assets: assets,
            sectors: [],
            platformSignals: [],
            managerSignals: [],
            marketQuotes: [],
            insightHeadline: "",
            sourceWarnings: []
        )
    }
}

// MARK: - 2026-08-28 死循环修复：批次全错收集 + 归因自动降级

final class AssetBatchRejectionLoopFixTests: XCTestCase {
    private func asset(
        code: String,
        impactText: String,
        supportingEvidenceIDs: [String] = []
    ) -> TrendAssetView {
        TrendAssetView(
            id: "asset-\(code)",
            name: "基金\(code)",
            code: code,
            sector: "A股",
            impactText: impactText,
            horizons: [],
            rationale: "观察。",
            counterSignals: ["若行情变化则重新评估。"],
            claimEvidence: TrendClaimEvidence(supportingEvidenceIDs: supportingEvidenceIDs)
        )
    }

    func testBatchCollectsAllFundErrorsAtOnce() async throws {
        // 2026-09-01 起「错前缀」由 App 补前缀不再报错;「一批全错一次性列出」
        // 的契约改用不可兜底的错误类别(未知代码)验证。
        let store = TrendReportDraftStore(expectedFundCodes: ["000001", "000002", "000003"])
        let batch = [
            asset(code: "999991", impactText: "涨跌归因：跟随板块上涨。"),
            asset(code: "999992", impactText: "涨跌归因：跟随板块上涨。"),
        ]
        do {
            try await store.storeAssetBatch(TrendReportAssetBatchModule(assetTrends: batch))
            XCTFail("两只未知代码基金应整批拒收")
        } catch let error as TrendReportDraftError {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("2 个问题"), "一次性列出全部问题，实际：\(message)")
            XCTAssertTrue(message.contains("999991"))
            XCTAssertTrue(message.contains("999992"))
        }
    }

    func testBatchWithAttributionButNoEvidenceIsAutoDowngradedAndAccepted() async throws {
        let store = TrendReportDraftStore(expectedFundCodes: ["000369", "019524"])
        let batch = [
            asset(
                code: "000369",
                impactText: "涨跌归因：当日盘中估值跌0.31%，跟随港股科技回调。",
                supportingEvidenceIDs: ["manager:forumHit:86149"]
            ),
            asset(
                code: "019524",
                impactText: "涨跌归因：重仓股上涨带动净值回升。",
                supportingEvidenceIDs: []
            ),
        ]
        // v4.7.0 线上正是这两类基金把修复预算耗尽——现在应整批通过
        try await store.storeAssetBatch(TrendReportAssetBatchModule(assetTrends: batch))
        let progress = await store.progress()
        XCTAssertEqual(progress.completedSections, 1, "持仓分批已暂存")
    }

    func testMixedBatchPartialAcceptanceViaFullErrorList() async throws {
        // 未知代码 + 无证据归因：前者报错，后者降级——错误信息只含前者
        let store = TrendReportDraftStore(expectedFundCodes: ["000001"])
        let batch = [
            asset(code: "999999", impactText: "涨跌归因：板块上涨。"),
            asset(code: "000001", impactText: "涨跌归因：板块上涨。"),
        ]
        do {
            try await store.storeAssetBatch(TrendReportAssetBatchModule(assetTrends: batch))
            XCTFail("未知代码应报错")
        } catch let error as TrendReportDraftError {
            XCTAssertTrue(error.localizedDescription.contains("999999"))
            XCTAssertFalse(error.localizedDescription.contains("涨跌归因"), "降级后不再报归因类错误")
        }
    }
}
