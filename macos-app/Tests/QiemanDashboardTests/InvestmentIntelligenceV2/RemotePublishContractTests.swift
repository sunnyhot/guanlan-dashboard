import XCTest
@testable import QiemanDashboard

#if os(macOS)

/// PROV-3b 跨语言契约测试（DATA010 §Compliance「跨语言契约测试守护 schema 对齐」
/// 的离线先行部分）：VPS 侧 `remote_publish.py` 的真实产物 vs Swift 接收面
/// （RemoteStagingProvider）端到端。
///
/// 链路：remote_publish.py `--selftest`（离线，走与生产完全相同的序列化/签名/
/// 落盘路径）→ publish 根目录（snapshots/<ts>/ 快照 + current 原子切换 symlink）
/// → DirectoryRemoteFetcher（读 current/）→ RemoteStagingProvider（验签 / sha256 /
/// 增量 / SchemaValidator）→ 本地 spool。
///
/// 环境守卫：无 python3 跳过整组；签名用例额外要求 python 侧 cryptography
/// 可用（keygen 失败即跳过该用例，不算失败）。真实 VPS 部署 + HTTP 连通
/// 属 PROV-3b 剩余验收项，不在本测试范围。
final class RemotePublishContractTests: XCTestCase {

    private var workDir: URL!
    /// 发布根目录（含 snapshots/ 与 current/）
    private var publishRoot: URL!
    /// nginx 托管面：publishRoot/current（原子切换 symlink）
    private var serveDir: URL!
    private var spoolURL: URL!
    private var stateURL: URL!

