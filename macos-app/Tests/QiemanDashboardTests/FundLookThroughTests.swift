import XCTest
@testable import QiemanDashboard

final class FundLookThroughTests: XCTestCase {
    func testParsesLatestStockAndBondDisclosureTables() {
        let stockText = """
        var apidata={ content:"<div><a title='测试混合基金' href='http://fund.eastmoney.com/000001.html'>测试混合基金</a>截止至：<font class='px12'>2026-06-30</font><table><tbody>
        <tr><td>1</td><td><a>300308</a></td><td class='tol'><a>中际旭创</a></td><td></td><td></td><td>资讯</td><td class='tor'>6.45%</td><td>20.00</td><td>25,400.00</td></tr>
        <tr><td>2</td><td><a>688012</a></td><td class='tol'><a>中微公司</a></td><td></td><td></td><td>资讯</td><td class='tor'>4.70%</td><td>39.54</td><td>18,525.47</td></tr>
        </tbody></table><table><tr><td>1</td><td>OLD</td><td>旧持仓</td><td>99%</td><td>1</td></tr></table>"};
        """
        let stocks = FundLookThroughClient.parseArchiveHoldings(stockText, kind: .stock)

        XCTAssertEqual(stocks.fundName, "测试混合基金")
        XCTAssertEqual(stocks.holdings.map(\.code), ["300308", "688012"])
        XCTAssertEqual(stocks.holdings.map(\.weightPct), [6.45, 4.70])
        XCTAssertEqual(stocks.holdings.first?.disclosureDate, "2026-06-30")

        let bondText = """
        var apidata={ content:"<div><a href='http://fund.eastmoney.com/000001.html'>测试混合基金</a>截止至：<font class='px12'>2026-06-30</font><table><tbody>
        <tr><td>1</td><td>019827</td><td class='tol'>26国债01</td><td class='tor'>7.05%</td><td>27,778.90</td></tr>
        </tbody></table>"};
        """
        let bonds = FundLookThroughClient.parseArchiveHoldings(bondText, kind: .bond)

        XCTAssertEqual(bonds.holdings.first?.code, "019827")
        XCTAssertEqual(bonds.holdings.first?.name, "26国债01")
        XCTAssertEqual(bonds.holdings.first?.weightPct, 7.05)
    }

    func testParsesLatestIndustryAndAssetAllocation() throws {
        let industryJSON = """
        {
          "Data": {
            "ShortName": "测试基金",
            "QuarterInfos": [
              {"JZRQ":"2026-03-31","HYPZInfo":[{"HYMC":"制造业","FSRQ":"2026-03-31","ZJZBL":"40.00"}]},
              {"JZRQ":"2026-06-30","HYPZInfo":[
                {"HYMC":"制造业","FSRQ":"2026-06-30","ZJZBL":"62.50"},
                {"HYMC":"信息技术服务业","FSRQ":"2026-06-30","ZJZBL":"8.25"}
              ]}
            ]
          },
          "ErrCode": 0
        }
        """
        let industry = try XCTUnwrap(FundLookThroughClient.parseIndustries(industryJSON))
        XCTAssertEqual(industry.fundName, "测试基金")
        XCTAssertEqual(industry.exposures.map(\.name), ["制造业", "信息技术服务业"])
        XCTAssertEqual(industry.exposures.map(\.weightPct), [62.5, 8.25])
        XCTAssertEqual(industry.exposures.first?.disclosureDate, "2026-06-30")

        let allocationText = """
        var Data_assetAllocation = {
          "series": [
            {"name":"股票占净比","data":[70.0,75.5]},
            {"name":"债券占净比","data":[20.0,18.0]},
            {"name":"现金占净比","data":[5.0,3.5]}
          ],
          "categories":["2026-03-31","2026-06-30"]
        };
        """
        let allocation = try XCTUnwrap(FundLookThroughClient.parseAssetAllocation(allocationText))
        XCTAssertEqual(allocation.stockPct, 75.5)
        XCTAssertEqual(allocation.bondPct, 18)
        XCTAssertEqual(allocation.cashPct, 3.5)
        XCTAssertEqual(allocation.otherPct, 3)
        XCTAssertEqual(allocation.disclosureDate, "2026-06-30")

        let allocationHTML = """
        <h4>资产配置明细</h4>
        <table><thead><tr><th>报告期</th></tr></thead><tbody>
        <tr><td>2026-06-30</td><td class="tor">79.98%</td><td class="tor">20.19%</td><td class="tor">0.79%</td><td>39.38</td></tr>
        <tr><td>2026-03-31</td><td>72.51%</td><td>20.63%</td><td>2.39%</td><td>26.44</td></tr>
        </tbody></table>
        """
        let htmlAllocation = try XCTUnwrap(
            FundLookThroughClient.parseAssetAllocation(allocationHTML)
        )
        XCTAssertEqual(htmlAllocation.stockPct, 79.98)
        XCTAssertEqual(htmlAllocation.bondPct, 20.19)
        XCTAssertEqual(htmlAllocation.cashPct, 0.79)
        // 净值口径下三项合计可能略高于 100%，其他项按 0 处理。
        XCTAssertEqual(htmlAllocation.otherPct, 0)
    }

