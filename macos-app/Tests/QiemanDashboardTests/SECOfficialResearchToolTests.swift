import XCTest
@testable import QiemanDashboard

final class SECOfficialResearchToolTests: XCTestCase {
    func testRecentFilingsProducesCanonicalOfficialEvidence() async throws {
        let client = FakeSECOfficialSourceClient()
        let registry = TrendResearchToolRegistry(
            officialSourceClient: client,
            officialSourceCache: SECOfficialSourceCache()
        )
        let ledger = TrendEvidenceLedger()
        let context = TrendResearchToolContext(
            snapshot: makeSnapshot(ticker: "NVDA"),
            evidenceLedger: ledger,
            officialSourceSettings: OfficialSourceSettings(
                secContactEmail: "research@example.com"
            )
        )

        let result = await registry.execute(
            officialCall(
                ticker: "NVDA",
                mode: "recentFilings",
                extra: ["days": 730, "forms": ["8-K"]]
            ),
            context: context
        )

        XCTAssertFalse(result.isError)
        let evidence = await ledger.canonical(
            for: "official:sec:filing:0001045810-26-000123"
        )
        XCTAssertEqual(evidence?.metadata.sourceKind, .officialFiling)
        XCTAssertEqual(evidence?.metadata.sourceTier, .primary)
        XCTAssertEqual(evidence?.metadata.publisherKey, "sec.gov")
        XCTAssertEqual(evidence?.metadata.entityCodes, ["NVDA"])
        XCTAssertTrue(evidence?.url?.contains("sec.gov/Archives/edgar/data/1045810/") == true)
    }

    func testCompanyFactsProducesPrimaryFinancialEvidence() async throws {
        let client = FakeSECOfficialSourceClient()
        let registry = TrendResearchToolRegistry(
            officialSourceClient: client,
            officialSourceCache: SECOfficialSourceCache()
        )
        let ledger = TrendEvidenceLedger()
        let context = TrendResearchToolContext(
            snapshot: makeSnapshot(ticker: "NVDA"),
            evidenceLedger: ledger,
            officialSourceSettings: OfficialSourceSettings(
                secContactEmail: "research@example.com"
            )
        )

        let result = await registry.execute(
            officialCall(ticker: "NVDA", mode: "companyFacts"),
            context: context
        )

        XCTAssertFalse(result.isError)
        let ids = await ledger.allIDs()
        let evidenceID = try XCTUnwrap(ids.first { $0.hasPrefix("official:sec:facts:") })
        let evidence = await ledger.canonical(for: evidenceID)
        XCTAssertEqual(evidence?.metadata.sourceKind, .officialFinancial)
        XCTAssertTrue(evidence?.summary.contains("营业收入") == true)
        XCTAssertTrue(result.contentJSON.contains("\"provider\":\"U.S. SEC EDGAR\""))
    }

    func testRejectsTickerOutsideFrozenSnapshotWithoutNetworkCall() async {
        let client = FakeSECOfficialSourceClient()
        let registry = TrendResearchToolRegistry(
            officialSourceClient: client,
            officialSourceCache: SECOfficialSourceCache()
        )
        let context = TrendResearchToolContext(
            snapshot: makeSnapshot(ticker: "NVDA"),
            evidenceLedger: TrendEvidenceLedger(),
            officialSourceSettings: OfficialSourceSettings(
                secContactEmail: "research@example.com"
            )
        )

        let result = await registry.execute(
            officialCall(ticker: "AAPL", mode: "recentFilings"),
            context: context
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.contentJSON.contains("不在本次直接持仓"))
        let callCount = await client.callCount()
        XCTAssertEqual(callCount, 0)
    }

    private func officialCall(
        ticker: String,
        mode: String,
        extra: [String: Any] = [:]
    ) -> AgentToolCall {
        var arguments: [String: Any] = [
            "mode": mode,
            "ticker": ticker,
            "research_target": [
                "kind": "asset",
                "key": ticker,
                "entityCodes": [ticker]
            ]
        ]
        arguments.merge(extra) { _, new in new }
        let data = try! JSONSerialization.data(withJSONObject: arguments)
        return AgentToolCall(
            id: "sec-\(mode)",
            function: AgentToolFunctionCall(
                name: "official_sec_research",
                arguments: String(data: data, encoding: .utf8)!
            )
        )
    }

    private func makeSnapshot(ticker: String) -> TrendResearchSnapshot {
        let asset = TrendContextAsset(
            id: ticker,
            name: "NVIDIA",
            code: ticker,
            assetType: PersonalAssetType.stock.displayName,
            sector: "美国科技",
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
}

private actor FakeSECOfficialSourceClient: SECOfficialSourceClientProtocol {
    private var calls = 0

    func fetch(
        _ descriptor: SECRequestDescriptor,
        settings: OfficialSourceSettings,
        timeoutSeconds: Double
    ) async throws -> Data {
        calls += 1
        let path = descriptor.url.absoluteString
        if path.contains("company_tickers_exchange.json") {
            return Data(
                #"{"fields":["cik","name","ticker","exchange"],"data":[[1045810,"NVIDIA CORP","NVDA","Nasdaq"]]}"#.utf8
            )
        }
        if path.contains("/submissions/") {
            return Data(
                """
                {
                  "filings": {
                    "recent": {
                      "accessionNumber": ["0001045810-26-000123"],
                      "filingDate": ["2026-07-28"],
                      "reportDate": ["2026-07-27"],
                      "acceptanceDateTime": ["2026-07-28T16:05:00.000Z"],
                      "form": ["8-K"],
                      "items": ["2.02"],
                      "primaryDocument": ["nvda-20260728.htm"],
                      "primaryDocDescription": ["Current report"],
                      "isXBRL": [1],
                      "isInlineXBRL": [1]
                    }
                  }
                }
                """.utf8
            )
        }
        if path.contains("/companyfacts/") {
            return Data(
                """
                {
                  "facts": {
                    "us-gaap": {
                      "RevenueFromContractWithCustomerExcludingAssessedTax": {
                        "units": {
                          "USD": [{
                            "val": 30000000000,
                            "start": "2026-04-01",
                            "end": "2026-06-30",
                            "filed": "2026-07-28",
                            "form": "10-Q",
                            "frame": "CY2026Q2"
                          }]
                        }
                      },
                      "NetIncomeLoss": {
                        "units": {
                          "USD": [{
                            "val": 15000000000,
                            "start": "2026-04-01",
                            "end": "2026-06-30",
                            "filed": "2026-07-28",
                            "form": "10-Q",
                            "frame": "CY2026Q2"
                          }]
                        }
                      }
                    }
                  }
                }
                """.utf8
            )
        }
        throw SECOfficialSourceClientError.invalidResponse("unexpected test URL")
    }

    func callCount() -> Int {
        calls
    }
}
