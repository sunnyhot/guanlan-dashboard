import Foundation
import XCTest
@testable import QiemanDashboard

final class AlphaVantageResearchToolTests: XCTestCase {
    func testETFProfileProducesAuthoritativeVendorEvidence() async throws {
        let fixture = """
        {
          "symbol": "QQQ",
          "fund_type": "ETF",
          "net_assets": "300000000000",
          "net_expense_ratio": "0.0020",
          "holdings": [
            {"symbol":"NVDA","description":"NVIDIA Corp","weight":"0.091"},
            {"symbol":"MSFT","description":"Microsoft Corp","weight":"0.083"}
          ],
          "sectors": [
            {"sector":"Technology","weight":"0.52"},
            {"sector":"Communication Services","weight":"0.16"}
          ],
          "asset_allocation": {"domestic_equities":"0.99"}
        }
        """
        let client = FakeAlphaVantageClient(
            responses: [.etfProfile: Data(fixture.utf8)]
        )
        let (registry, _) = makeRegistry(client: client)
        let ledger = TrendEvidenceLedger()
        let result = await registry.execute(
            call(mode: "etfProfile", symbol: "QQQ"),
            context: context(symbol: "QQQ", ledger: ledger)
        )

        XCTAssertFalse(result.isError, result.contentJSON)
        let evidenceItems = await ledger.allEvidence()
        let evidence = try XCTUnwrap(evidenceItems.first)
        XCTAssertEqual(evidence.metadata.sourceKind, .licensedMarketData)
        XCTAssertEqual(evidence.metadata.sourceTier, .authoritative)
        XCTAssertEqual(evidence.metadata.publisherKey, "alphavantage.co")
        XCTAssertTrue(evidence.summary.contains("NVDA"))
        XCTAssertTrue(result.contentJSON.contains("\"cache_hit\":false"))
        XCTAssertTrue(result.contentJSON.contains("第三方供应商"))
    }

    func testEarningsCalendarParsesCSV() async throws {
        let csv = """
        symbol,name,reportDate,fiscalDateEnding,estimate,currency
        NVDA,NVIDIA Corp,2026-08-26,2026-07-31,1.21,USD
        """
        let client = FakeAlphaVantageClient(
            responses: [.earningsCalendar: Data(csv.utf8)]
        )
        let (registry, _) = makeRegistry(client: client)
        let ledger = TrendEvidenceLedger()
        let result = await registry.execute(
            call(
                mode: "earningsCalendar",
                symbol: "NVDA",
                extra: ["horizon": "3month"]
            ),
            context: context(symbol: "NVDA", ledger: ledger)
        )

        XCTAssertFalse(result.isError, result.contentJSON)
        XCTAssertTrue(result.contentJSON.contains("2026-08-26"))
        let evidenceItems = await ledger.allEvidence()
        let evidence = try XCTUnwrap(evidenceItems.first)
        XCTAssertTrue(evidence.id.contains("vendor:alphavantage:earnings:NVDA"))
        XCTAssertTrue(evidence.summary.contains("可能调整"))
    }

    func testDailyAnalyticsCalculatesIndicatorsLocally() async throws {
        var series: [String: Any] = [:]
        let calendar = Calendar(identifier: .gregorian)
        let start = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-29T00:00:00Z")
        )
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        for offset in 0..<65 {
            let date = calendar.date(byAdding: .day, value: -offset, to: start)!
            series[formatter.string(from: date)] = [
                "4. close": String(200 - offset),
                "5. volume": String(1_000_000 + offset)
            ]
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["Time Series (Daily)": series]
        )
        let client = FakeAlphaVantageClient(
            responses: [.timeSeriesDaily: data]
        )
        let (registry, _) = makeRegistry(client: client)
        let ledger = TrendEvidenceLedger()
        let result = await registry.execute(
            call(mode: "dailyAnalytics", symbol: "NVDA"),
            context: context(symbol: "NVDA", ledger: ledger)
        )

