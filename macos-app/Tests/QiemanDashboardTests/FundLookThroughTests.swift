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

    // MARK: - 失败判定 / 重试 / 磁盘缓存兜底

    func testCompleteSuccessPersistsToDisk() async throws {
        let tempDir = makeTemporaryDirectory()
        let cacheFile = tempDir.appendingPathComponent("fund-look-through-cache.json")
        let responder = DisclosureStubResponder(fundCode: "163402", mode: .allSuccess)
        let session = stubURLSession(responder: responder)

        let client = FundLookThroughClient(
            session: session,
            now: { Date() },
            cacheTTL: 24 * 60 * 60,
            storageFileURL: cacheFile
        )
        let batch = await client.fetchDisclosures(fundCodes: ["163402"])

        let disclosure = try XCTUnwrap(batch.disclosures["163402"])
        // 完整披露：股票 6.45% + 债券 7.05% 全部到位，不再只剩债券冒充完整。
        XCTAssertEqual(disclosure.disclosedSecurityWeightPct, 13.5, accuracy: 0.0001)
        XCTAssertTrue(disclosure.warnings.isEmpty)

        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path))
        let decoder = JSONDecoder()
        let data = try Data(contentsOf: cacheFile)
        let snapshot = try decoder.decode(
            [String: FundLookThroughClient.CachedDisclosure].self,
            from: data
        )
        let persisted = try XCTUnwrap(snapshot["163402"])
        XCTAssertEqual(persisted.disclosure.disclosedSecurityWeightPct, 13.5, accuracy: 0.0001)
    }

    func testPartialFailureFallsBackToDiskCache() async throws {
        let tempDir = makeTemporaryDirectory()
        let cacheFile = tempDir.appendingPathComponent("fund-look-through-cache.json")
        // 预置一份完整披露（含股票 6.45% + 债券 7.05%），loadedAt 留在兜底 TTL 内。
        let seeded = FundLookThroughClient.CachedDisclosure(
            loadedAt: Date(),
            disclosure: disclosure(
                code: "163402",
                name: "兴全趋势",
                holdingWeight: 6.45,
                industryWeight: 30,
                allocation: FundAssetAllocation(
                    stockPct: 80, bondPct: 10, cashPct: 5, otherPct: 5,
                    disclosureDate: "2026-06-30"
                )
            )
        )
        try prewarmDiskCache(at: cacheFile, with: ["163402": seeded])

        // 线上股票接口持续失败，债券/行业/资产配置成功（复刻本次 bug 场景）。
        let responder = DisclosureStubResponder(fundCode: "163402", mode: .stockFails)
        let session = stubURLSession(responder: responder)
        let client = FundLookThroughClient(
            session: session,
            now: { Date() },
            cacheTTL: 24 * 60 * 60,
            fallbackTTL: 120 * 24 * 60 * 60,
            storageFileURL: cacheFile
        )
        let batch = await client.fetchDisclosures(fundCodes: ["163402"])

        let disclosure = try XCTUnwrap(batch.disclosures["163402"])
        // 兜底用的是缓存完整披露：披露证券占基金仍为 6.45%，而不是被债券数据冒充。
        XCTAssertEqual(disclosure.disclosedSecurityWeightPct, 6.45, accuracy: 0.0001)

        // 残缺结果不得覆盖磁盘上已有的完整披露。
        let decoder = JSONDecoder()
        let reread = try decoder.decode(
            [String: FundLookThroughClient.CachedDisclosure].self,
            from: Data(contentsOf: cacheFile)
        )
        let rereadDisclosure = try XCTUnwrap(reread["163402"]?.disclosure)
        XCTAssertEqual(rereadDisclosure.disclosedSecurityWeightPct, 6.45, accuracy: 0.0001)
    }

    func testPartialFailureWithoutCacheIsExcluded() async throws {
        let tempDir = makeTemporaryDirectory()
        let cacheFile = tempDir.appendingPathComponent("fund-look-through-cache.json")
        let responder = DisclosureStubResponder(fundCode: "163402", mode: .stockFails)
        let session = stubURLSession(responder: responder)
        let client = FundLookThroughClient(
            session: session,
            now: { Date() },
            cacheTTL: 24 * 60 * 60,
            fallbackTTL: 120 * 24 * 60 * 60,
            storageFileURL: cacheFile
        )
        let batch = await client.fetchDisclosures(fundCodes: ["163402"])

        // 既无完整抓取、也无缓存兜底：该基金被排除出 disclosures，只进 warnings。
        XCTAssertNil(batch.disclosures["163402"])
        XCTAssertTrue(batch.warnings.contains { $0.contains("163402") })
        // 残缺结果不落盘。
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path))
    }

    func testRetryingRequestRelievesTransientFailure() async throws {
        let tempDir = makeTemporaryDirectory()
        let cacheFile = tempDir.appendingPathComponent("fund-look-through-cache.json")
        // 股票接口前 2 次返回 500，第 3 次成功；其余接口稳定成功。
        let responder = DisclosureStubResponder(
            fundCode: "163402",
            mode: .stockTransientFail(transientFailures: 2)
        )
        let session = stubURLSession(responder: responder)
        let client = FundLookThroughClient(
            session: session,
            now: { Date() },
            cacheTTL: 24 * 60 * 60,
            storageFileURL: cacheFile
        )
        let batch = await client.fetchDisclosures(fundCodes: ["163402"])

        // 重试后四接口最终全部成功 → 完整披露（股票 6.45% + 债券 7.05%）。
        let disclosure = try XCTUnwrap(batch.disclosures["163402"])
        XCTAssertEqual(disclosure.disclosedSecurityWeightPct, 13.5, accuracy: 0.0001)
        XCTAssertEqual(responder.stockAttempts, 3)
    }

    // MARK: - 网络测试辅助

    private func makeTemporaryDirectory() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FundLookThroughTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }

    private func prewarmDiskCache(
        at fileURL: URL,
        with snapshot: [String: FundLookThroughClient.CachedDisclosure]
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    private func stubURLSession(responder: DisclosureStubResponder) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DisclosureStubURLProtocol.self]
        DisclosureStubURLProtocol.responder = { [weak responder] request in
            responder?.respond(to: request) ?? .failure(404)
        }
        return URLSession(configuration: configuration)
    }
}

