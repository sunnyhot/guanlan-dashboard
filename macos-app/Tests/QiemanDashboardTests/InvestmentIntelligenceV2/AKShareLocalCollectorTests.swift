import XCTest
import CryptoKit
@testable import QiemanDashboard

#if os(macOS)

/// PROV-3a 单元测试：Swift 侧 staging 摄取与进程外 launcher 的错误路径
///（离线：manifest / JSONL 由测试构造，launcher 用替身 Process，不真跑 Python）。
///
/// 覆盖 DATA007 验收点的失败隔离与可诊断输出：
/// - 单 dataset 失败（collector 报错 / 文件缺 / sha256 不符 / 行损坏 / 全部非法）
///   只标记该 dataset，其他 dataset 照常摄取
/// - SchemaValidator 拒收非法记录（不污染 spool）
/// - watchdog 超时杀进程（launcher 用替身验证，不阻塞测试）
/// - launcher 脚本缺失 / 非零退出码 / 退出码分类
final class AKShareLocalCollectorTests: XCTestCase {

    private var workDir: URL!

    override func setUp() {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prov3a-unit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - 测试用 manifest / JSONL 构造

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.startOfDay(for: cal.date(from: DateComponents(year: y, month: m, day: d))!)
    }

    private func dailyBarRecord(symbol: String = "600519", day: Date) -> ProviderRecord {
        let payload = DailyBarPayload(
            rawOpen: Price(value: Decimal(string: "10.00")!, currency: .cny),
            rawHigh: Price(value: Decimal(string: "11.00")!, currency: .cny),
            rawLow: Price(value: Decimal(string: "9.50")!, currency: .cny),
            rawClose: Price(value: Decimal(string: "10.50")!, currency: .cny),
            volume: 1_000,
            adjustmentFactor: 1,
            fxRate: nil
        )
        return ProviderRecord(
            providerID: .akshare,
            providerCode: ProviderCode(scheme: "stock_symbol", value: symbol),
            effectiveAt: day,
            publishedAt: day,
            ingestedAt: date(2024, 7, 10),
            kind: .dailyBar,
            rawPayload: (try! JSONEncoder().encode(payload)),
            reliabilityClass: .communityAggregated,
            jurisdiction: .chinaMainland
        )
    }

    private func writeJSONL(_ records: [ProviderRecord], name: String) throws -> (fileName: String, sha256: String) {
        let url = workDir.appendingPathComponent(name)
        try ProviderStagingWriter().write(records, to: url)
        let digest = Data(SHA256.hash(data: try Data(contentsOf: url)))
            .map { String(format: "%02x", $0) }.joined()
        return (name, digest)
    }

    private func okStatus(file: String, sha256: String, count: Int) -> AKShareStagingManifest.DatasetStatus {
        AKShareStagingManifest.DatasetStatus(
            status: "ok", recordCount: count, droppedMalformed: [:],
            errorCategory: nil, errorMessage: nil, file: file, sha256: sha256
        )
    }

    private func errorStatus(category: String, message: String) -> AKShareStagingManifest.DatasetStatus {
        AKShareStagingManifest.DatasetStatus(
            status: "error", recordCount: 0, droppedMalformed: [:],
            errorCategory: category, errorMessage: message, file: nil, sha256: nil
        )
    }

    @discardableResult
    private func writeManifest(_ datasets: [String: AKShareStagingManifest.DatasetStatus]) throws -> URL {
        let manifest = AKShareStagingManifest(
            collectorVersion: "0.1.0", generatedAt: date(2024, 7, 10),
            mode: "collect", datasets: datasets
        )
        let url = workDir.appendingPathComponent("manifest.json")
        let data = try ProviderStaging.defaultEncoder.encode(manifest)
        try data.write(to: url)
        return url
    }

    // MARK: - Manifest 模型