        XCTAssertFalse(result.isError, result.contentJSON)
        let envelope = try XCTUnwrap(json(result.contentJSON))
        let payload = try XCTUnwrap(envelope["data"] as? [String: Any])
        let analytics = try XCTUnwrap(payload["analytics"] as? [String: Any])
        XCTAssertEqual(analytics["latest_close"] as? Double, 200)
        XCTAssertNotNil(analytics["return_20d_pct"] as? Double)
        XCTAssertNotNil(analytics["sma_60"] as? Double)
        XCTAssertNotNil(analytics["annualized_volatility_pct"] as? Double)
        XCTAssertTrue(result.contentJSON.contains("本地计算"))
    }

    func testRejectsSymbolOutsideFrozenSnapshotWithoutNetworkCall() async {
        let client = FakeAlphaVantageClient(
            responses: [.etfProfile: Data("{}".utf8)]
        )
        let (registry, _) = makeRegistry(client: client)
        let result = await registry.execute(
            call(mode: "etfProfile", symbol: "SPY"),
            context: context(symbol: "QQQ", ledger: TrendEvidenceLedger())
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.contentJSON.contains("不在本次直接持仓"))
        let networkCalls = await client.callCount()
        XCTAssertEqual(networkCalls, 0)
    }

    func testPersistentCacheAvoidsSecondNetworkAndBudgetConsumption() async throws {
        let fixture = """
        {"holdings":[{"symbol":"NVDA","description":"NVIDIA","weight":"0.1"}]}
        """
        let client = FakeAlphaVantageClient(
            responses: [.etfProfile: Data(fixture.utf8)]
        )
        let budget = FakeAlphaVantageBudget()
        let directory = temporaryDirectory()
        let cache = AlphaVantageResponseCache(
            directory: directory,
            budget: budget
        )
        let registry = TrendResearchToolRegistry(
            alphaVantageClient: client,
            alphaVantageCache: cache
        )
        let first = await registry.execute(
            call(mode: "etfProfile", symbol: "QQQ"),
            context: context(symbol: "QQQ", ledger: TrendEvidenceLedger())
        )
        let second = await registry.execute(
            call(mode: "etfProfile", symbol: "QQQ"),
            context: context(symbol: "QQQ", ledger: TrendEvidenceLedger())
        )

        XCTAssertFalse(first.isError)
        XCTAssertFalse(second.isError)
        XCTAssertTrue(second.contentJSON.contains("\"cache_hit\":true"))
        let networkCalls = await client.callCount()
        let budgetConsumes = await budget.consumeCount()
        XCTAssertEqual(networkCalls, 1)
        XCTAssertEqual(budgetConsumes, 1)
    }

    func testAShareSymbolMappingUsesDocumentedSuffix() {
        let snapshot = makeSnapshot(symbol: "600104")
        XCTAssertEqual(snapshot.eligibleAlphaVantageSymbols, ["600104.SHH"])
        let shenzhen = makeSnapshot(symbol: "000002")
        XCTAssertEqual(shenzhen.eligibleAlphaVantageSymbols, ["000002.SHZ"])
    }

    private func makeRegistry(
        client: FakeAlphaVantageClient
    ) -> (TrendResearchToolRegistry, FakeAlphaVantageBudget) {
        let budget = FakeAlphaVantageBudget()
        let cache = AlphaVantageResponseCache(
            directory: temporaryDirectory(),
            budget: budget
        )
        return (
            TrendResearchToolRegistry(
                alphaVantageClient: client,
                alphaVantageCache: cache
            ),
            budget
        )
    }

    private func context(
        symbol: String,
        ledger: TrendEvidenceLedger
    ) -> TrendResearchToolContext {
        TrendResearchToolContext(
            snapshot: makeSnapshot(symbol: symbol),
            evidenceLedger: ledger,
            alphaVantageSettings: AlphaVantageSettings(
                enabled: true,
                apiKey: "test-key",
                dailyRequestLimit: 25
            )
        )
    }

    private func makeSnapshot(symbol: String) -> TrendResearchSnapshot {
        let asset = TrendContextAsset(
            id: symbol,
            name: symbol,
            code: symbol,
            assetType: PersonalAssetType.stock.displayName,
            sector: "测试",
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
        return TrendResearchSnapshot(
            runID: UUID(),
            createdAt: "2026-07-29 10:00:00",
            dataAsOf: "2026-07-29 10:00:00",
            privacyMode: .sanitized,
            portfolio: TrendContextPortfolio(
                assetCount: 1,
                holdingCount: 1,
                activePlanCount: 0,
                pendingAssetCount: 0,
                totalMarketValue: nil,
                totalPendingCashAmount: nil,
                totalEstimatedNextPlanAmount: nil,
                totalEffectiveHoldingAmount: nil
            ),
            assets: [asset],
            sectors: [],
            platformSignals: [],
            managerSignals: [],
            marketQuotes: [],
            insightHeadline: "测试",
            sourceWarnings: []
        )
    }

    private func call(
        mode: String,
        symbol: String,
        extra: [String: Any] = [:]
    ) -> AgentToolCall {
        var arguments: [String: Any] = [
            "mode": mode,
            "symbol": symbol,
            "research_target": [
                "kind": "asset",
                "key": symbol,
                "entityCodes": [symbol]
            ]
        ]
        arguments.merge(extra) { _, new in new }
        let data = try! JSONSerialization.data(withJSONObject: arguments)
        return AgentToolCall(
            id: "alpha-\(mode)",
            function: AgentToolFunctionCall(
                name: "alpha_vantage_research",
                arguments: String(data: data, encoding: .utf8)!
            )
        )
    }

    private func json(_ value: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(
            with: Data(value.utf8)
        ) as? [String: Any]
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}

private actor FakeAlphaVantageClient: AlphaVantageClientProtocol {
    private let responses: [AlphaVantageFunction: Data]
    private var calls = 0

    init(responses: [AlphaVantageFunction: Data]) {
        self.responses = responses
    }

    func fetch(
        _ descriptor: AlphaVantageRequestDescriptor,
        settings: AlphaVantageSettings
    ) throws -> Data {
        calls += 1
        guard let data = responses[descriptor.function] else {
            throw AlphaVantageClientError.invalidResponse("缺少测试响应")
        }
        return data
    }

    func callCount() -> Int {
        calls
    }
}

private actor FakeAlphaVantageBudget: AlphaVantageDailyBudgetProtocol {
    private var consumes = 0

    func consume(limit: Int, now: Date) throws {
        guard consumes < limit else {
            throw AlphaVantageClientError.dailyBudgetExceeded(limit: limit)
        }
        consumes += 1
    }

    func remaining(limit: Int, now: Date) -> Int {
        max(0, limit - consumes)
    }

    func consumeCount() -> Int {
        consumes
    }
}