    func testCalculatorMergesSameUnderlyingSecurityAcrossFunds() throws {
        let rows = [
            makeRow(code: "000001", name: "基金 A", marketValue: 60_000),
            makeRow(code: "000002", name: "基金 B", marketValue: 40_000)
        ]
        let disclosures = [
            "000001": disclosure(
                code: "000001",
                name: "基金 A",
                holdingWeight: 10,
                industryWeight: 30,
                allocation: FundAssetAllocation(
                    stockPct: 80,
                    bondPct: 10,
                    cashPct: 5,
                    otherPct: 5,
                    disclosureDate: "2026-06-30"
                )
            ),
            "000002": disclosure(
                code: "000002",
                name: "基金 B",
                holdingWeight: 20,
                industryWeight: 50,
                allocation: FundAssetAllocation(
                    stockPct: 60,
                    bondPct: 30,
                    cashPct: 10,
                    otherPct: 0,
                    disclosureDate: "2026-06-30"
                )
            )
        ]

        let result = try XCTUnwrap(
            PortfolioLookThroughCalculator.make(
                rows: rows,
                disclosures: disclosures,
                generatedAt: "2026-07-26 12:00:00"
            )
        )

        XCTAssertEqual(result.coveredFundCount, 2)
        XCTAssertEqual(result.fundDataCoveragePct, 100, accuracy: 0.0001)
        XCTAssertEqual(result.disclosedSecurityCoveragePct, 14, accuracy: 0.0001)
        XCTAssertEqual(result.unknownPortfolioWeightPct, 86, accuracy: 0.0001)

        let shared = try XCTUnwrap(result.topPositions.first)
        XCTAssertEqual(shared.code, "300308")
        XCTAssertEqual(shared.portfolioWeightPct, 14, accuracy: 0.0001)
        XCTAssertEqual(shared.contributors.count, 2)

        let manufacturing = try XCTUnwrap(result.industries.first { $0.name == "制造业" })
        XCTAssertEqual(manufacturing.portfolioWeightPct, 38, accuracy: 0.0001)
        let stock = try XCTUnwrap(result.assetClasses.first { $0.name == "股票" })
        XCTAssertEqual(stock.portfolioWeightPct, 72, accuracy: 0.0001)
        XCTAssertTrue(result.warnings.contains { $0.contains("并非实时完整持仓") })
    }

    func testCalculatorReportsMissingAndStaleDisclosure() throws {
        let rows = [
            makeRow(code: "000001", name: "旧披露基金", marketValue: 50_000),
            makeRow(code: "000002", name: "缺失基金", marketValue: 50_000)
        ]
        let stale = disclosure(
            code: "000001",
            name: "旧披露基金",
            holdingWeight: 25,
            industryWeight: 40,
            allocation: nil,
            date: "2025-12-31"
        )

        let result = try XCTUnwrap(
            PortfolioLookThroughCalculator.make(
                rows: rows,
                disclosures: ["000001": stale],
                generatedAt: "2026-07-26 12:00:00"
            )
        )

        XCTAssertEqual(result.fundDataCoveragePct, 50, accuracy: 0.0001)
        XCTAssertTrue(result.warnings.contains { $0.contains("超过 150 天") })
        XCTAssertTrue(result.warnings.contains { $0.contains("1 只基金未取得") })
    }

