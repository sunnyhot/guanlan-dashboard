import XCTest
@testable import QiemanDashboard

// 阶段二：快照、工具、证据账本与增强 Validator 的单元测试。
final class TrendResearchToolTests: XCTestCase {
    private let registry = TrendResearchToolRegistry()

    // MARK: - 资产分页

    func testAssetsPaginateStablyWithoutGapsOrDuplicates() async throws {
        let snapshot = makeSnapshot(assets: (0..<25).map { makeAsset(code: String(format: "%05d", $0)) })
        let context = makeContext(snapshot: snapshot)

        let page1 = try parseData(await runAssetTool(cursor: 0, limit: 20, context: context))
        XCTAssertEqual(page1["total_count"] as? Int, 25)
        XCTAssertEqual((page1["assets"] as? [Any])?.count, 20)
        XCTAssertEqual(page1["has_more"] as? Bool, true)
        XCTAssertEqual(page1["next_cursor"] as? Int, 20)

        let page2 = try parseData(await runAssetTool(cursor: 20, limit: 20, context: context))
        XCTAssertEqual((page2["assets"] as? [Any])?.count, 5)
        XCTAssertEqual(page2["has_more"] as? Bool, false)

        // 顺序稳定、无重复、无遗漏。
        let codes = collectCodes(page1) + collectCodes(page2)
        XCTAssertEqual(codes, (0..<25).map { String(format: "%05d", $0) })
    }