    func testManifest_roundTripThroughDefaultEncoder() throws {
        // Python 侧 manifest 字段（camelCase + iso8601 日期）与 Swift Codable 对齐
        let json = """
        {"collectorVersion":"0.1.0","generatedAt":"2024-07-10T00:00:00Z","mode":"collect",
         "datasets":{"stock_daily":{"status":"ok","recordCount":2,"droppedMalformed":{"malformed_row":1},
         "errorCategory":null,"errorMessage":null,"file":"stock_daily.jsonl","sha256":"abc"}}}
        """
        let manifest = try ProviderStaging.defaultDecoder.decode(
            AKShareStagingManifest.self, from: json.data(using: .utf8)!
        )
        XCTAssertEqual(manifest.collectorVersion, "0.1.0")
        XCTAssertEqual(manifest.mode, "collect")
        XCTAssertEqual(manifest.okDatasetCount, 1)
        let stock = manifest.datasets["stock_daily"]
        XCTAssertEqual(stock?.droppedMalformed, ["malformed_row": 1])
    }

    // MARK: - 摄取：成功路径

    func testIngest_appendsValidRecordsToSpool() throws {
        let records = [
            dailyBarRecord(day: date(2024, 7, 1)),
            dailyBarRecord(day: date(2024, 7, 2)),
        ]
        let (file, sha) = try writeJSONL(records, name: "stock_daily.jsonl")
        try writeManifest(["stock_daily": okStatus(file: file, sha256: sha, count: 2)])

        let spool = workDir.appendingPathComponent("spool.jsonl")
        let (_, results) = try AKShareStagingIngestor().ingest(from: workDir, toSpool: spool)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].dataset, .stockDaily)
        XCTAssertTrue(results[0].isSuccess)
        XCTAssertEqual(results[0].stagedCount, 2)
        XCTAssertEqual(results[0].rejectedCount, 0)
        let spooled = try ProviderStagingReader().read(from: spool)
        XCTAssertEqual(spooled, records, "spool 内容应与 collector staging 等价")
    }

    // MARK: - 失败隔离：单 dataset 失败不影响其他

    func testIngest_collectorReportedErrorIsolated() throws {
        // stock_daily 在 Python 侧就失败（网络）；fund_nav 正常 → 只有前者标记失败
        let records = [dailyBarRecord(day: date(2024, 7, 1))]
        let (file, sha) = try writeJSONL(records, name: "fund_nav.jsonl")
        try writeManifest([
            "stock_daily": errorStatus(category: "network", message: "ConnectionError: upstream timeout"),
            "fund_nav": okStatus(file: file, sha256: sha, count: 1),
        ])

        let spool = workDir.appendingPathComponent("spool.jsonl")
        let (_, results) = try AKShareStagingIngestor().ingest(from: workDir, toSpool: spool)
        let stock = results.first { $0.dataset == .stockDaily }
        XCTAssertEqual(stock?.failure, .collectorReported(
            category: "network", message: "ConnectionError: upstream timeout"
        ))
        XCTAssertEqual(stock?.stagedCount, 0)
        let fund = results.first { $0.dataset == .fundNAV }
        XCTAssertTrue(fund?.isSuccess ?? false)
        XCTAssertEqual(fund?.stagedCount, 1)
        // spool 里只有 fund_nav 的记录（失败 dataset 不写任何东西）
        XCTAssertEqual(try ProviderStagingReader().read(from: spool).count, 1)
    }

    func testIngest_checksumMismatchRejected() throws {
        let records = [dailyBarRecord(day: date(2024, 7, 1))]
        let (file, _) = try writeJSONL(records, name: "stock_daily.jsonl")
        try writeManifest(["stock_daily": okStatus(file: file, sha256: "deadbeef", count: 1)])

        let spool = workDir.appendingPathComponent("spool.jsonl")
        let (_, results) = try AKShareStagingIngestor().ingest(from: workDir, toSpool: spool)
        XCTAssertEqual(results[0].failure, .checksumMismatch(fileName: "stock_daily.jsonl"))
        XCTAssertEqual(results[0].stagedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.path), "校验失败不应写 spool")
    }

    func testIngest_fileMissingIsolated() throws {
        let records = [dailyBarRecord(day: date(2024, 7, 1))]
        let (file, sha) = try writeJSONL(records, name: "fund_nav.jsonl")
        try writeManifest([
            // manifest 声明 ok 但文件实际不存在（外部删除）
            "stock_daily": okStatus(file: "stock_daily.jsonl", sha256: "abc", count: 1),
            "fund_nav": okStatus(file: file, sha256: sha, count: 1),
        ])
        let spool = workDir.appendingPathComponent("spool.jsonl")
        let (_, results) = try AKShareStagingIngestor().ingest(from: workDir, toSpool: spool)
        XCTAssertEqual(results.first { $0.dataset == .stockDaily }?.failure, .fileMissing(fileName: "stock_daily.jsonl"))
        XCTAssertTrue(results.first { $0.dataset == .fundNAV }?.isSuccess ?? false)
    }

    func testIngest_malformedLineFailsOnlyThatDataset() throws {
        let good = [dailyBarRecord(day: date(2024, 7, 1))]
        let (navFile, navSha) = try writeJSONL(good, name: "fund_nav.jsonl")
        // 手工构造带损坏行的 JSONL（第 2 行不是 JSON）
        let badURL = workDir.appendingPathComponent("stock_daily.jsonl")
        try "{\"providerID\":{\"rawValue\":\"akshare\"}\n{corrupt\n".data(using: .utf8)!.write(to: badURL)
        let badSha = Data(SHA256.hash(data: try Data(contentsOf: badURL))).map { String(format: "%02x", $0) }.joined()
        try writeManifest([
            "stock_daily": okStatus(file: "stock_daily.jsonl", sha256: badSha, count: 2),
            "fund_nav": okStatus(file: navFile, sha256: navSha, count: 1),
        ])

        let spool = workDir.appendingPathComponent("spool.jsonl")
        let (_, results) = try AKShareStagingIngestor().ingest(from: workDir, toSpool: spool)
        let stock = results.first { $0.dataset == .stockDaily }
        guard case .malformedLine(let line, _)? = stock?.failure else {
            XCTFail("expected malformedLine, got \(String(describing: stock?.failure))")
            return
        }
        XCTAssertGreaterThan(line, 0, "损坏行应带行号")
        XCTAssertTrue(results.first { $0.dataset == .fundNAV }?.isSuccess ?? false, "损坏隔离在 dataset 级")
    }

    func testIngest_schemaInvalidRecordsRejectedNotPollutingSpool() throws {
        // 构造一条 kind=dailyBar 但 payload 是 NAVPayload 的记录（schema 不匹配）
        // —— SchemaValidator 应拒收；其余合法记录照常入 spool。
        let navPayload = NAVPayload(
            unitNAV: Price(value: 1, currency: .cny), accumulatedNAV: nil, cumulativeDividendPerShare: nil
        )
        let mismatch = ProviderRecord(
            providerID: .akshare,
            providerCode: ProviderCode(scheme: "stock_symbol", value: "600519"),
            effectiveAt: date(2024, 7, 1), publishedAt: date(2024, 7, 1), ingestedAt: date(2024, 7, 10),
            kind: .dailyBar,
            rawPayload: try JSONEncoder().encode(navPayload),
            reliabilityClass: .communityAggregated,
            jurisdiction: .chinaMainland
        )
        let records = [dailyBarRecord(day: date(2024, 7, 1)), mismatch]
        let (file, sha) = try writeJSONL(records, name: "stock_daily.jsonl")
        try writeManifest(["stock_daily": okStatus(file: file, sha256: sha, count: 2)])

        let spool = workDir.appendingPathComponent("spool.jsonl")
        let (_, results) = try AKShareStagingIngestor().ingest(from: workDir, toSpool: spool)
        XCTAssertEqual(results[0].stagedCount, 1, "合法记录照常入 spool")
        XCTAssertEqual(results[0].rejectedCount, 1, "kind/payload 不匹配被 SchemaValidator 拒收")
        let spooled = try ProviderStagingReader().read(from: spool)
        XCTAssertEqual(spooled.count, 1)
        XCTAssertEqual(spooled[0].kind, .dailyBar)
    }

    func testIngest_allRecordsRejectedReportsSchemaDrift() throws {
        let navPayload = NAVPayload(
            unitNAV: Price(value: 1, currency: .cny), accumulatedNAV: nil, cumulativeDividendPerShare: nil
        )
        let mismatch = ProviderRecord(
            providerID: .akshare,
            providerCode: ProviderCode(scheme: "stock_symbol", value: "600519"),
            effectiveAt: date(2024, 7, 1), publishedAt: date(2024, 7, 1), ingestedAt: date(2024, 7, 10),
            kind: .dailyBar,
            rawPayload: try JSONEncoder().encode(navPayload),
            reliabilityClass: .communityAggregated,
            jurisdiction: .chinaMainland
        )
        let (file, sha) = try writeJSONL([mismatch], name: "stock_daily.jsonl")
        try writeManifest(["stock_daily": okStatus(file: file, sha256: sha, count: 1)])
        let spool = workDir.appendingPathComponent("spool.jsonl")
        let (_, results) = try AKShareStagingIngestor().ingest(from: workDir, toSpool: spool)
        guard case .allRecordsRejected(let total, _)? = results[0].failure else {
            XCTFail("expected allRecordsRejected")
            return
        }
        XCTAssertEqual(total, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.path), "全拒收不应写 spool")
    }

    func testIngest_missingManifestThrows() {
        let spool = workDir.appendingPathComponent("spool.jsonl")
        XCTAssertThrowsError(try AKShareStagingIngestor().ingest(from: workDir, toSpool: spool)) { error in
            guard case ProviderStagingError.readFailed = error else {
                XCTFail("expected readFailed, got \(error)")
                return
            }
        }
    }

    /// 前向兼容：未来 collector 新增 dataset key（Swift 枚举没有）→ 跳过不摄取，不报错。
    func testIngest_unknownDatasetKeySkipped() throws {
        let records = [dailyBarRecord(day: date(2024, 7, 1))]
        let (file, sha) = try writeJSONL(records, name: "stock_daily.jsonl")
        try writeManifest([
            "stock_daily": okStatus(file: file, sha256: sha, count: 1),
            "bond_daily": okStatus(file: "bond_daily.jsonl", sha256: "xyz", count: 5),  // 未来 dataset
        ])
        let spool = workDir.appendingPathComponent("spool.jsonl")
        let (_, results) = try AKShareStagingIngestor().ingest(from: workDir, toSpool: spool)
        XCTAssertEqual(results.count, 1, "未知 dataset 被跳过")
        XCTAssertEqual(results[0].dataset, .stockDaily)
    }

    /// sha256 校验可通过 verifyChecksums 关闭（本地可信目录 / 性能场景）。
    func testIngest_checksumVerificationOptional() throws {
        let records = [dailyBarRecord(day: date(2024, 7, 1))]
        let (file, _) = try writeJSONL(records, name: "stock_daily.jsonl")
        try writeManifest(["stock_daily": okStatus(file: file, sha256: "wrong", count: 1)])
        let spool = workDir.appendingPathComponent("spool.jsonl")
        let ingestor = AKShareStagingIngestor(verifyChecksums: false)
        let (_, results) = try ingestor.ingest(from: workDir, toSpool: spool)
        XCTAssertTrue(results[0].isSuccess, "关闭校验后 sha 不符不拦截")
    }

    // MARK: - Launcher（替身 Process，不真跑 Python）

    func testLauncher_scriptNotFound() async {
        let launcher = AKShareLocalCollectorLauncher(processFactory: { StubProcess() })
        do {
            try await launcher.run(
                scriptURL: workDir.appendingPathComponent("nope.py"),
                outDir: workDir.appendingPathComponent("out")
            )
            XCTFail("expected scriptNotFound")
        } catch let error as AKShareCollectorError {
            guard case .scriptNotFound = error else {
                XCTFail("expected scriptNotFound, got \(error)")
                return
            }
        } catch {
            XCTFail("expected AKShareCollectorError, got \(error)")
        }
    }

    func testLauncher_nonzeroExitSurfacesStderrTail() async throws {
        // 脚本存在（touch 一个空文件即可通过存在性检查）；替身返回 exit 2
        let script = workDir.appendingPathComponent("fake_collector.py")
        try "".write(to: script, atomically: true, encoding: .utf8)
        let launcher = AKShareLocalCollectorLauncher(processFactory: {
            StubProcess(exitCode: 2, stderrText: "[akshare-collector] 环境错误: akshare 未安装")
        })
        do {
            try await launcher.run(scriptURL: script, outDir: workDir.appendingPathComponent("out"))
            XCTFail("expected nonzeroExit")
        } catch let error as AKShareCollectorError {
            guard case .nonzeroExit(let code, let tail) = error else {
                XCTFail("expected nonzeroExit, got \(error)")
                return
            }
            XCTAssertEqual(code, 2)
            XCTAssertTrue(tail.contains("akshare 未安装"), "stderr 尾部应带回可诊断信息")
        }
    }

    func testLauncher_watchdogTimesOutAndTerminates() async throws {
        // 替身永远不退出 → watchdog 超时 terminate + 抛 timedOut（不无限等待）
        let script = workDir.appendingPathComponent("fake_collector.py")
        try "".write(to: script, atomically: true, encoding: .utf8)
        let stub = HangingProcess()
        var launcher = AKShareLocalCollectorLauncher(processFactory: { stub })
        launcher.timeoutSeconds = 0.2
        do {
            try await launcher.run(scriptURL: script, outDir: workDir.appendingPathComponent("out"))
            XCTFail("expected timedOut")
        } catch let error as AKShareCollectorError {
            guard case .timedOut = error else {
                XCTFail("expected timedOut, got \(error)")
                return
            }
        }
        // 给 watchdog 任务一拍执行 terminate
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(stub.terminated, "watchdog 超时必须杀进程（DATA007 §Decision 3）")
    }

    func testLauncher_successPassesArgumentsThrough() async throws {
        let script = workDir.appendingPathComponent("fake_collector.py")
        try "".write(to: script, atomically: true, encoding: .utf8)
        let stub = StubProcess(exitCode: 0)
        let launcher = AKShareLocalCollectorLauncher(processFactory: { stub })
        try await launcher.run(
            scriptURL: script,
            outDir: workDir.appendingPathComponent("out"),
            datasets: [.stockDaily, .fundNAV],
            selftest: true
        )
        XCTAssertEqual(stub.capturedPythonPath?.hasSuffix("python3"), true)
        let args = stub.capturedArguments ?? []
        XCTAssertTrue(args.contains("--selftest"))
        XCTAssertTrue(args.contains("--dataset"))
        XCTAssertEqual(args[args.firstIndex(of: "--dataset")! + 1], "stock_daily,fund_nav")
        XCTAssertTrue(args.contains(where: { $0.hasSuffix("out") }), "应传 --out-dir")
    }
}