    func testResearchToolReturnsAggregateAndRecordsDisclosureEvidence() async throws {
        let disclosure = disclosure(
            code: "000001",
            name: "基金 A",
            holdingWeight: 12,
            industryWeight: 30,
            allocation: nil
        )
        let lookThrough = try XCTUnwrap(
            PortfolioLookThroughCalculator.make(
                rows: [makeRow(code: "000001", name: "基金 A", marketValue: 100_000)],
                disclosures: ["000001": disclosure],
                generatedAt: "2026-07-26 12:00:00"
            )
        )
        let snapshot = TrendResearchSnapshot(
            runID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: "2026-07-26 12:00:00",
            dataAsOf: "2026-07-26 12:00:00",
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
            assets: [],
            sectors: [],
            platformSignals: [],
            managerSignals: [],
            marketQuotes: [],
            lookThrough: lookThrough,
            insightHeadline: "测试",
            sourceWarnings: []
        )
        let ledger = TrendEvidenceLedger()
        let context = TrendResearchToolContext(snapshot: snapshot, evidenceLedger: ledger)
        let call = AgentToolCall(
            id: "lookthrough",
            function: AgentToolFunctionCall(
                name: "get_fund_lookthrough",
                arguments: #"{"fund_codes":["000001"]}"#
            )
        )

        let result = await TrendResearchToolRegistry().execute(call, context: context)

        XCTAssertFalse(result.isError)
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.contentJSON.utf8)) as? [String: Any]
        )
        let data = try XCTUnwrap(envelope["data"] as? [String: Any])
        let positions = try XCTUnwrap(data["top_positions"] as? [[String: Any]])
        XCTAssertEqual(positions.first?["code"] as? String, "300308")
        XCTAssertNotNil(data["fund_details"])
        let evidence = await ledger.canonical(for: "fund:look-through:000001:2026-06-30")
        XCTAssertEqual(evidence?.publishedAt, "2026-06-30")
        XCTAssertEqual(evidence?.sourceName, "测试披露")
    }

    private func disclosure(
        code: String,
        name: String,
        holdingWeight: Double,
        industryWeight: Double,
        allocation: FundAssetAllocation?,
        date: String = "2026-06-30"
    ) -> FundLookThroughDisclosure {
        FundLookThroughDisclosure(
            fundCode: code,
            fundName: name,
            asOf: date,
            holdings: [
                FundUnderlyingHolding(
                    code: "300308",
                    name: "中际旭创",
                    kind: .stock,
                    weightPct: holdingWeight,
                    disclosureDate: date
                )
            ],
            industries: [
                FundIndustryExposure(
                    name: "制造业",
                    weightPct: industryWeight,
                    disclosureDate: date
                )
            ],
            assetAllocation: allocation,
            sourceLabel: "测试披露",
            sourceURL: "https://example.com/\(code)",
            warnings: []
        )
    }

    private func makeRow(code: String, name: String, marketValue: Double) -> PersonalAssetAggregateRow {
        let holding = UserPortfolioHolding(
            fundCode: code,
            assetType: .fund,
            units: 10_000,
            costPrice: 1,
            displayName: name
        )
        let valuation = UserPortfolioValuationRow(
            holding: holding,
            fundName: name,
            currentPrice: nil,
            priceTime: nil,
            priceSource: nil,
            officialNav: nil,
            officialNavDate: nil,
            estimatePrice: nil,
            estimatePriceTime: nil,
            marketValue: marketValue,
            costValue: nil,
            profitAmount: nil,
            profitPct: nil,
            estimateChangePct: nil
        )
        return PersonalAssetAggregateRow(
            key: code,
            assetType: .fund,
            fundName: name,
            fundCode: code,
            holdingRow: valuation,
            rawHolding: holding,
            archivedHolding: nil,
            pendingTrades: [],
            plans: []
        )
    }
}
