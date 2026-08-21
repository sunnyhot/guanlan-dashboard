import XCTest
import CryptoKit
@testable import QiemanDashboard

/// PROV-3b 客户端侧单元测试：RemoteStagingProvider（ADR-DATA010）。
///
/// 全离线（FakeRemoteFetcher 注入内存 manifest/文件/签名）。覆盖 DATA010
/// Compliance Check：增量下载（同 hash 跳过）、sha256 篡改拒收、Ed25519 验签
/// （合法过 / 篡改拒）、403/429 降级语义、断路器指数退避 + 退避期 .skipped、
/// SchemaValidator 兜底（结构非法记录不进 spool）、state 持久化。
final class RemoteStagingProviderTests: XCTestCase {

    private var now = Date(timeIntervalSince1970: 1_724_000_000)

    private var tempDir: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-staging-\(UUID().uuidString)")
    }

    private func makeRecord(symbol: String = "600519") -> ProviderRecord {
        let payload = DailyBarPayload(
            rawOpen: Price(value: Decimal(string: "10.0")!, currency: .cny),
            rawHigh: Price(value: Decimal(string: "10.5")!, currency: .cny),
            rawLow: Price(value: Decimal(string: "9.9")!, currency: .cny),
            rawClose: Price(value: Decimal(string: "10.2")!, currency: .cny),
            volume: 1_000,
            adjustmentFactor: 1.0,
            fxRate: nil
        )
        let day = Date(timeIntervalSince1970: 1_720_000_000)
        return ProviderRecord(
            providerID: .akshare,
            providerCode: ProviderCode(scheme: "stock_symbol", value: symbol),
            effectiveAt: day,
            publishedAt: day,
            ingestedAt: day,
            kind: .dailyBar,
            rawPayload: (try! JSONEncoder().encode(payload)),
            reliabilityClass: .communityAggregated,
            jurisdiction: .chinaMainland
        )
    }

    /// 编码 staging JSONL（与 ProviderStaging.defaultEncoder 对齐：iso8601）。
    private func jsonl(_ records: [ProviderRecord]) -> Data {
        let encoder = ProviderStaging.defaultEncoder
        let lines = records.map { try! encoder.encode($0) }
        return Data(lines.flatMap { Array($0) + [0x0A] })
    }

    private func manifest(
        files: [RemoteStagingManifest.File],
        generatedAt: Date? = nil,
        version: Int = 1
    ) -> Data {
        let manifest = RemoteStagingManifest(
            version: version,
            collectorVersion: "1.0.0",
            generatedAt: generatedAt ?? now,
            files: files
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try! encoder.encode(manifest)
    }

    private func fileEntry(
        name: String, data: Data
    ) -> RemoteStagingManifest.File {
        RemoteStagingManifest.File(
            name: name,
            sha256: RemoteStagingProvider.sha256Hex(data),
            byteSize: data.count
        )
    }

    /// 测试 fetcher：多快照内存存储 + 可注入错误。
    ///
    /// manifest / 签名 / 文件按快照隔离存储，`fetchCurrentSnapshotID` 返回
    /// `currentSnapshotID`——`onFetchSnapshotID` 钩子可模拟「客户端取到 ID 后、
    /// 读内容前发生发布」（切指针），用于验证快照固定读取的批次一致性。
    /// 顶层便捷属性（manifestData / manifestSignature / files）读写 current 快照，
    /// 保持既有用例的构造姿势不变。
    private final class FakeRemoteFetcher: RemoteStagingFetcher, @unchecked Sendable {
        struct Snapshot {
            var manifestData: Data
            var manifestSignature: Data?
            var files: [String: Data] = [:]
        }

        var snapshots: [String: Snapshot]
        var currentSnapshotID: String
        var manifestError: Error?
        var fileErrors: [String: Error] = [:]
        /// 拉取文件时的副作用（模拟「append 前一刻持久层故障」——loadState 已过、
        /// checkpoint 将失败的时间窗）
        var onFetchFile: (@Sendable (String) -> Void)?
        /// fetchCurrentSnapshotID 返回前触发（模拟读取期间发生发布）
        var onFetchSnapshotID: (@Sendable () -> Void)?

        /// fetchFile 调用计数（锁保护——@Sendable 钩子里不能改捕获变量，
        /// Swift 6 严格并发下报 mutation of captured var；断言用本计数器）
        private let countLock = NSLock()
        private var _fileFetchCount = 0
        var fileFetchCount: Int {
            countLock.lock(); defer { countLock.unlock() }
            return _fileFetchCount
        }

        init(manifestData: Data, currentSnapshotID: String = "snap-1") {
            self.currentSnapshotID = currentSnapshotID
            self.snapshots = [currentSnapshotID: Snapshot(manifestData: manifestData)]
        }

        /// 便捷读写：current 快照的 manifest（既有用例构造姿势）
        var manifestData: Data {
            get { snapshots[currentSnapshotID]?.manifestData ?? Data() }
            set { snapshots[currentSnapshotID, default: Snapshot(manifestData: Data())].manifestData = newValue }
        }

        var manifestSignature: Data? {
            get { snapshots[currentSnapshotID]?.manifestSignature }
            set { snapshots[currentSnapshotID, default: Snapshot(manifestData: Data())].manifestSignature = newValue }
        }

        var files: [String: Data] {
            get { snapshots[currentSnapshotID]?.files ?? [:] }
            set { snapshots[currentSnapshotID, default: Snapshot(manifestData: Data())].files = newValue }
        }

        func fetchCurrentSnapshotID() async throws -> String {
            if let manifestError { throw manifestError }
            let id = currentSnapshotID
            onFetchSnapshotID?()
            return id
        }

        func fetchManifest(snapshotID: String) async throws -> Data {
            guard let snapshot = snapshots[snapshotID] else {
                throw RemoteStagingError.unavailable(detail: "no snapshot \(snapshotID)")
            }
            return snapshot.manifestData
        }

        func fetchManifestSignature(snapshotID: String) async throws -> Data {
            guard let signature = snapshots[snapshotID]?.manifestSignature else {
                throw RemoteStagingError.unavailable(detail: "no signature")
            }
            return signature
        }

        func fetchFile(_ name: String, snapshotID: String) async throws -> Data {
            countLock.lock()
            _fileFetchCount += 1
            countLock.unlock()
            onFetchFile?(name)
            if let error = fileErrors[name] { throw error }
            guard let data = snapshots[snapshotID]?.files[name] else {
                throw RemoteStagingError.unavailable(detail: "no fixture for \(name)")
            }
            return data
        }
    }

    /// 写一份合法的空 state（让 sync 轮首的 loadState 可读）。
    private func writeEmptyState(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(RemoteStagingLocalState()).write(to: url)
    }

    /// 把 state 路径替换为目录：占位使后续 checkpoint 的原子写必然失败。
    private func blockStateWrites(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func makeProvider(
        fetcher: FakeRemoteFetcher,
        publicKey: Data? = nil,
        backoff: TimeInterval = 60
    ) -> RemoteStagingProvider {
        // 测试内输入均合法（nil / 有效公钥字节）；非法公钥行为单独测
        try! RemoteStagingProvider(
            fetcher: fetcher,
            signaturePublicKey: publicKey,
            breakerConfig: .init(baseBackoff: backoff, maxBackoff: backoff * 8),
            now: { [weak self] in self?.now ?? .distantPast }
        )
    }

    // MARK: - happy path

    func testSync_happyPath_appendsValidRecordsAndPersistsState() async throws {
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = dir.appendingPathComponent("spool.jsonl")
        let stateURL = dir.appendingPathComponent("state.json")

        let records = [makeRecord(), makeRecord(symbol: "000001")]
        let fileData = jsonl(records)
        let fetcher = FakeRemoteFetcher(
            manifestData: manifest(files: [fileEntry(name: "stock_daily.jsonl", data: fileData)])
        )
        fetcher.files["stock_daily.jsonl"] = fileData

        let provider = makeProvider(fetcher: fetcher)
        let outcome = await provider.sync(to: spool, state: stateURL)

        guard case .synced(let summary) = outcome else {
            return XCTFail("expected synced, got \(outcome)")
        }
        XCTAssertEqual(summary.filesDownloaded, 1)
        XCTAssertEqual(summary.recordsAppended, 2)
        XCTAssertEqual(summary.recordsRejectedInvalidSchema, 0)
        XCTAssertEqual(summary.filesRejectedTampered, 0)

        // spool 内容 = 追加的合法记录（PROV-1 Reader round-trip）
        let reread = try ProviderStagingReader().read(from: spool)
        XCTAssertEqual(reread.count, 2)
        XCTAssertEqual(reread.map(\.providerCode.value).sorted(), ["000001", "600519"])

        // state 持久化（增量依据）
        let stateData = try Data(contentsOf: stateURL)
        let stateDecoder = JSONDecoder()
        stateDecoder.dateDecodingStrategy = .iso8601
        let state = try stateDecoder.decode(RemoteStagingLocalState.self, from: stateData)
        XCTAssertEqual(state.fileHashes["stock_daily.jsonl"], RemoteStagingProvider.sha256Hex(fileData))
        XCTAssertNotNil(state.lastSyncedAt)
    }

    // MARK: - wire 契约闸门（审查 P1）

    func testSync_publishDuringSession_readsPinnedSnapshotConsistently() async throws {
        // 取到快照 ID 之后、读 manifest 之前发生发布（指针切换到新快照）——
        // 本轮仍完整读取旧快照（manifest + 签名 + 文件同源），不误判篡改。
        // 两个快照用不同 Ed25519 密钥签名：若混读必然验签失败（旧行为），
        // 固定路径读取则成功——这是本回归的判定器
        let oldKey = Curve25519.Signing.PrivateKey()
        let newKey = Curve25519.Signing.PrivateKey()

        let oldFile = jsonl([makeRecord()])
        let oldManifest = manifest(files: [fileEntry(name: "stock_daily.jsonl", data: oldFile)])
        let newFile = jsonl([makeRecord(symbol: "000001"), makeRecord(symbol: "600036")])
        let newManifest = manifest(
            files: [fileEntry(name: "stock_daily.jsonl", data: newFile)],
            generatedAt: now.addingTimeInterval(3_600)
        )

        let fetcher = FakeRemoteFetcher(manifestData: oldManifest, currentSnapshotID: "20260821T000000Z")
        fetcher.snapshots["20260821T000000Z"]?.manifestSignature = try oldKey.signature(for: oldManifest)
        fetcher.snapshots["20260821T000000Z"]?.files = ["stock_daily.jsonl": oldFile]
        fetcher.snapshots["20260821T010000Z"] = FakeRemoteFetcher.Snapshot(
            manifestData: newManifest,
            manifestSignature: try newKey.signature(for: newManifest),
            files: ["stock_daily.jsonl": newFile]
        )
        // 客户端拿到旧 ID 的瞬间服务端切指针——后续内容读取必须仍走旧快照
        fetcher.onFetchSnapshotID = { fetcher.currentSnapshotID = "20260821T010000Z" }

        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = try makeProvider(fetcher: fetcher, publicKey: oldKey.publicKey.rawRepresentation)
        let outcome = await provider.sync(
            to: dir.appendingPathComponent("spool.jsonl"),
            state: dir.appendingPathComponent("state.json")
        )

        guard case .synced(let summary) = outcome else {
            return XCTFail("中途发布不应破坏批次一致性, got \(outcome)")
        }
        XCTAssertEqual(summary.recordsAppended, 1, "读取的是旧快照的 1 条记录")
        let spool = try ProviderStagingReader().read(from: dir.appendingPathComponent("spool.jsonl"))
        XCTAssertEqual(spool.map(\.providerCode.value), ["600519"], "spool 内容来自旧快照")
    }

    func testSync_unsupportedManifestVersion_rejectedFailClosed() async throws {
        // 服务端 bump version=2 时客户端显式拒绝，不静默按 v1 语义解读
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let records = [makeRecord()]
        let fileData = jsonl(records)
        let fetcher = FakeRemoteFetcher(
            manifestData: manifest(files: [fileEntry(name: "stock_daily.jsonl", data: fileData)], version: 2)
        )
        fetcher.files["stock_daily.jsonl"] = fileData

        let provider = makeProvider(fetcher: fetcher)
        let outcome = await provider.sync(
            to: dir.appendingPathComponent("spool.jsonl"),
            state: dir.appendingPathComponent("state.json")
        )
        guard case .failed(.malformedManifest(let detail)) = outcome else {
            return XCTFail("expected .failed(.malformedManifest), got \(outcome)")
        }
        XCTAssertTrue(detail.contains("unsupported manifest version 2"), "detail: \(detail)")
        // 版本闸门在下载/落库之前——spool 不应有任何字节
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("spool.jsonl").path))
    }

    func testSync_farFutureGeneratedAt_rejectedByIndependentClientClock() async throws {
        // 服务端未来上界对「collector 与 publisher 共用 VPS 时钟一起漂移」失效
        //（同机差值≈0）——客户端必须用独立 now() 复核，下载任何文件前 fail-closed
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let records = [makeRecord()]
        let fileData = jsonl(records)
        let fetcher = FakeRemoteFetcher(
            // generatedAt = 客户端本地 now + 1h（超过 10min 容忍度）
            manifestData: manifest(
                files: [fileEntry(name: "stock_daily.jsonl", data: fileData)],
                generatedAt: now.addingTimeInterval(3_600)
            )
        )
        fetcher.files["stock_daily.jsonl"] = fileData

        let provider = makeProvider(fetcher: fetcher)
        let outcome = await provider.sync(
            to: dir.appendingPathComponent("spool.jsonl"),
            state: dir.appendingPathComponent("state.json")
        )
        guard case .failed(.malformedManifest(let detail)) = outcome else {
            return XCTFail("expected .failed(.malformedManifest), got \(outcome)")
        }
        XCTAssertTrue(detail.contains("far future"), "detail: \(detail)")
        XCTAssertEqual(fetcher.fileFetchCount, 0, "闸门必须在下载任何文件之前")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("spool.jsonl").path))
    }

    func testSync_nearFutureGeneratedAt_withinTolerancePasses() async throws {
        // 时钟小幅超前（容忍度内）正常放行
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let records = [makeRecord()]
        let fileData = jsonl(records)
        let fetcher = FakeRemoteFetcher(
            manifestData: manifest(
                files: [fileEntry(name: "stock_daily.jsonl", data: fileData)],
                generatedAt: now.addingTimeInterval(5 * 60)   // +5min < 10min
            )
        )
        fetcher.files["stock_daily.jsonl"] = fileData

        let provider = makeProvider(fetcher: fetcher)
        let outcome = await provider.sync(
            to: dir.appendingPathComponent("spool.jsonl"),
            state: dir.appendingPathComponent("state.json")
        )
        guard case .synced(let summary) = outcome else {
            return XCTFail("容忍度内应正常 sync: \(outcome)")
        }
        XCTAssertEqual(summary.recordsAppended, 1)
    }

    func testURLSessionFetcher_bypassesURLCache_andSendsCollectorKey() async throws {
        // nginx 静态文件带 Last-Modified 无 Cache-Control 时，URLCache 启发式缓存
        // 会让 manifest 变陈旧——生产 fetcher 必须显式绕过本地缓存
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RequestRecorderProtocol.self]
        let session = URLSession(configuration: config)
        RequestRecorderProtocol.stubData = manifest(files: [])
        defer { RequestRecorderProtocol.reset() }

        let fetcher = URLSessionRemoteStagingFetcher(
            baseURL: URL(string: "https://collector.example.com/staging/")!,
            collectorKey: "test-collector-key",
            session: session
        )
        // 先固定快照 ID，再取 manifest（与 sync 流程同款顺序）
        let snapshotID = try await fetcher.fetchCurrentSnapshotID()
        XCTAssertTrue(URLSessionRemoteStagingFetcher.isValidSnapshotID(snapshotID))
        let data = try await fetcher.fetchManifest(snapshotID: snapshotID)
        XCTAssertFalse(data.isEmpty)

        let request = try XCTUnwrap(RequestRecorderProtocol.lastRequest, "URLProtocol 应捕获到请求")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData,
                       "manifest/文件请求必须绕过 URLCache 启发式缓存")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Collector-Key"), "test-collector-key")
    }

    // MARK: - 增量：同 hash 跳过

    func testSync_incremental_skipsUnchangedFiles() async throws {
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = dir.appendingPathComponent("spool.jsonl")
        let stateURL = dir.appendingPathComponent("state.json")

        let fileData = jsonl([makeRecord()])
        let fetcher = FakeRemoteFetcher(
            manifestData: manifest(files: [fileEntry(name: "a.jsonl", data: fileData)])
        )
        fetcher.files["a.jsonl"] = fileData
        let provider = makeProvider(fetcher: fetcher)

        // 第一轮：下载
        _ = await provider.sync(to: spool, state: stateURL)
        // 第二轮：同 hash → skipped download，spool 不再增长
        let outcome = await provider.sync(to: spool, state: stateURL)
        guard case .synced(let summary) = outcome else {
            return XCTFail("expected synced, got \(outcome)")
        }
        XCTAssertEqual(summary.filesUnchanged, 1)
        XCTAssertEqual(summary.filesDownloaded, 0)
        XCTAssertEqual(summary.recordsAppended, 0)
        let reread = try ProviderStagingReader().read(from: spool)
        XCTAssertEqual(reread.count, 1)   // 无重复追加
    }

    // MARK: - 完整性：sha256 篡改拒收

    func testSync_tamperedFile_rejectedNotAppended() async throws {
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = dir.appendingPathComponent("spool.jsonl")
        let stateURL = dir.appendingPathComponent("state.json")

        let goodData = jsonl([makeRecord()])
        // manifest 声明的 hash 对应 goodData，但传输内容被替换（传输篡改场景）
        let tamperedData = jsonl([makeRecord(symbol: "EVIL")])
        let fetcher = FakeRemoteFetcher(
            manifestData: manifest(files: [
                fileEntry(name: "good.jsonl", data: goodData),
                fileEntry(name: "clean.jsonl", data: goodData)
            ])
        )
        fetcher.files["good.jsonl"] = tamperedData   // 篡改
        fetcher.files["clean.jsonl"] = goodData      // 正常

        let provider = makeProvider(fetcher: fetcher)
        let outcome = await provider.sync(to: spool, state: stateURL)
        guard case .synced(let summary) = outcome else {
            return XCTFail("expected synced, got \(outcome)")
        }
        XCTAssertEqual(summary.filesRejectedTampered, 1)
        XCTAssertEqual(summary.filesDownloaded, 1)
        // 篡改内容未进 spool
        let reread = try ProviderStagingReader().read(from: spool)
        XCTAssertEqual(reread.count, 1)
        XCTAssertFalse(reread.contains { $0.providerCode.value == "EVIL" })
        // 篡改文件不写 state（下轮重下）
        let stateData = try Data(contentsOf: stateURL)
        XCTAssertTrue(String(data: stateData, encoding: .utf8)!.contains("clean.jsonl"))
        XCTAssertFalse(String(data: stateData, encoding: .utf8)!.contains("good.jsonl"))
    }

    // MARK: - SchemaValidator 兜底

    func testSync_invalidSchemaRecords_excludedFromSpool() async throws {
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = dir.appendingPathComponent("spool.jsonl")
        let stateURL = dir.appendingPathComponent("state.json")

        // 1 条合法 + 1 条 schema 非法（kind=dailyBar 但 payload 是 NAV）
        var badRecord = makeRecord()
        badRecord = ProviderRecord(
            providerID: badRecord.providerID,
            providerCode: badRecord.providerCode,
            effectiveAt: badRecord.effectiveAt,
            publishedAt: badRecord.publishedAt,
            ingestedAt: badRecord.ingestedAt,
            kind: .dailyBar,
            rawPayload: (try! JSONEncoder().encode(NAVPayload(
                unitNAV: Price(value: 1, currency: .cny),
                accumulatedNAV: nil, cumulativeDividendPerShare: nil
            ))),
            reliabilityClass: badRecord.reliabilityClass,
            jurisdiction: badRecord.jurisdiction
        )
        let fileData = jsonl([makeRecord(), badRecord])
        let fetcher = FakeRemoteFetcher(
            manifestData: manifest(files: [fileEntry(name: "mixed.jsonl", data: fileData)])
        )
        fetcher.files["mixed.jsonl"] = fileData

        let provider = makeProvider(fetcher: fetcher)
        let outcome = await provider.sync(to: spool, state: stateURL)
        guard case .synced(let summary) = outcome else {
            return XCTFail("expected synced, got \(outcome)")
        }
        XCTAssertEqual(summary.recordsAppended, 1)
        XCTAssertEqual(summary.recordsRejectedInvalidSchema, 1)
        XCTAssertEqual(try ProviderStagingReader().read(from: spool).count, 1)
    }

    // MARK: - Ed25519 验签

    func testSync_validSignature_passes() async throws {
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = dir.appendingPathComponent("spool.jsonl")
        let stateURL = dir.appendingPathComponent("state.json")

        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        let fileData = jsonl([makeRecord()])
        let manifestData = manifest(files: [fileEntry(name: "a.jsonl", data: fileData)])
        let signature = try privateKey.signature(for: manifestData)

        let fetcher = FakeRemoteFetcher(manifestData: manifestData)
        fetcher.files["a.jsonl"] = fileData
        fetcher.manifestSignature = signature

        let provider = makeProvider(fetcher: fetcher, publicKey: publicKey.rawRepresentation)
        let outcome = await provider.sync(to: spool, state: stateURL)
        guard case .synced(let summary) = outcome else {
            return XCTFail("expected synced, got \(outcome)")
        }
        XCTAssertEqual(summary.recordsAppended, 1)
    }

    func testSync_forgedSignature_failsWholeBatch() async throws {
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = dir.appendingPathComponent("spool.jsonl")
        let stateURL = dir.appendingPathComponent("state.json")

        // 用另一对密钥签名（伪造）
        let signer = Curve25519.Signing.PrivateKey()
        let verifier = Curve25519.Signing.PrivateKey()
        let fileData = jsonl([makeRecord()])
        let manifestData = manifest(files: [fileEntry(name: "a.jsonl", data: fileData)])
        let forged = try signer.signature(for: manifestData)

        let fetcher = FakeRemoteFetcher(manifestData: manifestData)
        fetcher.files["a.jsonl"] = fileData
        fetcher.manifestSignature = forged

        let provider = makeProvider(
            fetcher: fetcher, publicKey: verifier.publicKey.rawRepresentation
        )
        let outcome = await provider.sync(to: spool, state: stateURL)
        guard case .failed(let error) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertEqual(error, .signatureVerificationFailed)
        // 拒收整批：spool 无内容，state 未写
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    }

    // MARK: - 配置安全（审查 P1：非法公钥不得静默降级为未验签）

    func testInit_invalidPublicKey_throws() {
        let fetcher = FakeRemoteFetcher(manifestData: Data("{}".utf8))
        XCTAssertThrowsError(
            try RemoteStagingProvider(fetcher: fetcher, signaturePublicKey: Data([1, 2, 3]))
        ) { error in
            guard case RemoteStagingError.invalidConfiguration = error else {
                return XCTFail("expected invalidConfiguration, got \(error)")
            }
        }
    }

    // MARK: - state 写入失败不虚报成功（审查 P1）

    func testSync_stateWriteFailure_reportsFailed() async throws {
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = dir.appendingPathComponent("spool.jsonl")
        let stateURL = dir.appendingPathComponent("state.json")
        try writeEmptyState(to: stateURL)

        let fileData = jsonl([makeRecord()])
        let fetcher = FakeRemoteFetcher(
            manifestData: manifest(files: [fileEntry(name: "a.jsonl", data: fileData)])
        )
        fetcher.files["a.jsonl"] = fileData
        // fetchFile 时才把 state 路径占位成目录：loadState 已读成功、append 已
        // 预备，checkpoint 原子写此刻必然失败（模拟 append 后、checkpoint 前故障）
        fetcher.onFetchFile = { [blockStateWrites] _ in blockStateWrites(stateURL) }

        let provider = makeProvider(fetcher: fetcher)
        let outcome = await provider.sync(to: spool, state: stateURL)
        guard case .failed = outcome else {
            return XCTFail("state 写失败必须报 .failed，不得虚报 .synced，got \(outcome)")
        }
        // 记录已进 spool 但 state 未提交——journal 保留供下轮恢复
        XCTAssertEqual(try ProviderStagingReader().read(from: spool).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: stateURL.appendingPathExtension("journal").path
        ))
    }

    func testSync_checkpointFailureThenRetry_spoolHasSingleCopy() async throws {
        // 审查 P1 场景：第一次 checkpoint 失败（记录已 append、journal 保留），
        // 第二次重试经 journal 恢复把 spool 截断回偏移再重新追加——最终只有一份。
        // journal/state 路径跨重启不变（生产形态）。
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = dir.appendingPathComponent("spool.jsonl")
        let stateURL = dir.appendingPathComponent("state.json")
        try writeEmptyState(to: stateURL)

        let fileData = jsonl([makeRecord()])
        let fetcher = FakeRemoteFetcher(
            manifestData: manifest(files: [fileEntry(name: "a.jsonl", data: fileData)])
        )
        fetcher.files["a.jsonl"] = fileData
        // 仅首轮：fetchFile 时占位 state 路径 → append 后 checkpoint 失败
        fetcher.onFetchFile = { [blockStateWrites] _ in blockStateWrites(stateURL) }

        let provider = makeProvider(fetcher: fetcher, backoff: 1)
        guard case .failed = await provider.sync(to: spool, state: stateURL) else {
            return XCTFail("第一次（state 写失败）应报 .failed")
        }
        XCTAssertEqual(try ProviderStagingReader().read(from: spool).count, 1)
        let journalURL = stateURL.appendingPathExtension("journal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))

        // 故障排除（占位目录让位、副作用解除）+ 越过 1s 退避后重试：
        // journal 恢复 → 截断 → 重新追加 → checkpoint 成功
        fetcher.onFetchFile = nil
        try FileManager.default.removeItem(at: stateURL)
        now = now.addingTimeInterval(2)
        let outcome = await provider.sync(to: spool, state: stateURL)
        guard case .synced(let summary) = outcome else {
            return XCTFail("第二次重试应成功，got \(outcome)")
        }
        XCTAssertEqual(summary.recordsAppended, 1)
        // 关键断言：spool 仍只有一份，没有重复追加
        XCTAssertEqual(try ProviderStagingReader().read(from: spool).count, 1)
        // journal 已清
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testSync_crashAfterAppendWithoutCheckpoint_recoversViaJournal() async throws {
        // 模拟「append 成功、checkpoint 前崩溃」：手工构造 journal + spool 尾部
        // 未提交内容，下一次 sync 先截断再处理，spool 不重复
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = dir.appendingPathComponent("spool.jsonl")
        let stateURL = dir.appendingPathComponent("state.json")

        let fileData = jsonl([makeRecord()])
        // 崩溃现场：spool 里已有一次未提交的 append（2 条），journal 记录偏移 0
        try ProviderStagingWriter().write([makeRecord(), makeRecord(symbol: "000001")], to: spool)
        let journalURL = stateURL.appendingPathExtension("journal")
        let journalEncoder = JSONEncoder()
        try journalEncoder.encode(
            RemoteStagingJournal(fileName: "a.jsonl", fileSha256: "deadbeef", spoolOffsetBefore: 0)
        ).write(to: journalURL)

        let fetcher = FakeRemoteFetcher(
            manifestData: manifest(files: [fileEntry(name: "a.jsonl", data: fileData)])
        )
        fetcher.files["a.jsonl"] = fileData

        let provider = makeProvider(fetcher: fetcher)
        let outcome = await provider.sync(to: spool, state: stateURL)
        guard case .synced(let summary) = outcome else {
            return XCTFail("expected synced, got \(outcome)")
        }
        XCTAssertEqual(summary.recordsAppended, 1)
        // 截断恢复了未提交的 2 条 + 重新追加 1 条 = spool 只有 1 份
        XCTAssertEqual(try ProviderStagingReader().read(from: spool).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testSync_immediateRetryDuringBackoff_stillRecoversJournal() async throws {
        // 审查 P1：checkpoint 失败立即打开断路器；不推进时钟马上重试虽返回
        // .skipped（不触网络），但本地 journal 恢复必须已执行——spool 尾巴已
        // 截断、journal 已清，本地状态一致。恢复不得被断路器拦在后面。
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = dir.appendingPathComponent("spool.jsonl")
        let stateURL = dir.appendingPathComponent("state.json")
        try writeEmptyState(to: stateURL)

        let fileData = jsonl([makeRecord()])
        let fetcher = FakeRemoteFetcher(
            manifestData: manifest(files: [fileEntry(name: "a.jsonl", data: fileData)])
        )
        fetcher.files["a.jsonl"] = fileData
        fetcher.onFetchFile = { [blockStateWrites] _ in blockStateWrites(stateURL) }

        let provider = makeProvider(fetcher: fetcher, backoff: 60)
        guard case .failed = await provider.sync(to: spool, state: stateURL) else {
            return XCTFail("第一次（state 写失败）应报 .failed")
        }
        XCTAssertEqual(try ProviderStagingReader().read(from: spool).count, 1)
        let journalURL = stateURL.appendingPathExtension("journal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))

        // 不推进时钟立即重试：断路器打开 → .skipped，但恢复已跑
        // （注意：恢复里的 state 判断遇到「占位目录」会失败——这正是读取容错
        // 要求的终止语义，因此重试前先把故障排除，保持本测试聚焦断路器次序）
        fetcher.onFetchFile = nil
        try FileManager.default.removeItem(at: stateURL)
        guard case .skipped = await provider.sync(to: spool, state: stateURL) else {
            return XCTFail("退避期内应 .skipped")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertTrue(try ProviderStagingReader().read(from: spool).isEmpty)

        // 越过退避后：正常同步成功，spool 仍只有一份
        now = now.addingTimeInterval(61)
        guard case .synced(let summary) = await provider.sync(to: spool, state: stateURL) else {
            return XCTFail("退避过后应 synced")
        }
        XCTAssertEqual(summary.recordsAppended, 1)
        XCTAssertEqual(try ProviderStagingReader().read(from: spool).count, 1)
    }

    func testSync_journalOffsetBeyondSpoolSize_refusesAndKeepsSpool() async throws {
        // 审查 P1：spool 被外部缩短/替换（journal 偏移 > 当前 spool 大小）时，
        // 恢复必须拒绝执行（按偏移截断会破坏数据），spool 原样保留并报 .failed
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = dir.appendingPathComponent("spool.jsonl")
        let stateURL = dir.appendingPathComponent("state.json")

        // 已提交的 2 条历史 + 一个偏移越界的残留 journal
        try ProviderStagingWriter().write([makeRecord(), makeRecord(symbol: "000001")], to: spool)
        let journalURL = stateURL.appendingPathExtension("journal")
        try JSONEncoder().encode(
            RemoteStagingJournal(fileName: "a.jsonl", fileSha256: "deadbeef", spoolOffsetBefore: 999_999)
        ).write(to: journalURL)

        let fetcher = FakeRemoteFetcher(manifestData: Data("{}".utf8))
        let provider = makeProvider(fetcher: fetcher)
        let outcome = await provider.sync(to: spool, state: stateURL)
        guard case .failed = outcome else {
            return XCTFail("偏移越界应报 .failed，got \(outcome)")
        }
        // spool 原样保留（拒绝截断），journal 未清（现场保留待人工排查）
        XCTAssertEqual(try ProviderStagingReader().read(from: spool).count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testSync_corruptStateWithPendingJournal_neverTruncatesCommittedSpool() async throws {
        // 审查 P1 场景：checkpoint 已成功、journal 未清、state 此刻读不出/解不了
        // ——恢复必须终止本轮并保留现场，绝不能把坏 state 当空 state 误判「未提交」
        // 而截断已提交的 spool（静默数据丢失）
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = dir.appendingPathComponent("spool.jsonl")
        let stateURL = dir.appendingPathComponent("state.json")

        // 已提交的 spool（1 条）+ 残留 journal（指向同文件，offset 0）+ 损坏的 state
        try ProviderStagingWriter().write([makeRecord()], to: spool)
        let journalURL = stateURL.appendingPathExtension("journal")
        try JSONEncoder().encode(
            RemoteStagingJournal(fileName: "a.jsonl", fileSha256: "deadbeef", spoolOffsetBefore: 0)
        ).write(to: journalURL)
        try Data("not-json".utf8).write(to: stateURL)

        let fetcher = FakeRemoteFetcher(manifestData: Data("{}".utf8))
        let provider = makeProvider(fetcher: fetcher)
        let outcome = await provider.sync(to: spool, state: stateURL)
        guard case .failed = outcome else {
            return XCTFail("坏 state + 残留 journal 必须报 .failed，got \(outcome)")
        }
        // 现场原样保留：spool 未被截断、journal 未被清
        XCTAssertEqual(try ProviderStagingReader().read(from: spool).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testSync_corruptStateWithoutJournal_failsInsteadOfRestartingIncremental() async throws {
        // 审查 P1：无 journal 但 state 损坏时，也不能当空 state 继续——增基线错误
        // 会导致已同步文件被重新下载再次追加
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = dir.appendingPathComponent("spool.jsonl")
        let stateURL = dir.appendingPathComponent("state.json")
        try Data("not-json".utf8).write(to: stateURL)

        let fileData = jsonl([makeRecord()])
        let fetcher = FakeRemoteFetcher(
            manifestData: manifest(files: [fileEntry(name: "a.jsonl", data: fileData)])
        )
        fetcher.files["a.jsonl"] = fileData

        let provider = makeProvider(fetcher: fetcher)
        let outcome = await provider.sync(to: spool, state: stateURL)
        guard case .failed = outcome else {
            return XCTFail("坏 state 必须报 .failed（不得当空 state 重新同步），got \(outcome)")
        }
        // 未发生任何追加
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.path))
    }

    func testSync_unreadableJournal_terminatesRound() async throws {
        // 审查 P1：journal 存在但内容读不了/解不了时，静默跳过恢复会让 spool 里的
        // 未提交追加留到后续轮次被重复下载再次追加——必须终止本轮、保留现场
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = dir.appendingPathComponent("spool.jsonl")
        let stateURL = dir.appendingPathComponent("state.json")
        // spool 里有一条「未提交」追加 + 损坏的 journal
        try ProviderStagingWriter().write([makeRecord()], to: spool)
        try Data("garbage-bytes".utf8).write(to: stateURL.appendingPathExtension("journal"))

        let fileData = jsonl([makeRecord(symbol: "600036")])
        let fetcher = FakeRemoteFetcher(
            manifestData: manifest(files: [fileEntry(name: "a.jsonl", data: fileData)])
        )
        fetcher.files["a.jsonl"] = fileData

        let provider = makeProvider(fetcher: fetcher)
        let outcome = await provider.sync(to: spool, state: stateURL)
        guard case .failed = outcome else {
            return XCTFail("读不了的 journal 必须终止本轮，got \(outcome)")
        }
        // 现场保留：spool 原样（未被截断也未被再次追加）
        XCTAssertEqual(try ProviderStagingReader().read(from: spool).count, 1)
        XCTAssertEqual(try ProviderStagingReader().read(from: spool)[0].providerCode.value, "600519")
    }

    func testSync_negativeJournalOffset_refused() async throws {
        // 审查 P1：合法 JSON 可解出负偏移——max(0,·) 静默转 0 会清空整个 spool。
        // 必须拒绝执行并保留现场（spool 与 journal 都不动）
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = dir.appendingPathComponent("spool.jsonl")
        let stateURL = dir.appendingPathComponent("state.json")
        try ProviderStagingWriter().write([makeRecord()], to: spool)
        try writeEmptyState(to: stateURL)
        try JSONEncoder().encode(
            RemoteStagingJournal(fileName: "a.jsonl", fileSha256: "deadbeef", spoolOffsetBefore: -1)
        ).write(to: stateURL.appendingPathExtension("journal"))

        let fetcher = FakeRemoteFetcher(manifestData: Data("{}".utf8))
        let provider = makeProvider(fetcher: fetcher)
        let outcome = await provider.sync(to: spool, state: stateURL)
        guard case .failed = outcome else {
            return XCTFail("负偏移必须拒绝，got \(outcome)")
        }
        XCTAssertEqual(try ProviderStagingReader().read(from: spool).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: stateURL.appendingPathExtension("journal").path
        ))
    }

    func testSync_negativeJournalOffset_missingSpool_refused() async throws {
        // 审查 P1：spool 缺失时负偏移同样拒绝（不得当作 offset==0 恢复成功）
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = dir.appendingPathComponent("spool.jsonl")
        let stateURL = dir.appendingPathComponent("state.json")
        try writeEmptyState(to: stateURL)
        try JSONEncoder().encode(
            RemoteStagingJournal(fileName: "a.jsonl", fileSha256: "deadbeef", spoolOffsetBefore: -1)
        ).write(to: stateURL.appendingPathExtension("journal"))

        let fetcher = FakeRemoteFetcher(manifestData: Data("{}".utf8))
        let provider = makeProvider(fetcher: fetcher)
        let outcome = await provider.sync(to: spool, state: stateURL)
        guard case .failed = outcome else {
            return XCTFail("缺失 spool + 负偏移必须拒绝，got \(outcome)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.path))
    }

    func testSync_directoryAtStatePath_failsNotFirstRun() async throws {
        // 审查 P1：fileExists 无法区分「不存在」与「查不了/读不了」。state 路径
        // 被目录占用是真实的非 no-such-file 读取失败（EISDIR）——必须 .failed，
        // 不得当作首次运行的空 state 继续同步
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = dir.appendingPathComponent("spool.jsonl")
        let stateURL = dir.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)

        let fileData = jsonl([makeRecord()])
        let fetcher = FakeRemoteFetcher(
            manifestData: manifest(files: [fileEntry(name: "a.jsonl", data: fileData)])
        )
        fetcher.files["a.jsonl"] = fileData

        let provider = makeProvider(fetcher: fetcher)
        let outcome = await provider.sync(to: spool, state: stateURL)
        guard case .failed = outcome else {
            return XCTFail("读不了的 state 必须报 .failed（不是首次运行），got \(outcome)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.path))
    }

    func testSync_directoryAtJournalPath_terminatesRound() async throws {
        // 审查 P1：journal 路径被目录占用（真实读取失败）→ 终止本轮并保留 spool 现场
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = dir.appendingPathComponent("spool.jsonl")
        let stateURL = dir.appendingPathComponent("state.json")
        try ProviderStagingWriter().write([makeRecord()], to: spool)
        try writeEmptyState(to: stateURL)
        try FileManager.default.createDirectory(
            at: stateURL.appendingPathExtension("journal"),
            withIntermediateDirectories: true
        )

        let fetcher = FakeRemoteFetcher(manifestData: Data("{}".utf8))
        let provider = makeProvider(fetcher: fetcher)
        let outcome = await provider.sync(to: spool, state: stateURL)
        guard case .failed = outcome else {
            return XCTFail("读不了的 journal 必须终止本轮，got \(outcome)")
        }
        XCTAssertEqual(try ProviderStagingReader().read(from: spool).count, 1)
    }

    // MARK: - 服务端拒绝与断路器（DATA010 §3/§4）

    func testSync_serverRejection_mapsToFailed() async throws {
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = dir.appendingPathComponent("spool.jsonl")
        let stateURL = dir.appendingPathComponent("state.json")

        let fetcher = FakeRemoteFetcher(manifestData: Data("{}".utf8))
        fetcher.manifestError = RemoteStagingError.rejectedByServer(statusCode: 403)
        let provider = makeProvider(fetcher: fetcher, backoff: 60)

        let outcome = await provider.sync(to: spool, state: stateURL)
        guard case .failed(.rejectedByServer(let statusCode)) = outcome else {
            return XCTFail("expected rejectedByServer, got \(outcome)")
        }
        XCTAssertEqual(statusCode, 403)
    }

    func testCircuitBreaker_skipsDuringBackoffThenRetries() async throws {
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = dir.appendingPathComponent("spool.jsonl")
        let stateURL = dir.appendingPathComponent("state.json")

        let fetcher = FakeRemoteFetcher(manifestData: Data("{}".utf8))
        fetcher.manifestError = RemoteStagingError.unavailable(detail: "vps down")
        let provider = makeProvider(fetcher: fetcher, backoff: 60)

        // 第一次失败 → 断路器打开 60s
        guard case .failed = await provider.sync(to: spool, state: stateURL) else {
            return XCTFail("expected failed")
        }
        var breaker = await provider.breakerStatus()
        XCTAssertEqual(breaker.consecutiveFailures, 1)
        XCTAssertNotNil(breaker.openUntil)

        // 退避期内：直接 skipped，不触网络（fetcher 不再被调）
        fetcher.manifestError = nil   // 即使恢复了也不该被调用
        guard case .skipped(let openUntil) = await provider.sync(to: spool, state: stateURL) else {
            return XCTFail("expected skipped during backoff")
        }
        XCTAssertGreaterThan(openUntil, now)

        // 越过退避期：重新尝试（此刻 manifest 为空 JSON 会失败——再累计退避翻倍）
        now = now.addingTimeInterval(120)
        guard case .failed = await provider.sync(to: spool, state: stateURL) else {
            return XCTFail("expected retry then failed (empty manifest)")
        }
        breaker = await provider.breakerStatus()
        XCTAssertEqual(breaker.consecutiveFailures, 2)
        // 指数退避：第 2 次失败 = 60 * 2^1 = 120s
        let expectedOpen = now.addingTimeInterval(120)
        XCTAssertEqual(breaker.openUntil, expectedOpen)
    }

    func testCircuitBreaker_successResets() async throws {
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = dir.appendingPathComponent("spool.jsonl")
        let stateURL = dir.appendingPathComponent("state.json")

        let fileData = jsonl([makeRecord()])
        let fetcher = FakeRemoteFetcher(
            manifestData: manifest(files: [fileEntry(name: "a.jsonl", data: fileData)])
        )
        fetcher.files["a.jsonl"] = fileData
        let provider = makeProvider(fetcher: fetcher, backoff: 60)

        // 失败一次后恢复
        fetcher.manifestError = RemoteStagingError.unavailable(detail: "blip")
        guard case .failed = await provider.sync(to: spool, state: stateURL) else {
            return XCTFail("expected failed")
        }
        now = now.addingTimeInterval(61)
        fetcher.manifestError = nil
        guard case .synced = await provider.sync(to: spool, state: stateURL) else {
            return XCTFail("expected synced after recovery")
        }
        let breaker = await provider.breakerStatus()
        XCTAssertEqual(breaker.consecutiveFailures, 0)
        XCTAssertNil(breaker.openUntil)
    }

    // MARK: - manifest 契约

    func testManifest_wireFormatDecoding() throws {
        // 服务端（Python collector）产出的 camelCase + ISO8601 契约
        let json = """
        {"version":1,"collectorVersion":"0.3.0",
         "generatedAt":"2026-08-20T10:00:00Z",
         "files":[{"name":"stock_daily.jsonl","sha256":"abc123","byteSize":2048}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(RemoteStagingManifest.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.collectorVersion, "0.3.0")
        XCTAssertEqual(manifest.files.count, 1)
        XCTAssertEqual(manifest.files[0].name, "stock_daily.jsonl")
        XCTAssertEqual(
            manifest.generatedAt,
            ISO8601DateFormatter().date(from: "2026-08-20T10:00:00Z")
        )
    }

    func testSync_malformedManifest_failsWithDetail() async throws {
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fetcher = FakeRemoteFetcher(manifestData: Data("not json".utf8))
        let provider = makeProvider(fetcher: fetcher)
        let outcome = await provider.sync(
            to: dir.appendingPathComponent("spool.jsonl"),
            state: dir.appendingPathComponent("state.json")
        )
        guard case .failed(.malformedManifest) = outcome else {
            return XCTFail("expected malformedManifest, got \(outcome)")
        }
    }

    // MARK: - ProviderHealth 对接（新鲜度/失败聚合由调用方记录）

    func testHealthIntegration_callerRecordsRemoteFailures() async {
        let clockNow = now
        let monitor = ProviderHealthMonitor(policy: .v1, now: { clockNow })
        await monitor.register(.akshare, reliabilityClass: .communityAggregated)

        // 远程通道连续失败 5 次 → unavailable，调用方读 health 决定降级到原生 provider
        for _ in 0..<5 {
            await monitor.recordFailure(
                .akshare, error: .unavailable(providerID: .akshare, underlying: "vps down")
            )
        }
        let health = await monitor.health(for: .akshare)
        XCTAssertEqual(health?.status, .unavailable)
        let callable = await monitor.isCallable(.akshare)
        XCTAssertFalse(callable)
    }
}

/// URLProtocol 桩：捕获请求（cachePolicy / header），返回预置字节。
/// 仅供 URLSessionRemoteStagingFetcher 的请求级断言用。
private final class RequestRecorderProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var _lastRequest: URLRequest?
    private static var _stubData = Data()

    static var lastRequest: URLRequest? {
        get { lock.lock(); defer { lock.unlock() }; return _lastRequest }
        set { lock.lock(); defer { lock.unlock() }; _lastRequest = newValue }
    }

    static var stubData: Data {
        get { lock.lock(); defer { lock.unlock() }; return _stubData }
        set { lock.lock(); defer { lock.unlock() }; _stubData = newValue }
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _lastRequest = nil
        _stubData = Data()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        // snapshot.txt 返回合法快照 ID；其余路径返回预置 stubData
        let body: Data
        if request.url?.lastPathComponent == "snapshot.txt" {
            body = Data("20260821T000000Z\n".utf8)
        } else {
            body = Self.stubData
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Last-Modified": "Wed, 21 Aug 2026 00:00:00 GMT"]   // 触发启发式缓存的典型响应头
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