// MARK: - 替身 Process

private final class StubProcess: CollectorProcess, @unchecked Sendable {
    private let exitCode: Int32
    private let stderrText: String
    private let lock = NSLock()
    private var _capturedPythonPath: String?
    private var _capturedArguments: [String]?

    init(exitCode: Int32 = 0, stderrText: String = "") {
        self.exitCode = exitCode
        self.stderrText = stderrText
    }

    var capturedPythonPath: String? { lock.lock(); defer { lock.unlock() }; return _capturedPythonPath }
    var capturedArguments: [String]? { lock.lock(); defer { lock.unlock() }; return _capturedArguments }

    func launch(pythonPath: String, arguments: [String], stderrSink: @escaping @Sendable (String) -> Void) throws {
        lock.lock()
        _capturedPythonPath = pythonPath
        _capturedArguments = arguments
        lock.unlock()
        if !stderrText.isEmpty { stderrSink(stderrText) }
    }

    func waitUntilExit() async throws -> Int32 { exitCode }

    func terminate() {}
}

/// 永不退出的替身（watchdog 测试）。
private final class HangingProcess: CollectorProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var _terminated = false
    var terminated: Bool { lock.lock(); defer { lock.unlock() }; return _terminated }

    func launch(pythonPath: String, arguments: [String], stderrSink: @escaping @Sendable (String) -> Void) throws {}

    func waitUntilExit() async throws -> Int32 {
        while true {
            try await Task.sleep(nanoseconds: 10_000_000)
            try Task.checkCancellation()
        }
    }

    func terminate() {
        lock.lock()
        _terminated = true
        lock.unlock()
    }
}

#endif