    func testAssetsRejectNegativeCursor() async throws {
        let snapshot = makeSnapshot(assets: [makeAsset(code: "00001")])
        let context = makeContext(snapshot: snapshot)

        let result = await runAssetTool(cursor: -1, limit: 5, context: context)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.contentJSON.contains("invalid_arguments"))
    }

    func testAssetsRejectOutOfRangeLimit() async throws {
        let snapshot = makeSnapshot(assets: [makeAsset(code: "00001"), makeAsset(code: "00002")])
        let context = makeContext(snapshot: snapshot)

        let result = await runAssetTool(cursor: 0, limit: 99, context: context)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.contentJSON.contains("invalid_arguments"))
    }

    func testAssetsFilterByCodes() async throws {
        let snapshot = makeSnapshot(assets: ["00001", "00002", "00003"].map { makeAsset(code: $0) })
        let context = makeContext(snapshot: snapshot)

        let data = try parseData(await runAssetTool(cursor: 0, limit: 20, codes: ["00002"], context: context))
        XCTAssertEqual(collectCodes(data), ["00002"])
    }

    // MARK: - 证据账本

    func testToolsRecordStableEvidenceIDs() async throws {
        let snapshot = makeSnapshot(assets: [makeAsset(code: "00001")])
        let ledger = TrendEvidenceLedger()
        let context = TrendResearchToolContext(snapshot: snapshot, evidenceLedger: ledger)

        _ = await runAssetTool(cursor: 0, limit: 20, context: context)

        let ids = await ledger.allIDs()
        XCTAssertTrue(ids.contains("portfolio:asset:00001"))
    }

    func testMarketSnapshotReturnsUnderlyingQuoteWithRelatedFundEvidence() async throws {
        let quote = TrendResearchQuote(
            kind: "underlying-stock",
            evidenceID: "market:stock:688041:2026-08-10 15:00:00",
            code: "688041",
            name: "海光信息",
            price: 188.5,
            changePct: 4.2,
            changeAmount: 7.6,
            quotedAt: "2026-08-10 15:00:00",
            sourceLabel: "股票行情",
            assessment: TrendSourceFreshnessPolicy.assess(
                quoteType: .lastTrade,
                asOf: "2026-08-10 15:00:00",
                receivedAt: "2026-08-10 15:02:00"
            )
        )
        let contributor = PortfolioLookThroughContributor(
            fundCode: "163402",
            fundName: "兴全趋势投资混合",
            fundPortfolioWeightPct: 41.69,
            underlyingWeightPct: 10.44,
            portfolioWeightPct: 4.35,
            disclosureDate: "2026-06-30",
            isDirectHolding: false
        )
        let lookThrough = PortfolioLookThroughSnapshot(
            expectedFundCount: 1,
            coveredFundCount: 1,
            fundDataCoveragePct: 100,
            disclosedSecurityCoveragePct: 10.44,
            unknownPortfolioWeightPct: 89.56,
            topPositions: [
                PortfolioLookThroughPosition(
                    code: "688041",
                    name: "海光信息",
                    kind: .stock,
                    portfolioWeightPct: 4.35,
                    contributors: [contributor]
                )
            ],
            industries: [],
            assetClasses: [],
            funds: [],
            disclosures: [:],
            warnings: []
        )
        let snapshot = makeSnapshot(
            assets: [makeAsset(code: "163402")],
            quotes: [quote],
            lookThrough: lookThrough
        )
        let ledger = TrendEvidenceLedger()
        let context = TrendResearchToolContext(snapshot: snapshot, evidenceLedger: ledger)
        let call = AgentToolCall(
            id: "market-attribution",
            function: AgentToolFunctionCall(
                name: "get_market_snapshot",
                arguments: jsonString([
                    "asset_codes": ["163402"],
                    "include_indices": false,
                    "include_underlying_holdings": true,
                ])
            )
        )

        let result = await registry.execute(call, context: context)
        let data = try parseData(result)
        XCTAssertEqual((data["underlying_attribution"] as? [Any])?.count, 1)
        let evidence = await ledger.canonical(for: quote.evidenceID)
        XCTAssertTrue(evidence?.metadata.isAssociated(entityCode: "163402") == true)
        XCTAssertTrue(evidence?.metadata.isAssociated(entityName: "兴全趋势投资混合") == true)
    }

    func testMarketRadarSnapshotDoesNotExposeFundOrUnderlyingHoldingQuotes() async throws {
        let assessment = TrendSourceFreshnessPolicy.assess(
            quoteType: .lastTrade,
            asOf: "2026-08-10 15:00:00",
            receivedAt: "2026-08-10 15:02:00"
        )
        let quotes = [
            TrendResearchQuote(
                kind: "index",
                evidenceID: "market:index:000001:2026-08-10 15:00:00",
                code: "000001",
                name: "上证指数",
                price: 3900,
                changePct: 0.8,
                changeAmount: 31,
                quotedAt: "2026-08-10 15:00:00",
                sourceLabel: "指数行情",
                assessment: assessment
            ),
            TrendResearchQuote(
                kind: "fund-estimate",
                evidenceID: "market:fund-estimate:163402:2026-08-10 15:00:00",
                code: "163402",
                name: "兴全趋势投资混合",
                price: 1.2,
                changePct: 2.6,
                changeAmount: nil,
                quotedAt: "2026-08-10 15:00:00",
                sourceLabel: "基金估值",
                assessment: assessment
            ),
        ]
        let snapshot = makeSnapshot(
            assets: [makeAsset(code: "163402")],
            quotes: quotes
        )
        let ledger = TrendEvidenceLedger()
        let context = TrendResearchToolContext(
            snapshot: snapshot,
            scope: .marketRadar,
            evidenceLedger: ledger
        )
        let call = AgentToolCall(
            id: "market-only",
            function: AgentToolFunctionCall(
                name: "get_market_snapshot",
                arguments: "{}"
            )
        )

        let result = await registry.execute(call, context: context)
        let data = try parseData(result)
        let returnedQuotes = try XCTUnwrap(data["quotes"] as? [[String: Any]])
        XCTAssertEqual(returnedQuotes.compactMap { $0["kind"] as? String }, ["index"])
        let fundEvidence = await ledger.canonical(for: quotes[1].evidenceID)
        XCTAssertNil(fundEvidence)
    }

    func testHarnessRequiresMarketSnapshotWhenQuotesAreAvailable() {
        let quote = TrendResearchQuote(
            kind: "fund-estimate",
            evidenceID: "market:fund-estimate:163402:2026-08-10 15:00:00",
            code: "163402",
            name: "兴全趋势投资混合",
            price: 1.2,
            changePct: 2.67,
            changeAmount: nil,
            quotedAt: "2026-08-10 15:00:00",
            sourceLabel: "基金估值"
        )
        var harness = TrendResearchHarnessState(
            snapshot: makeSnapshot(quotes: [quote])
        )
        _ = harness.process(
            toolName: "get_portfolio_overview",
            result: TrendResearchToolResult.content(
                TrendResearchToolEnvelope.success(["portfolio": [:]])
            )
        )

        XCTAssertFalse(harness.readyForSubmission())
        XCTAssertTrue(
            harness.nextStepHint()
                .contains("get_market_snapshot")
        )

        _ = harness.process(
            toolName: "get_market_snapshot",
            result: TrendResearchToolResult.content(
                TrendResearchToolEnvelope.success(["quotes": []])
            )
        )
        XCTAssertTrue(harness.readyForSubmission())
    }

    // MARK: - submit 归一化

    func testSubmitNormalizesTimestampsAndPrivacyMode() async throws {
        // 快照无可覆盖基金（assets 为空）→ 覆盖率校验平凡通过，便于聚焦归一化行为。
        let snapshot = makeSnapshot(assets: [])
        let ledger = TrendEvidenceLedger()
        let context = TrendResearchToolContext(snapshot: snapshot, evidenceLedger: ledger)
        await recordOverviewEvidence(context: context)

        let report = TrendAnalysisReport
            .fixture(generatedAt: "1999-01-01 00:00:00", externalSignalStatus: .partial)
            .groundedForSubmission(snapshot: snapshot)
        let reportObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        let arguments = jsonString(["report": reportObject])
        let call = AgentToolCall(id: "submit_1", function: AgentToolFunctionCall(name: "submit_trend_report", arguments: arguments))

        let result = await registry.execute(call, context: context)
        XCTAssertFalse(result.isError)
        guard case .report(let normalized) = result.completion else {
            XCTFail("期望 submit 成功并返回报告")
            return
        }
        XCTAssertEqual(normalized.dataAsOf, "2026-07-24 09:58:00")
        XCTAssertEqual(normalized.privacyMode, .sanitized)
        XCTAssertNotEqual(normalized.generatedAt, "1999-01-01 00:00:00")
        XCTAssertEqual(normalized.disposition, .insufficientEvidence)
        XCTAssertEqual(
            normalized.horizons.first(where: { $0.horizon == .short })?.direction,
            .uncertain
        )
        XCTAssertEqual(normalized.sourceStatuses.count, TrendDataSource.allCases.count)
    }

    // MARK: - Validator 增强

    func testValidatorRejectsAvailableStatusWithoutExternalResearchEvidence() {
        let report = TrendAnalysisReport.fixture(generatedAt: "2026-07-24 10:00:00", externalSignalStatus: .available)
        let result = TrendAnalysisValidator().validate(report)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.messages.contains { $0.contains("官方源或联网搜索") })
    }

    func testValidatorRejectsFabricatedEvidenceID() throws {
        let base = TrendAnalysisReport.fixture(generatedAt: "2026-07-24 10:00:00", externalSignalStatus: .partial)
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        dict["sectors"] = [[
            "name": "A股",
            "exposureText": "30%",
            "direction": "neutral",
            "confidence": ["score": 60, "label": "中"],
            "rationale": "测试板块",
            "evidenceIDs": ["fabricated:eid"],
            "counterSignals": ["无"]
        ]]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let report = try JSONDecoder().decode(TrendAnalysisReport.self, from: data)

        let result = TrendAnalysisValidator().validate(report)
        XCTAssertTrue(result.messages.contains { $0.contains("引用的证据 ID 不存在：fabricated:eid") })
    }

    // MARK: - 辅助构造

    private func makeContext(
        snapshot: TrendResearchSnapshot
    ) -> TrendResearchToolContext {
        TrendResearchToolContext(
            snapshot: snapshot,
            evidenceLedger: TrendEvidenceLedger()
        )
    }

    private func makeSnapshot(
        assets: [TrendContextAsset] = [],
        signals: [TrendResearchSignal] = [],
        quotes: [TrendResearchQuote] = [],
        lookThrough: PortfolioLookThroughSnapshot? = nil
    ) -> TrendResearchSnapshot {
        TrendResearchSnapshot(
            runID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: "2026-07-24 10:00:00",
            dataAsOf: "2026-07-24 09:58:00",
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
            platformSignals: signals,
            managerSignals: [],
            marketQuotes: quotes,
            lookThrough: lookThrough,
            insightHeadline: "测试洞察",
            sourceWarnings: []
        )
    }

    private func makeAsset(code: String, marketValue: Double? = nil) -> TrendContextAsset {
        TrendContextAsset(
            id: code,
            name: "基金\(code)",
            code: code,
            assetType: PersonalAssetType.fund.displayName,
            sector: "A股",
            statusText: "已持有",
            weightText: nil,
            profitPct: 0.1,
            estimateChangePct: 0.2,
            pendingTradeCount: 0,
            activePlanCount: 0,
            pausedPlanCount: 0,
            endedPlanCount: 0,
            marketValue: marketValue,
            costValue: nil,
            profitAmount: nil,
            pendingCashAmount: nil,
            estimatedNextPlanAmount: nil,
            totalCumulativePlanAmount: nil
        )
    }

    private func runAssetTool(
        cursor: Int?,
        limit: Int?,
        codes: [String]? = nil,
        context: TrendResearchToolContext
    ) async -> TrendResearchToolResult {
        var args: [String: Any] = [:]
        if let cursor { args["cursor"] = cursor }
        if let limit { args["limit"] = limit }
        if let codes { args["codes"] = codes }
        let call = AgentToolCall(
            id: "asset_call",
            function: AgentToolFunctionCall(name: "get_portfolio_assets", arguments: jsonString(args))
        )
        return await registry.execute(call, context: context)
    }

    private func recordOverviewEvidence(
        context: TrendResearchToolContext
    ) async {
        let call = AgentToolCall(
            id: "overview_for_submit",
            function: AgentToolFunctionCall(
                name: "get_portfolio_overview",
                arguments: "{}"
            )
        )
        _ = await registry.execute(call, context: context)
    }

    private func parseData(_ result: TrendResearchToolResult) throws -> [String: Any] {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.contentJSON.utf8)) as? [String: Any])
        return try XCTUnwrap(json["data"] as? [String: Any])
    }

    private func collectCodes(_ data: [String: Any]) -> [String] {
        ((data["assets"] as? [Any]) ?? []).compactMap { ($0 as? [String: Any])?["code"] as? String }
    }

    private func jsonString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}
