import XCTest
@testable import QiemanDashboard

/// PROV-3b App 生产接线测试：配置面（RemoteStagingSyncConfig + Store）、
/// 路径布局（RemoteStagingSyncPaths）、装配（RemoteStagingSyncSetup，含
/// 「配错显式上报、不静默降级」的验签开关语义）、以及 config → provider →
/// sync 的端到端 wiring（FakeRemoteFetcher 注入，离线）。
///
/// AppModel 侧循环（启动/6h 周期/取消）是薄胶水，其全部决策逻辑都在
/// Setup/Config 中被本文件覆盖；AppModel.startRemoteStagingSyncLoopIfNeeded
/// 的每个分支与 Setup 分支一一对应。
final class RemoteStagingSyncWiringTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prov3b-wiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Config Store

    func testConfigStore_missingFile_returnsNil() throws {
        let url = tempDir.appendingPathComponent("absent.json")
        XCTAssertNil(try RemoteStagingSyncConfigStore.load(from: url))
    }

    func testConfigStore_roundTrip() throws {
        let url = tempDir.appendingPathComponent("cfg.json")
        let config = RemoteStagingSyncConfig(
            enabled: true,
            baseURL: "https://collector.example.com/staging/",
            collectorKey: "  k-123  ",
            signaturePublicKeyBase64: nil
        )
        try RemoteStagingSyncConfigStore.save(config, to: url)
        let loaded = try XCTUnwrap(try RemoteStagingSyncConfigStore.load(from: url))
        XCTAssertEqual(loaded, config)
        XCTAssertEqual(loaded.trimmedCollectorKey, "k-123", "key 前后空白应剥掉")
    }

    func testConfigStore_malformedJSON_throws() throws {
        let url = tempDir.appendingPathComponent("bad.json")
        try Data("{not-json".utf8).write(to: url)
        XCTAssertThrowsError(try RemoteStagingSyncConfigStore.load(from: url)) { error in
            guard case RemoteStagingSyncConfigError.malformed = error else {
                XCTFail("expected malformed, got \(error)")
                return
            }
        }
    }

    func testConfigStore_decodeIgnoresUnknownKeys_forForwardCompatibility() throws {
        // 服务端/未来版本给配置文件加字段不应让旧客户端直接拒读
        let url = tempDir.appendingPathComponent("cfg2.json")
        let json = #"{"enabled":true,"baseURL":"https://v.example.com/s","futureField":42}"#
        try Data(json.utf8).write(to: url)
        let loaded = try XCTUnwrap(try RemoteStagingSyncConfigStore.load(from: url))
        XCTAssertTrue(loaded.isRunnable)
    }

    // MARK: - Config 校验

    func testConfig_isRunnable_requiresEnabledAndValidBaseURL() {
        XCTAssertFalse(RemoteStagingSyncConfig.disabled.isRunnable)

        XCTAssertFalse(RemoteStagingSyncConfig(
            enabled: true, baseURL: "", collectorKey: nil, signaturePublicKeyBase64: nil
        ).isRunnable, "enabled 但空 baseURL 不可运行")

        XCTAssertFalse(RemoteStagingSyncConfig(
            enabled: true, baseURL: "ftp://v.example.com/s", collectorKey: nil, signaturePublicKeyBase64: nil
        ).isRunnable, "非 http(s) scheme 不可运行")

        XCTAssertFalse(RemoteStagingSyncConfig(
            enabled: true, baseURL: "not a url", collectorKey: nil, signaturePublicKeyBase64: nil
        ).isRunnable)

        XCTAssertTrue(RemoteStagingSyncConfig(
            enabled: true, baseURL: "https://v.example.com/staging", collectorKey: nil, signaturePublicKeyBase64: nil
        ).isRunnable)
    }

    // MARK: - 路径布局

    func testPaths_layoutUnderDataDirectory() {
        let dataDir = URL(fileURLWithPath: "/data", isDirectory: true)
        XCTAssertEqual(
            RemoteStagingSyncPaths.configURL(in: dataDir),
            URL(fileURLWithPath: "/data/remote-staging-sync.json")
        )
        XCTAssertEqual(
            RemoteStagingSyncPaths.spoolURL(in: dataDir),
            URL(fileURLWithPath: "/data/investment-intelligence-v2/remote-staging/spool.jsonl")
        )
        XCTAssertEqual(
            RemoteStagingSyncPaths.stateURL(in: dataDir),
            URL(fileURLWithPath: "/data/investment-intelligence-v2/remote-staging/state.json")
        )
    }

    // MARK: - Setup 装配（配置错误显式上报，不静默降级）

    func testSetup_disabledConfig_notConfigured() {
        if case .notConfigured = RemoteStagingSyncSetup.make(config: .disabled) {
            // expected
        } else {
            XCTFail("disabled 应为 notConfigured")
        }
    }

    func testSetup_enabledButInvalidURL_notConfiguredWithReason() {
        let config = RemoteStagingSyncConfig(
            enabled: true, baseURL: "://bad", collectorKey: nil, signaturePublicKeyBase64: nil
        )
        guard case .notConfigured(let reason) = RemoteStagingSyncSetup.make(config: config) else {
            XCTFail("enabled + 非法 baseURL 应为 notConfigured")
            return
        }
        XCTAssertTrue(reason.contains("baseURL"), "原因应指明 baseURL 问题：\(reason)")
    }

    func testSetup_invalidBase64PublicKey_misconfigured_notSilentlyUnsigned() {
        // DATA010 §5 + fail-loud：配了公钥但字节非法 → 显式错误，绝不回退未验签
        let config = RemoteStagingSyncConfig(
            enabled: true,
            baseURL: "https://v.example.com/staging",
            collectorKey: nil,
            signaturePublicKeyBase64: "!!not-base64!!"
        )
        guard case .misconfigured(let detail) = RemoteStagingSyncSetup.make(config: config) else {
            XCTFail("非法 base64 公钥应为 misconfigured")
            return
        }
        XCTAssertTrue(detail.contains("base64"), "原因应指明 base64：\(detail)")
    }

    func testSetup_wrongLengthPublicKey_misconfigured() {
        // base64 合法但长度不是 32 字节（Ed25519 rawRepresentation）→ RemoteStagingProvider
        // init 抛 invalidConfiguration → misconfigured（不静默、不降级）
        let shortKey = Data(repeating: 0x01, count: 31).base64EncodedString()
        let config = RemoteStagingSyncConfig(
            enabled: true,
            baseURL: "https://v.example.com/staging",
            collectorKey: nil,
            signaturePublicKeyBase64: shortKey
        )
        guard case .misconfigured = RemoteStagingSyncSetup.make(config: config) else {
            XCTFail("31 字节公钥应为 misconfigured")
            return
        }
    }

    func testSetup_validPublicKey_ready() throws {
        // 真实 Ed25519 公钥 32 字节（内容任意合法即可——Setup 不做信任判断）
        let key = Data(repeating: 0x02, count: 32).base64EncodedString()
        let config = RemoteStagingSyncConfig(
            enabled: true,
            baseURL: "https://v.example.com/staging",
            collectorKey: "k-1",
            signaturePublicKeyBase64: key
        )
        guard case .ready = RemoteStagingSyncSetup.make(config: config) else {
            XCTFail("合法配置应为 ready")
            return
        }
    }

    // MARK: - 端到端 wiring：config → provider → sync（离线 FakeFetcher）

    func testWiring_readyProviderSyncsIntoProductionPaths() async throws {
        let dataDir = tempDir.appendingPathComponent("appdata", isDirectory: true)
        let spoolURL = RemoteStagingSyncPaths.spoolURL(in: dataDir)
        let stateURL = RemoteStagingSyncPaths.stateURL(in: dataDir)

        // 服务端一轮快照：1 个 dataset 文件，2 条合法 DailyBar 记录
        let records = [Self.makeRecord(symbol: "600519"), Self.makeRecord(symbol: "000001")]
        let fileData = Self.jsonl(records)
        let fetcher = WiringFakeFetcher(
            manifest: Self.manifest(files: [
                Self.fileEntry(name: "stock_daily.jsonl", data: fileData)
            ]),
            files: ["stock_daily.jsonl": fileData]
        )
        let config = RemoteStagingSyncConfig(
            enabled: true,
            baseURL: "https://collector.example.com/staging",
            collectorKey: nil,
            signaturePublicKeyBase64: nil
        )
        guard case .ready(let provider) = RemoteStagingSyncSetup.make(
            config: config, fetcher: fetcher, now: { Date(timeIntervalSince1970: 1_780_000_000) }
        ) else {
            XCTFail("合法配置应为 ready")
            return
        }

        // 生产循环的第一步：建目录（AppModel.runRemoteStagingSyncLoop 同款）
        try FileManager.default.createDirectory(
            at: spoolURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let outcome = await provider.sync(to: spoolURL, state: stateURL)

        guard case .synced(let summary) = outcome else {
            XCTFail("端到端 wiring 应成功，实际 \(outcome)")
            return
        }
        XCTAssertEqual(summary.filesDownloaded, 1)
        XCTAssertEqual(summary.recordsAppended, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: spoolURL.path), "记录应落生产 spool 路径")
        let readBack = try ProviderStagingReader().read(from: spoolURL)
        XCTAssertEqual(readBack.count, 2)

        // 第二轮（同内容）应走增量跳过，不重复追加
        let second = await provider.sync(to: spoolURL, state: stateURL)
        guard case .synced(let secondSummary) = second else {
            XCTFail("第二轮应成功，实际 \(second)")
            return
        }
        XCTAssertEqual(secondSummary.filesDownloaded, 0)
        XCTAssertEqual(secondSummary.filesUnchanged, 1)
        XCTAssertEqual(try ProviderStagingReader().read(from: spoolURL).count, 2, "增量轮不得重复追加")
    }

    // MARK: - Fixtures（与 RemoteStagingProviderTests 同构的最小内联实现）

    private static func makeRecord(symbol: String) -> ProviderRecord {
        let payload = DailyBarPayload(
            rawOpen: Price(value: Decimal(string: "10.0")!, currency: .cny),
            rawHigh: Price(value: Decimal(string: "10.5")!, currency: .cny),
            rawLow: Price(value: Decimal(string: "9.9")!, currency: .cny),
            rawClose: Price(value: Decimal(string: "10.2")!, currency: .cny),
            volume: 1_000,
            adjustmentFactor: 1.0,
            fxRate: nil
        )
        let day = Date(timeIntervalSince1970: 1_780_000_000)
        return ProviderRecord(
            providerID: .akshare,
            providerCode: ProviderCode(scheme: "stock_symbol", value: symbol),
            effectiveAt: day,
            publishedAt: day,
            ingestedAt: day,
            kind: .dailyBar,
            rawPayload: try! JSONEncoder().encode(payload),
            reliabilityClass: .communityAggregated,
            jurisdiction: .chinaMainland
        )
    }

    private static func jsonl(_ records: [ProviderRecord]) -> Data {
        let encoder = ProviderStaging.defaultEncoder
        let lines = records.map { try! encoder.encode($0) }
        return Data(lines.flatMap { Array($0) + [0x0A] })
    }

    private static func manifest(files: [RemoteStagingManifest.File]) -> Data {
        let manifest = RemoteStagingManifest(
            version: 1,
            collectorVersion: "1.0.0",
            generatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            files: files
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try! encoder.encode(manifest)
    }

    private static func fileEntry(name: String, data: Data) -> RemoteStagingManifest.File {
        RemoteStagingManifest.File(
            name: name,
            sha256: RemoteStagingProvider.sha256Hex(data),
            byteSize: data.count
        )
    }

    /// 最小 fetcher 桩：单快照、manifest + 文件、无签名。
    private final class WiringFakeFetcher: RemoteStagingFetcher, @unchecked Sendable {
        private let manifestData: Data
        private let files: [String: Data]

        init(manifest: Data, files: [String: Data] = [:]) {
            self.manifestData = manifest
            self.files = files
        }

        func fetchCurrentSnapshotID() async throws -> String { "20260821T000000Z" }

        func fetchManifest(snapshotID: String) async throws -> Data { manifestData }

        func fetchManifestSignature(snapshotID: String) async throws -> Data {
            throw RemoteStagingError.unavailable(detail: "unsigned deployment")
        }

        func fetchFile(_ name: String, snapshotID: String) async throws -> Data {
            guard let data = files[name] else {
                throw RemoteStagingError.unavailable(detail: "no fixture \(name)")
            }
            return data
        }
    }
}
