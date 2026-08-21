import XCTest
@testable import QiemanDashboard

#if os(macOS)

/// PROV-3b 跨语言契约测试（DATA010 §Compliance「跨语言契约测试守护 schema 对齐」
/// 的离线先行部分）：VPS 侧 `remote_publish.py` 的真实产物 vs Swift 接收面
/// （RemoteStagingProvider）端到端。
///
/// 链路：remote_publish.py `--selftest`（离线，走与生产完全相同的序列化/签名/
/// 落盘路径）→ publish 目录（manifest.json [+ manifest.sig] + {dataset}.jsonl）
/// → DirectoryRemoteFetcher → RemoteStagingProvider（验签 / sha256 / 增量 /
/// SchemaValidator）→ 本地 spool。
///
/// 环境守卫：无 python3 跳过整组；签名用例额外要求 python 侧 cryptography
/// 可用（keygen 失败即跳过该用例，不算失败）。真实 VPS 部署 + HTTP 连通
/// 属 PROV-3b 剩余验收项，不在本测试范围。
final class RemotePublishContractTests: XCTestCase {

    private var workDir: URL!
    private var publishDir: URL!
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
        let thisFile = URL(fileURLWithPath: #filePath)
        let script = thisFile.deletingLastPathComponent()      // .../InvestmentIntelligenceV2
            .deletingLastPathComponent()                        // .../QiemanDashboardTests
            .deletingLastPathComponent()                        // .../Tests
            .deletingLastPathComponent()                        // .../macos-app
            .appendingPathComponent("InvestmentIntelligenceV2/Collector/remote_publish.py")
        return FileManager.default.fileExists(atPath: script.path) ? script : nil
    }

    /// 运行 remote_publish.py，返回 (exit code, stdout, stderr)。
    private func runPublisher(_ args: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let python = try XCTUnwrap(Self.pythonURL, "本机无 python3，跳过跨语言契约测试")
        let script = try XCTUnwrap(Self.publishScript, "remote_publish.py 不在源码树预期位置")
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path] + args
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    /// 离线发布一轮（unsigned）。exit 0 + manifest 存在。
    private func publishSelftest(signedWith key: URL? = nil) throws {
        var args = ["--selftest", "--publish-dir", publishDir.path]
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
        publishDir = workDir.appendingPathComponent("publish", isDirectory: true)
        spoolURL = workDir.appendingPathComponent("spool.jsonl")
        stateURL = workDir.appendingPathComponent("state.json")
    }

    override func tearDown() {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    /// 目录型 fetcher：把 publish 目录当远程根（manifest.json / manifest.sig / 文件）。
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
            fetcher: DirectoryRemoteFetcher(directory: publishDir),
            signaturePublicKey: publicKey
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
        let manifestData = try Data(contentsOf: publishDir.appendingPathComponent("manifest.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(RemoteStagingManifest.self, from: manifestData)

        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.collectorVersion, "0.1.0")
        XCTAssertEqual(manifest.files.count, 5, "selftest 应发布 5 个 dataset 文件")
        XCTAssertEqual(
            Set(manifest.files.map(\.name)),
            ["stock_daily.jsonl", "index_daily.jsonl", "fund_nav.jsonl",
             "fund_holdings.jsonl", "macro_china.jsonl"]
        )
        for file in manifest.files {
            // sha256：64 位小写 hex，且与磁盘文件实际内容一致
            XCTAssertTrue(file.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                          "\(file.name) sha256 应为小写 hex: \(file.sha256)")
            XCTAssertEqual(file.sha256.count, 64)
            let data = try Data(contentsOf: publishDir.appendingPathComponent(file.name))
            XCTAssertEqual(file.sha256, RemoteStagingProvider.sha256Hex(data),
                           "\(file.name) sha256 应与文件内容一致")
            XCTAssertEqual(file.byteSize, data.count, "\(file.name) byteSize 应与文件大小一致")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: publishDir.appendingPathComponent("manifest.sig").path),
            "未提供 --signing-key 时不应产 manifest.sig"
        )
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
        let target = publishDir.appendingPathComponent("stock_daily.jsonl")
        var data = try Data(contentsOf: target)
        data[10] ^= 0xFF
        try data.write(to: target)

        let provider = try makeProvider()
        let summary = try Self.outcomeSummary(await provider.sync(to: spoolURL, state: stateURL))
        XCTAssertEqual(summary.filesRejectedTampered, 1, "被篡改文件拒收")
        XCTAssertEqual(summary.filesDownloaded, 4, "其余 4 个文件正常下载")
        XCTAssertEqual(summary.recordsAppended, 6, "8 - stock_daily 的 2 条 = 6")
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: publishDir.appendingPathComponent("manifest.sig").path))

        // 合法签名：sync 成功，走完 sha256 + SchemaValidator 全链路
        let provider = try makeProvider(publicKey: publicRaw)
        let summary = try Self.outcomeSummary(await provider.sync(to: spoolURL, state: stateURL))
        XCTAssertEqual(summary.recordsAppended, 8)

        // manifest 被篡改（哪怕一个字节）：验签失败 → 拒收整批 + 断路器
        let manifestURL = publishDir.appendingPathComponent("manifest.json")
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