    private static var pythonURL: URL? {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static var publishScript: URL? {
        // remote_publish.py 是服务端组件，与 App 包分离，位于仓库根 remote-collector/
        //（#filePath 上溯 4 级到 macos-app，第 5 级到仓库根）
        let thisFile = URL(fileURLWithPath: #filePath)
        let script = thisFile.deletingLastPathComponent()      // .../InvestmentIntelligenceV2
            .deletingLastPathComponent()                        // .../QiemanDashboardTests
            .deletingLastPathComponent()                        // .../Tests
            .deletingLastPathComponent()                        // .../macos-app
            .deletingLastPathComponent()                        // .../仓库根
            .appendingPathComponent("remote-collector/remote_publish.py")
        return FileManager.default.fileExists(atPath: script.path) ? script : nil
    }

    /// 运行 remote_publish.py，返回 (exit code, stdout, stderr)。
    private func runPublisher(_ args: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let python = try XCTUnwrap(Self.pythonURL, "本机无 python3，跳过跨语言契约测试")
        let script = try XCTUnwrap(Self.publishScript, "remote_publish.py 不在源码树预期位置")
        return try Self.runProcess(python, [script.path] + args)
    }

    /// 运行 akshare_collector.py（部分 dataset 的 staging 构造用）。
    private func runCollector(_ args: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let python = try XCTUnwrap(Self.pythonURL, "本机无 python3，跳过跨语言契约测试")
        let script = try XCTUnwrap(Self.collectorScript, "akshare_collector.py 不在源码树预期位置")
        return try Self.runProcess(python, [script.path] + args)
    }

    private static func runProcess(_ executable: URL, _ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    private static var collectorScript: URL? {
        let thisFile = URL(fileURLWithPath: #filePath)
        let script = thisFile.deletingLastPathComponent()      // .../InvestmentIntelligenceV2
            .deletingLastPathComponent()                        // .../QiemanDashboardTests
            .deletingLastPathComponent()                        // .../Tests
            .deletingLastPathComponent()                        // .../macos-app
            .appendingPathComponent("InvestmentIntelligenceV2/Collector/akshare_collector.py")
        return FileManager.default.fileExists(atPath: script.path) ? script : nil
    }

    /// 离线发布一轮（unsigned）。exit 0 + current/manifest.json 存在。
    private func publishSelftest(signedWith key: URL? = nil) throws {
        var args = ["--selftest", "--publish-dir", publishRoot.path]
        if let key { args += ["--signing-key", key.path] }
        let result = try runPublisher(args)
        XCTAssertEqual(result.status, 0, "remote_publish --selftest 应 exit 0（stderr: \(result.stderr)）")
    }

    override func setUpWithError() throws {
        try XCTSkipIf(Self.pythonURL == nil, "本机无 python3，跳过跨语言契约测试")
        try XCTSkipIf(Self.publishScript == nil, "remote_publish.py 不在源码树预期位置")
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prov3b-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        publishRoot = workDir.appendingPathComponent("publish", isDirectory: true)
        serveDir = publishRoot.appendingPathComponent("current")
        spoolURL = workDir.appendingPathComponent("spool.jsonl")
        stateURL = workDir.appendingPathComponent("state.json")
    }

    override func tearDown() {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    /// 目录型 fetcher：把 publish 根的 current/（nginx 托管面）当远程根。
    private struct DirectoryRemoteFetcher: RemoteStagingFetcher, Sendable {
        let directory: URL

        func fetchManifest() async throws -> Data {
            try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        }

        func fetchManifestSignature() async throws -> Data {
            try Data(contentsOf: directory.appendingPathComponent("manifest.sig"))
        }

        func fetchFile(_ name: String) async throws -> Data {
            // 路径穿越防护与生产 fetcher 同款：manifest 白名单外的路径分隔符拒绝
            guard !name.contains("/") else {
                throw RemoteStagingError.unavailable(detail: "path traversal rejected: \(name)")
            }
            return try Data(contentsOf: directory.appendingPathComponent(name))
        }
    }

    private func makeProvider(publicKey: Data? = nil) throws -> RemoteStagingProvider {
        try RemoteStagingProvider(
            fetcher: DirectoryRemoteFetcher(directory: serveDir),
            signaturePublicKey: publicKey
        )
    }

    /// 读 current/manifest.json 并以客户端同款方式解码。
    private func decodeCurrentManifest() throws -> RemoteStagingManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            RemoteStagingManifest.self,
            from: Data(contentsOf: serveDir.appendingPathComponent("manifest.json"))
        )
    }

    private static func outcomeSummary(_ outcome: RemoteStagingSyncOutcome) throws -> RemoteStagingSyncSummary {
        guard case .synced(let summary) = outcome else {
            throw NSError(domain: "test", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "expected .synced, got \(outcome)"])
        }
        return summary
    }

    // MARK: - manifest wire 契约（Python 字节 vs Swift Codable）

    func testManifest_wireContract() throws {
        try publishSelftest()
        let manifest = try decodeCurrentManifest()

        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.collectorVersion, "0.1.0")
        XCTAssertEqual(manifest.files.count, 5, "selftest 应发布 5 个 dataset 文件")
        XCTAssertEqual(
            Set(manifest.files.map(\.name)),
            ["stock_daily.jsonl", "index_daily.jsonl", "fund_nav.jsonl",
             "fund_holdings.jsonl", "macro_china.jsonl"]
        )
        for file in manifest.files {
            // sha256：64 位小写 hex，且与 current/ 下文件实际内容一致
            XCTAssertTrue(file.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                          "\(file.name) sha256 应为小写 hex: \(file.sha256)")
            XCTAssertEqual(file.sha256.count, 64)
            let data = try Data(contentsOf: serveDir.appendingPathComponent(file.name))
            XCTAssertEqual(file.sha256, RemoteStagingProvider.sha256Hex(data),
                           "\(file.name) sha256 应与文件内容一致")
            XCTAssertEqual(file.byteSize, data.count, "\(file.name) byteSize 应与文件大小一致")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: serveDir.appendingPathComponent("manifest.sig").path),
            "未提供 --signing-key 时不应产 manifest.sig"
        )
        // 快照布局：current 是指向 snapshots/<ts> 的 symlink（原子切换点）
        XCTAssertTrue(FileManager.default.fileExists(atPath: serveDir.path))
        let snapshots = publishRoot.appendingPathComponent("snapshots")
        let snapshotDirs = try FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)
        XCTAssertEqual(snapshotDirs.count, 1, "一轮发布产一个快照")
    }

    // MARK: - 接收面端到端（unsigned：sha256 完整性路径）

    func testSync_unsignedPublish_appendsAllDatasets() async throws {
        try publishSelftest()
        let provider = try makeProvider()
        let outcome = await provider.sync(to: spoolURL, state: stateURL)
        let summary = try Self.outcomeSummary(outcome)

        XCTAssertEqual(summary.filesDownloaded, 5)
        XCTAssertEqual(summary.filesRejectedTampered, 0)
        XCTAssertEqual(summary.recordsRejectedInvalidSchema, 0)
        // selftest 样本记录数：stock 2 + index 1 + fund_nav 2 + holdings 1 + macro 2 = 8
        XCTAssertEqual(summary.recordsAppended, 8, "5 个 dataset 的合法记录应全部进 spool")

        // spool 内容可被 PROV-1 Reader 读回（跨语言字节对齐的最终证明）
        let records = try ProviderStagingReader().read(from: spoolURL)
        XCTAssertEqual(records.count, 8)
        XCTAssertEqual(Set(records.map(\.providerID)), [.akshare])
    }

    func testSync_secondRound_isIncremental() async throws {
        try publishSelftest()
        let provider = try makeProvider()
        _ = await provider.sync(to: spoolURL, state: stateURL)
        let second = try Self.outcomeSummary(await provider.sync(to: spoolURL, state: stateURL))
        XCTAssertEqual(second.filesUnchanged, 5, "同 hash 文件应全部跳过")
        XCTAssertEqual(second.recordsAppended, 0, "增量轮不应重复追加")
        XCTAssertEqual(try ProviderStagingReader().read(from: spoolURL).count, 8)
    }

    func testSync_tamperedFile_rejectedOthersContinue() async throws {
        try publishSelftest()
        // 篡改一个 dataset 文件字节（sha256 与 manifest 不符）
        let target = serveDir.appendingPathComponent("stock_daily.jsonl")
        var data = try Data(contentsOf: target)
        data[10] ^= 0xFF
        try data.write(to: target)

        let provider = try makeProvider()
        let summary = try Self.outcomeSummary(await provider.sync(to: spoolURL, state: stateURL))
        XCTAssertEqual(summary.filesRejectedTampered, 1, "被篡改文件拒收")
        XCTAssertEqual(summary.filesDownloaded, 4, "其余 4 个文件正常下载")
        XCTAssertEqual(summary.recordsAppended, 6, "8 - stock_daily 的 2 条 = 6")
    }

    // MARK: - P1 回归：旧 dataset 不进新 manifest（显式文件清单，非目录扫描）

    func testRepublish_staleDatasetsNotReListed() throws {
        // 首轮：selftest 全量 5 个 dataset
        try publishSelftest()
        XCTAssertEqual(try decodeCurrentManifest().files.count, 5)

        // 二轮：staging 只产 2 个 dataset（--dataset 过滤），其余 3 个是首轮旧文件
        let staging = workDir.appendingPathComponent("partial-staging", isDirectory: true)
        let collector = try runCollector([
            "--out-dir", staging.path, "--selftest", "--dataset", "stock_daily,fund_nav"
        ])
        XCTAssertEqual(collector.status, 0, "collector 部分 dataset 应 exit 0（stderr: \(collector.stderr)）")
        let publish = try runPublisher(["--staging-dir", staging.path, "--publish-dir", publishRoot.path])
        XCTAssertEqual(publish.status, 0, "部分 dataset 发布应 exit 0（stderr: \(publish.stderr)）")

        // 新 manifest 只登记本轮的 2 个文件——旧的 3 个不会带着新 generatedAt 重新上架
        let manifest = try decodeCurrentManifest()
        XCTAssertEqual(Set(manifest.files.map(\.name)), ["stock_daily.jsonl", "fund_nav.jsonl"])
        // current/（新快照）里也只有这 2 个文件
        // （contentsOfDirectory 的 URL 版不跟随 symlink，用 path 版）
        let served = try FileManager.default.contentsOfDirectory(atPath: serveDir.path)
        XCTAssertEqual(Set(served),
                       ["stock_daily.jsonl", "fund_nav.jsonl", "manifest.json"])
        // generatedAt 锚定 staging 产出时间（collector manifest 声明），非发布时刻
        let stagingManifestData = try Data(contentsOf: staging.appendingPathComponent("manifest.json"))
        let stagingJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: stagingManifestData) as? [String: Any]
        )
        XCTAssertEqual(manifest.collectorVersion, "0.1.0")
        XCTAssertNotNil(stagingJSON["generatedAt"], "collector manifest 应带 generatedAt")
    }

    // MARK: - P1 回归：manifest 与签名事务提交（签名失败 current 不动）

    func testSigningFailure_keepsCurrentUnchanged() async throws {
        let keyURL = workDir.appendingPathComponent("ed25519.pem")
        let keygen = try runPublisher(["--generate-key", keyURL.path])
        let publicBase64 = keygen.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard keygen.status == 0,
              let publicRaw = Data(base64Encoded: publicBase64), publicRaw.count == 32 else {
            throw XCTSkip("python 侧无 cryptography（keygen exit \(keygen.status): \(keygen.stderr)），跳过验签契约")
        }

        // 首轮签名发布成功
        try publishSelftest(signedWith: keyURL)
        let manifestBefore = try Data(contentsOf: serveDir.appendingPathComponent("manifest.json"))
        let sigBefore = try Data(contentsOf: serveDir.appendingPathComponent("manifest.sig"))

        // 二轮用坏私钥：签名失败必须废弃快照、不切换 current——
        // 线上不会出现「新 manifest 配旧签名」的错配对
        let badKey = workDir.appendingPathComponent("bad.pem")
        try Data("garbage not a pem".utf8).write(to: badKey)
        let failed = try runPublisher([
            "--selftest", "--publish-dir", publishRoot.path, "--signing-key", badKey.path
        ])
        XCTAssertEqual(failed.status, 2, "坏私钥应 exit 2（stderr: \(failed.stderr)）")
        XCTAssertEqual(try Data(contentsOf: serveDir.appendingPathComponent("manifest.json")), manifestBefore,
                       "current manifest 不得被未完成的快照替换")
        XCTAssertEqual(try Data(contentsOf: serveDir.appendingPathComponent("manifest.sig")), sigBefore,
                       "current 签名不得与 manifest 错配")

        // 线上版本仍可被客户端正常验签消费
        let provider = try makeProvider(publicKey: publicRaw)
        let summary = try Self.outcomeSummary(await provider.sync(to: spoolURL, state: stateURL))
        XCTAssertEqual(summary.recordsAppended, 8)
    }

    // MARK: - P2 回归：staging 路径穿越防护

    func testPublish_stagingPathTraversalRejected() throws {
        try publishSelftest()
        let manifestBefore = try Data(contentsOf: serveDir.appendingPathComponent("manifest.json"))

        // 恶意 staging manifest：file 字段带 ../ 与绝对路径
        let staging = workDir.appendingPathComponent("evil-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let evilJSON = """
        {"collectorVersion":"0.1.0","generatedAt":"2026-08-21T00:00:00Z","datasets":{
          "stock_daily":{"status":"ok","recordCount":1,"file":"../../etc/passwd","sha256":null},
          "fund_nav":{"status":"ok","recordCount":1,"file":"/etc/hosts","sha256":null}}}
        """
        try Data(evilJSON.utf8).write(to: staging.appendingPathComponent("manifest.json"))

        let result = try runPublisher(["--staging-dir", staging.path, "--publish-dir", publishRoot.path])
        XCTAssertEqual(result.status, 1, "全部条目非法应 exit 1（stderr: \(result.stderr)）")
        XCTAssertEqual(try Data(contentsOf: serveDir.appendingPathComponent("manifest.json")), manifestBefore,
                       "current 不得被非法条目替换")
    }

    // MARK: - P2 回归：--generate-key 单文件部署不依赖 akshare_collector.py

    func testGenerateKey_worksWithoutCollectorScript() throws {
        // 只部署 remote_publish.py（无 akshare_collector.py 同目录，
        // 也不在仓库源码树相对位置）——keygen 不触碰 collector
        let isolated = workDir.appendingPathComponent("isolated", isDirectory: true)
        try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
        let script = try XCTUnwrap(Self.publishScript)
        try FileManager.default.copyItem(at: script, to: isolated.appendingPathComponent("remote_publish.py"))

        let keyURL = workDir.appendingPathComponent("isolated-key.pem")
        let python = try XCTUnwrap(Self.pythonURL)
        let result = try Self.runProcess(python, [
            isolated.appendingPathComponent("remote_publish.py").path, "--generate-key", keyURL.path
        ])
        XCTAssertEqual(result.status, 0, "keygen 不应依赖 collector（stderr: \(result.stderr)）")
        let publicBase64 = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if let publicRaw = Data(base64Encoded: publicBase64) {
            XCTAssertEqual(publicRaw.count, 32, "stdout 应为 Ed25519 raw 公钥的 base64")
        } else {
            XCTFail("stdout 应只有 base64 公钥一行, got: \(result.stdout)")
        }
    }

    // MARK: - 验签路径（Ed25519：Python cryptography 签 → CryptoKit 验）

    func testSync_signedPublish_verifiesAndTamperDetected() async throws {
        let keyURL = workDir.appendingPathComponent("ed25519.pem")
        let keygen = try runPublisher(["--generate-key", keyURL.path])
        let publicBase64 = keygen.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard keygen.status == 0,
              let publicRaw = Data(base64Encoded: publicBase64), publicRaw.count == 32 else {
            throw XCTSkip("python 侧无 cryptography（keygen exit \(keygen.status): \(keygen.stderr)），跳过验签契约")
        }

        try publishSelftest(signedWith: keyURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: serveDir.appendingPathComponent("manifest.sig").path))

        // 合法签名：sync 成功，走完 sha256 + SchemaValidator 全链路
        let provider = try makeProvider(publicKey: publicRaw)
        let summary = try Self.outcomeSummary(await provider.sync(to: spoolURL, state: stateURL))
        XCTAssertEqual(summary.recordsAppended, 8)

        // manifest 被篡改（哪怕一个字节）：验签失败 → 拒收整批 + 断路器
        let manifestURL = serveDir.appendingPathComponent("manifest.json")
        var tampered = try Data(contentsOf: manifestURL)
        tampered.append(0x20)
        try tampered.write(to: manifestURL)
        let outcome = await provider.sync(to: workDir.appendingPathComponent("spool2.jsonl"),
                                          state: workDir.appendingPathComponent("state2.json"))
        guard case .failed(.signatureVerificationFailed) = outcome else {
            return XCTFail("篡改 manifest 应验签失败拒收整批, got \(outcome)")
        }
        // 验签失败前的数据未受影响（PIT 历史可信）
        XCTAssertEqual(try ProviderStagingReader().read(from: spoolURL).count, 8)
    }
}

#endif