private struct StubHTTPResponse {
    let statusCode: Int
    let body: String
    static func success(_ body: String) -> StubHTTPResponse {
        StubHTTPResponse(statusCode: 200, body: body)
    }
    static func failure(_ statusCode: Int = 500) -> StubHTTPResponse {
        StubHTTPResponse(statusCode: statusCode, body: "")
    }
}

/// 注入自定义响应的 URLProtocol；测试通过 `responder` 闭包按请求返回成功/失败。
private final class DisclosureStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: @Sendable (URLRequest) -> StubHTTPResponse = { _ in
        .failure()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = Self.responder(request)
        guard let url = request.url,
              let http = HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 按 URL 路径/查询分发到四个披露接口的桩数据，支持全部成功、股票持续失败、股票瞬时失败。
private final class DisclosureStubResponder: @unchecked Sendable {
    enum Mode {
        case allSuccess
        case stockFails
        case stockTransientFail(transientFailures: Int)
    }

    private let fundCode: String
    private let mode: Mode
    private let lock = NSLock()
    private var stockFailRemaining: Int
    private(set) var stockAttempts = 0

    init(fundCode: String, mode: Mode) {
        self.fundCode = fundCode
        self.mode = mode
        switch mode {
        case .stockTransientFail(let n):
            self.stockFailRemaining = n
        default:
            self.stockFailRemaining = 0
        }
    }

    func respond(to request: URLRequest) -> StubHTTPResponse {
        let url = request.url?.absoluteString ?? ""
        if url.contains("FundArchivesDatas.aspx") {
            if url.contains("type=jjcc") {
                return respondToStock()
            }
            if url.contains("type=zqcc") {
                return .success(Self.bondBody(fundCode: fundCode))
            }
        }
        if url.contains("/f10/HYPZ/") {
            return .success(Self.industryBody())
        }
        if url.contains("zcpz_") {
            return .success(Self.allocationBody())
        }
        return .failure(404)
    }

    private func respondToStock() -> StubHTTPResponse {
        lock.lock(); defer { lock.unlock() }
        stockAttempts += 1
        switch mode {
        case .allSuccess:
            return .success(Self.stockBody(fundCode: fundCode))
        case .stockFails:
            return .failure(500)
        case .stockTransientFail:
            if stockFailRemaining > 0 {
                stockFailRemaining -= 1
                return .failure(500)
            }
            return .success(Self.stockBody(fundCode: fundCode))
        }
    }

    private static func stockBody(fundCode: String) -> String {
        """
        var apidata={ content:"<div><a title='测试基金' href='http://fund.eastmoney.com/\(fundCode).html'>测试基金</a>截止至：<font class='px12'>2026-06-30</font><table><tbody>
        <tr><td>1</td><td>300308</td><td class='tol'><a>中际旭创</a></td><td></td><td></td><td>资讯</td><td class='tor'>6.45%</td><td>20.00</td><td>25,400.00</td></tr>
        </tbody></table>"};
        """
    }

    private static func bondBody(fundCode: String) -> String {
        """
        var apidata={ content:"<div><a href='http://fund.eastmoney.com/\(fundCode).html'>测试基金</a>截止至：<font class='px12'>2026-06-30</font><table><tbody>
        <tr><td>1</td><td>019827</td><td class='tol'>26国债01</td><td class='tor'>7.05%</td><td>27,778.90</td></tr>
        </tbody></table>"};
        """
    }

    private static func industryBody() -> String {
        """
        {"Data":{"ShortName":"测试基金","QuarterInfos":[{"JZRQ":"2026-06-30","HYPZInfo":[{"HYMC":"制造业","FSRQ":"2026-06-30","ZJZBL":"30.00"}]}]},"ErrCode":0}
        """
    }

    private static func allocationBody() -> String {
        """
        var Data_assetAllocation = {"series":[{"name":"股票占净比","data":[75.5]},{"name":"债券占净比","data":[18]},{"name":"现金占净比","data":[3.5]}],"categories":["2026-06-30"]};
        """
    }
}
