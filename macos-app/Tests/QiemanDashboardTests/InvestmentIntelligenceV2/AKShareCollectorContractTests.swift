import XCTest
import CryptoKit
@testable import QiemanDashboard

#if os(macOS)

/// PROV-3a 跨语言契约测试（DATA010 §Compliance「Python 产出的 JSONL 字节对齐
/// Swift ProviderRecord Codable」；该要求对 PROV-3a 本地路径同样适用）。
///
/// 运行 Python collector `--selftest`（离线：不联网、不依赖 akshare 安装），
/// 其输出走与生产完全相同的组装 / 序列化 / 落盘路径，然后断言 Swift 侧
/// ProviderStagingReader → SchemaValidator → ObservationFactory 全链路通过。
///
/// 环境守卫：本机没有 python3 时整组跳过（CI / 无 Python 环境可跑其余测试），
/// 不算失败——可选安装是 DATA007 的产品约束，不是测试前置。
final class AKShareCollectorContractTests: XCTestCase {

    private var stagingDir: URL!
    private var spoolURL: URL!

    override func setUpWithError() throws {
        // 脚本位置：macos-app/InvestmentIntelligenceV2/Collector/akshare_collector.py。
        // #filePath = .../macos-app/Tests/QiemanDashboardTests/InvestmentIntelligenceV2/<this file>，
        // 上溯 3 级到 macos-app/，再进 InvestmentIntelligenceV2/Collector/。
        let thisFile = URL(fileURLWithPath: #filePath)
        let collectorScript = thisFile.deletingLastPathComponent()      // .../InvestmentIntelligenceV2
            .deletingLastPathComponent()                                  // .../QiemanDashboardTests
            .deletingLastPathComponent()                                  // .../Tests
            .deletingLastPathComponent()                                  // .../macos-app
            .appendingPathComponent("InvestmentIntelligenceV2/Collector/akshare_collector.py")
        guard FileManager.default.fileExists(atPath: collectorScript.path) else {
            throw XCTSkip("collector 脚本不在源码树预期位置: \(collectorScript.path)")
        }

        let pythonCandidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        guard let python = pythonCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw XCTSkip("本机无 python3（可选组件），跳过跨语言契约测试")
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prov3a-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stagingDir = dir
        spoolURL = dir.appendingPathComponent("spool.jsonl")

        // 进程外运行 collector --selftest（DATA007：Python 只活在子进程里）
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [collectorScript.path, "--out-dir", dir.path, "--selftest"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "collector --selftest 应 exit 0")
    }

    override func tearDown() {
        if let stagingDir { try? FileManager.default.removeItem(at: stagingDir) }
    }

    // MARK: - manifest 契约

    func testManifest_decodesCollectorOutput() throws {
        let manifestURL = stagingDir.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try ProviderStaging.defaultDecoder.decode(AKShareStagingManifest.self, from: data)
        XCTAssertEqual(manifest.collectorVersion, "0.1.0")
        XCTAssertEqual(manifest.mode, "selftest")
        XCTAssertEqual(manifest.okDatasetCount, 5, "selftest 应 5 个 dataset 全 ok")
        XCTAssertEqual(manifest.failedDatasetCount, 0)
        for (name, status) in manifest.datasets {
            XCTAssertTrue(status.isOK, "\(name) 应为 ok")
            XCTAssertNotNil(status.file, "\(name) 应有 staging 文件名")
            XCTAssertNotNil(status.sha256, "\(name) 应有完整性摘要")
        }
    }

    // MARK: - JSONL 契约：Reader → SchemaValidator 全链路

    func testAllDatasetRecords_decodeValidateAndPassSchema() throws {
        let (manifest, _) = try ingestToSpool()
        for (name, status) in manifest.datasets {
            XCTAssertEqual(status.recordCount > 0, true, "\(name) 应有记录")
            let fileURL = stagingDir.appendingPathComponent(status.file!)
            let records = try ProviderStagingReader().read(from: fileURL)
            XCTAssertEqual(records.count, status.recordCount, "\(name) JSONL 行数应与 manifest recordCount 一致")
            for record in records {
                XCTAssertEqual(record.providerID, .akshare, "\(name) providerID 应为 akshare")
                XCTAssertEqual(record.reliabilityClass, .communityAggregated)
                XCTAssertEqual(record.jurisdiction, .chinaMainland)
            }
            // SchemaValidator：全部合法（Python 侧组装的字节对齐 Swift payload schema）
            let (_, invalid) = ProviderRecordSchemaValidator().partition(records)
            XCTAssertTrue(invalid.isEmpty, "\(name) 不应有非法记录: \(invalid.map(\.error))")
        }
    }

    /// CN 交易日界契约：A 股 2024-07-01 应是上海零点的 UTC 瞬时
    ///（与 EastmoneyResponseParser.normalizeToTradingDay 同一约定，跨源去重前提）。
    func testCNTradingDayBoundary_contract() throws {
        let records = try readDataset(.stockDaily)
        let first = try XCTUnwrap(records.first)
        XCTAssertEqual(first.effectiveAt, AKShareCollectorContractTests.utc(2024, 6, 30, 16))
        XCTAssertEqual(first.publishedAt, first.effectiveAt, "日线 publishedAt = effectiveAt")
        XCTAssertEqual(first.kind, .dailyBar)
        XCTAssertEqual(first.providerCode, ProviderCode(scheme: "stock_symbol", value: "600519"))
        // payload：raw 不复权、CNY
        let payload = try JSONDecoder().decode(DailyBarPayload.self, from: first.rawPayload)
        XCTAssertEqual(payload.rawOpen, Price(value: Decimal(string: "1425.00")!, currency: .cny))
        XCTAssertEqual(payload.rawClose, Price(value: Decimal(string: "1436.28")!, currency: .cny))
        XCTAssertEqual(payload.adjustmentFactor, 1, "raw 不复权，factor=1 不伪造")
        XCTAssertEqual(payload.volume, 2_896_700)
    }

    func testFundNAVPayload_contract() throws {
        let records = try readDataset(.fundNAV)
        XCTAssertEqual(records.count, 2)
        let first = records[0]
        XCTAssertEqual(first.kind, .navObservation)
        XCTAssertEqual(first.providerCode, ProviderCode(scheme: "fund_code", value: "110022"))
        let payload = try JSONDecoder().decode(NAVPayload.self, from: first.rawPayload)
        XCTAssertEqual(payload.unitNAV, Price(value: Decimal(string: "3.1830")!, currency: .cny))
        XCTAssertEqual(payload.accumulatedNAV, Price(value: Decimal(string: "4.8241")!, currency: .cny))
        XCTAssertNil(payload.cumulativeDividendPerShare, "上游不披露分红，留 nil 不伪造")
    }

    func testFundHoldingsPayload_contract() throws {
        let records = try readDataset(.fundHoldings)
        XCTAssertEqual(records.count, 1)
        let record = records[0]
        XCTAssertEqual(record.kind, .fundHoldingSnapshot)
        // 报告期 2024Q2 → effectiveAt = 季度末 2024-06-30（上海零点 = 前一日 16:00Z）
        XCTAssertEqual(record.effectiveAt, AKShareCollectorContractTests.utc(2024, 6, 29, 16))
        let payload = try JSONDecoder().decode(FundHoldingPayload.self, from: record.rawPayload)
        XCTAssertEqual(payload.reportPeriod, .q2)
        XCTAssertEqual(payload.positions.count, 2)
        let topPosition = payload.positions[0]
        XCTAssertEqual(topPosition.providerCode, ProviderCode(scheme: "stock_symbol", value: "600519"))
        XCTAssertEqual(topPosition.weight, Ratio(value: Decimal(string: "0.0998")!))
        XCTAssertEqual(topPosition.isDisclosed, true)
        XCTAssertEqual(payload.disclosedWeightTotal, Ratio(value: Decimal(string: "0.1874")!))
    }

    func testMacroPayload_contract() throws {
        let records = try readDataset(.macroChina)
        XCTAssertEqual(records.count, 2)
        let first = records[0]
        XCTAssertEqual(first.kind, .macroObservation)
        XCTAssertEqual(first.providerCode, ProviderCode(scheme: "ak_macro_series", value: "gdp_yearly"))
        // FRED 惯例：观测期起始 2024Q1 → 2024-01-01（上海零点 UTC 瞬时 = 前一日 16:00Z）
        XCTAssertEqual(first.effectiveAt, AKShareCollectorContractTests.utc(2023, 12, 31, 16))
        let payload = try JSONDecoder().decode(MacroPayload.self, from: first.rawPayload)
        XCTAssertEqual(payload.value, Decimal(string: "5.3")!)
        XCTAssertEqual(payload.unit, .percent)
        XCTAssertEqual(payload.frequency, .quarterly)
        XCTAssertEqual(payload.isSeasonallyAdjusted, false)
        XCTAssertEqual(first.publishedAt, first.effectiveAt, "AKShare 无公布时间，不发明")
    }

    /// 指数 dataset：scheme=index_code，与个股 stock_symbol 区分。
    func testIndexDataset_contract() throws {
        let records = try readDataset(.indexDaily)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].providerCode, ProviderCode(scheme: "index_code", value: "000300"))
        XCTAssertEqual(records[0].kind, .dailyBar)
    }

    // MARK: - ObservationFactory 语义链（记录可转 Canonical 候选）

    func testDailyBarRecord_passesObservationFactory() throws {
        // Python 产的 ProviderRecord 不止结构合法，还能走完 Swift 语义转换链
        //（identity 解析用 fixture 映射 600519 → Listing；未映射标的抛
        // identityUnresolved 是防火墙 1 的合法拒收，不要求 collector 数据带 identity）。
        let records = try readDataset(.stockDaily)
        let resolver = IdentityResolver.from([
            ProviderIdentifier(
                providerID: .akshare, identifierScheme: "stock_symbol", identifierValue: "600519",
                canonical: .listing(ListingID(rawValue: "list_sh600519")),
                resolutionMethod: .exchangeSymbolExact,
                resolvedAt: Date(timeIntervalSince1970: 0)
            )
        ])
        let factory = ObservationFactory(
            normalizer: TemporalNormalizer(calendar: WeekdayCalendar()), resolver: resolver
        )
        for (index, record) in records.enumerated() {
            let observation = try factory.makeObservation(
                from: record,
                observationID: ObservationID(rawValue: "obs_test_\(record.effectiveAt.timeIntervalSince1970)"),
                vintage: Vintage(announcementDate: record.publishedAt, publisherVersion: 1)
            )
            guard case .dailyBar(let bar) = observation else {
                XCTFail("expected dailyBar, got \(observation)")
                continue
            }
            XCTAssertEqual(bar.dataQuality.sourceProviderID, .akshare)
            // selftest 样本：第 1 条 close 1436.28、第 2 条 1445.00
            let expectedClose: Decimal = index == 0 ? Decimal(string: "1436.28")! : Decimal(string: "1445.00")!
            XCTAssertEqual(bar.rawClose, Price(value: expectedClose, currency: .cny))
        }
    }

    // MARK: - 摄取（Ingestor）集成

    func testIngestor_appendsAllDatasetsToSpool() throws {
        let (manifest, results) = try ingestToSpool()
        XCTAssertEqual(manifest.okDatasetCount, 5)
        XCTAssertEqual(results.count, 5)
        for result in results {
            XCTAssertTrue(result.isSuccess, "\(result.dataset) 摄取应成功: \(String(describing: result.failure))")
            XCTAssertGreaterThan(result.stagedCount, 0)
            XCTAssertEqual(result.rejectedCount, 0)
        }
        // spool 是全部 dataset 追加后的总行数
        let spoolRecords = try ProviderStagingReader().read(from: spoolURL)
        let expectedTotal = results.reduce(0) { $0 + $1.stagedCount }
        XCTAssertEqual(spoolRecords.count, expectedTotal)
        XCTAssertEqual(
            Set(spoolRecords.map(\.kind)),
            [.dailyBar, .navObservation, .fundHoldingSnapshot, .macroObservation],
            "5 个 dataset 覆盖 4 种 ProviderRecordKind"
        )
    }

    // MARK: - helpers

    private func ingestToSpool() throws -> (AKShareStagingManifest, [AKShareDatasetIngestResult]) {
        try AKShareStagingIngestor().ingest(from: stagingDir, toSpool: spoolURL)
    }

    private func readDataset(_ dataset: AKShareDataset) throws -> [ProviderRecord] {
        let fileURL = stagingDir.appendingPathComponent(dataset.fileName)
        return try ProviderStagingReader().read(from: fileURL)
    }

    private static func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Date {
        var components = DateComponents()
        components.year = y; components.month = m; components.day = d; components.hour = h
        components.timeZone = TimeZone(identifier: "UTC")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: components)!
    }
}

/// 周一~周五视为交易日的日历桩（与 FREDAdapterTests 同款；ObservationFactory
/// 语义链测试用，A 股节假日历不在 PROV-3a 范围）。
private struct WeekdayCalendar: TradingCalendar {
    func isTradingDay(_ date: Date, jurisdiction: Jurisdiction) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let w = cal.component(.weekday, from: date)
        return w >= 2 && w <= 6
    }
    func tradingDay(after date: Date, offset: Int, jurisdiction: Jurisdiction) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var current = date; var remaining = max(offset, 0); var safety = 0
        while remaining > 0 && safety < 14 {
            current = cal.date(byAdding: .day, value: 1, to: current)!
            if isTradingDay(current, jurisdiction: jurisdiction) { remaining -= 1 }
            safety += 1
        }
        return current
    }
    func tradingDayStart(_ date: Date, jurisdiction: Jurisdiction) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.startOfDay(for: date)
    }
}

#endif
