import XCTest
@testable import QiemanDashboard

/// AGENT-2 单元测试：investment-agent CLI 的可测入口（run(arguments:)，
/// 注入临时数据目录 / 环境 / 时钟，无真实网络路径）。
/// 二十轮审查回归：P0 同步桥挂死 / P1-1 输入锚点与 --force / P2 双 scheme。
final class InvestmentAgentCLITests: XCTestCase {

    private var dataDirectory: URL!

    override func setUpWithError() throws {
        dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dataDirectory, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDirectory)
    }

    // MARK: 工具

    private func runCLI(
        _ arguments: [String],
        environment: [String: String] = [:],
        now: Date = Date()
    ) async -> InvestmentAgentCLI.RunOutcome {
        await InvestmentAgentCLI.run(
            arguments: arguments, environment: environment, now: { now }
        )
    }

    private func decodeBody(_ outcome: InvestmentAgentCLI.RunOutcome) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: outcome.stdout) as? [String: Any]
        )
    }

    /// 写两笔基金持仓（成本口径可算权重）。
    private func writePortfolio(_ holdings: [UserPortfolioHolding]) throws {
        try UserPortfolioStore().save(
            holdings, to: dataDirectory.appendingPathComponent("user-portfolio.json")
        )
    }

    private let sampleHoldings = [
        UserPortfolioHolding(
            fundCode: "110022", assetType: .fund, units: 1000, costPrice: 1.5,
            displayName: "易方达消费行业"
        ),
        UserPortfolioHolding(
            fundCode: "000834", assetType: .fund, units: 500, costPrice: 2.0,
            displayName: "大成纳斯达克"
        ),
    ]

    // MARK: 基础命令

    func testVersionOutputsSchemaVersion() async throws {
        let outcome = await runCLI(["version"])
        XCTAssertEqual(outcome.exitCode, 0)
        let body = try decodeBody(outcome)
        XCTAssertEqual(body["schema_version"] as? Int, CanonicalDatabase.schemaVersion)
        XCTAssertEqual(body["agent_version"] as? String, InvestmentAgentCLI.agentVersion)
    }

    func testHelpAndUnknownCommand() async throws {
        let help = await runCLI(["help"])
        XCTAssertEqual(help.exitCode, 0)
        let body = try decodeBody(help)
        XCTAssertTrue(
            (body["help"] as? String ?? "").contains("investment-agent"),
            "help 应含用法说明"
        )
        XCTAssertTrue(
            (body["help"] as? String ?? "").contains("--force"),
            "help 应含 --force 说明（二十轮 P1-1）"
        )

        let unknown = await runCLI(["nope-command"])
        XCTAssertEqual(unknown.exitCode, 1)
        XCTAssertTrue(
            (unknown.stderr ?? "").contains("未知命令"),
            "未知命令应报错：\(unknown.stderr ?? "")"
        )
    }

    func testHealthWithDataDirOverrideCreatesDatabase() async throws {
        let outcome = await runCLI(["health", "--data-dir", dataDirectory.path])
        XCTAssertEqual(outcome.exitCode, 0)
        let body = try decodeBody(outcome)
        XCTAssertEqual(body["data_directory"] as? String, dataDirectory.path)
        XCTAssertEqual(body["schema_version"] as? Int, CanonicalDatabase.schemaVersion)
        XCTAssertEqual(body["non_terminal_jobs"] as? Int, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: dataDirectory
                    .appendingPathComponent("investment-intelligence-v2/canonical.sqlite3").path
            ),
            "health 应顺带打开/迁移 canonical 库"
        )
    }

    // MARK: 作业命令（经 AGENT-1 registry）

    func testAttributionRunWithCostBasisWeightsAndFullCoverageGap() async throws {
        try writePortfolio(sampleHoldings)
        let outcome = await runCLI(["attribution", "--data-dir", dataDirectory.path])
        XCTAssertEqual(outcome.exitCode, 0)
        let body = try decodeBody(outcome)
        XCTAssertEqual(body["executed"] as? Bool, true)
        XCTAssertEqual(body["status"] as? String, "COMPLETED")
        XCTAssertEqual(body["workflow"] as? String, "attribution")
        let summary = body["summary"] as? String ?? ""
        XCTAssertTrue(summary.contains("coverage 0.0%"), "无 NAV 数据时覆盖应为 0：\(summary)")
        // artifact 已落库（DAILY_ATTRIBUTION kind）
        let health = try decodeBody(
            await runCLI(["health", "--data-dir", dataDirectory.path])
        )
        let counts = health["artifact_counts"] as? [String: Int] ?? [:]
        XCTAssertEqual(counts["DAILY_ATTRIBUTION"], 1)
    }

    func testAttributionIdempotentSameDayAndNewJobNextDay() async throws {
        try writePortfolio(sampleHoldings)
        let day1 = Date(timeIntervalSince1970: 1_782_000_000)
        let first = try decodeBody(
            await runCLI(["attribution", "--data-dir", dataDirectory.path], now: day1)
        )
        XCTAssertEqual(first["executed"] as? Bool, true)
        // 同归因日（anchor 日相同）重提 → 幂等命中
        let second = try decodeBody(
            await runCLI(
                ["attribution", "--data-dir", dataDirectory.path],
                now: day1.addingTimeInterval(3600)
            )
        )
        XCTAssertEqual(second["executed"] as? Bool, false, "同归因日应幂等命中")
        XCTAssertEqual(second["job_id"] as? String, first["job_id"] as? String)
        // 次日（归因日锚变化）→ 新 job 执行
        let third = try decodeBody(
            await runCLI(
                ["attribution", "--data-dir", dataDirectory.path],
                now: day1.addingTimeInterval(90_000)
            )
        )
        XCTAssertEqual(third["executed"] as? Bool, true, "跨归因日应开新 job")
        XCTAssertNotEqual(third["job_id"] as? String, first["job_id"] as? String)
    }

    func testAttributionForceRerunsSameInput() async throws {
        try writePortfolio(sampleHoldings)
        let first = try decodeBody(
            await runCLI(["attribution", "--data-dir", dataDirectory.path])
        )
        XCTAssertEqual(first["executed"] as? Bool, true)
        // --force：同输入显式重跑（nonce 破坏幂等）
        let forced = try decodeBody(
            await runCLI(["attribution", "--data-dir", dataDirectory.path, "--force"])
        )
        XCTAssertEqual(forced["executed"] as? Bool, true, "--force 应重跑")
        XCTAssertNotEqual(forced["job_id"] as? String, first["job_id"] as? String)
    }

    func testAttributionInvalidDateFailsClosed() async throws {
        try writePortfolio(sampleHoldings)
        let outcome = await runCLI([
            "attribution", "--data-dir", dataDirectory.path, "--date", "2026-13-45",
        ])
        XCTAssertEqual(outcome.exitCode, 1, "非法日期应报错不静默回落今天")
        XCTAssertTrue((outcome.stderr ?? "").contains("非法日期"))
    }

    func testAttributionEmptyPortfolioFails() async throws {
        let outcome = await runCLI(["attribution", "--data-dir", dataDirectory.path])
        XCTAssertEqual(outcome.exitCode, 1)
        // 失败作业入列（attempt 可重试）
        let jobs = try decodeBody(
            await runCLI(["jobs", "--data-dir", dataDirectory.path])
        )
        let entries = jobs["jobs"] as? [[String: Any]] ?? []
        XCTAssertEqual(entries.first?["status"] as? String, "FAILED")
    }

    func testMarketResearchAnchorYieldsNewJobNextDay() async throws {
        let day1 = Date(timeIntervalSince1970: 1_782_000_000)
        let first = try decodeBody(
            await runCLI(
                ["market-research", "--data-dir", dataDirectory.path, "--limit", "3"],
                now: day1
            )
        )
        XCTAssertEqual(first["executed"] as? Bool, true)
        // 同日重提 → 幂等命中（当日 anchor 相同）
        let sameDay = try decodeBody(
            await runCLI(
                ["market-research", "--data-dir", dataDirectory.path, "--limit", "3"],
                now: day1.addingTimeInterval(3600)
            )
        )
        XCTAssertEqual(sameDay["executed"] as? Bool, false)
        // 次日（anchor 变化）→ 新 job
        let nextDay = try decodeBody(
            await runCLI(
                ["market-research", "--data-dir", dataDirectory.path, "--limit", "3"],
                now: day1.addingTimeInterval(90_000)
            )
        )
        XCTAssertEqual(nextDay["executed"] as? Bool, true, "跨日应开新 job（anchor 锚）")
        XCTAssertNotEqual(nextDay["job_id"] as? String, first["job_id"] as? String)
    }

    func testMarketResearchProducesDiscoveryReportAndJobsEntry() async throws {
        let outcome = await runCLI(["market-research", "--data-dir", dataDirectory.path, "--limit", "3"])
        XCTAssertEqual(outcome.exitCode, 0)
        let body = try decodeBody(outcome)
        XCTAssertEqual(body["executed"] as? Bool, true)
        XCTAssertEqual(body["workflow"] as? String, "marketDiscovery")
        let ids = body["artifact_ids"] as? [String] ?? []
        XCTAssertEqual(ids.count, 1, "应产出 MARKET_DISCOVERY_REPORT artifact")

        let jobs = try decodeBody(
            await runCLI(["jobs", "--data-dir", dataDirectory.path])
        )
        let entries = jobs["jobs"] as? [[String: Any]] ?? []
        XCTAssertEqual(entries.first?["workflow"] as? String, "marketDiscovery")
        XCTAssertEqual(entries.first?["status"] as? String, "COMPLETED")
    }

    // MARK: portfolio-review 凭据门槛

    func testPortfolioReviewRequiresLLMEnvironment() async throws {
        let outcome = await runCLI(
            ["portfolio-review", "--data-dir", dataDirectory.path], environment: [:]
        )
        XCTAssertEqual(outcome.exitCode, 1)
        XCTAssertTrue(
            (outcome.stderr ?? "").contains("QIEMAN_LLM"),
            "缺配置应提示环境变量：\(outcome.stderr ?? "")"
        )
        let partial = await runCLI(
            ["portfolio-review", "--data-dir", dataDirectory.path],
            environment: ["QIEMAN_LLM_BASE_URL": "https://example.com"]
        )
        XCTAssertEqual(partial.exitCode, 1, "部分配置同样拒收（不半启动）")
    }

    func testLLMConfigurationParsing() {
        XCTAssertNil(InvestmentAgentCLI.llmConfiguration([:]))
        XCTAssertNil(InvestmentAgentCLI.llmConfiguration([
            "QIEMAN_LLM_BASE_URL": "https://api.example.com",
            "QIEMAN_LLM_MODEL": "gpt-test",
        ]))
        let config = InvestmentAgentCLI.llmConfiguration([
            "QIEMAN_LLM_BASE_URL": " https://api.example.com ",
            "QIEMAN_LLM_MODEL": " gpt-test ",
            "QIEMAN_LLM_API_KEY": " sk-x ",
        ])
        XCTAssertNotNil(config)
    }

    // MARK: 查询命令

    func testIdentityInspectTriesBothSchemesByDefault() async throws {
        try writePortfolio(sampleHoldings)
        // 缺省双 scheme：全数字代码（可能基金也可能 A 股股票）依次尝试，
        // 两者皆未登记时如实 unresolved（二十轮 P2-4）
        let digitCode = try decodeBody(
            await runCLI(["identity-inspect", "--code", "110022", "--data-dir", dataDirectory.path])
        )
        XCTAssertEqual(digitCode["resolved"] as? Bool, false)
        let schemes = digitCode["schemes"] as? [String] ?? []
        XCTAssertEqual(Set(schemes), Set(["fund_code", "stock_symbol"]))
        // 显式 --scheme 只查声明的
        let stock = try decodeBody(
            await runCLI([
                "identity-inspect", "--code", "AAPL", "--scheme", "stock_symbol",
                "--data-dir", dataDirectory.path,
            ])
        )
        XCTAssertEqual(
            (stock["schemes"] as? [String])?.first, "stock_symbol",
            "显式 --scheme 只查声明的 scheme"
        )
        XCTAssertEqual(stock["resolved"] as? Bool, false)
        // 缺 --code 报用法错
        let missing = await runCLI(["identity-inspect", "--data-dir", dataDirectory.path])
        XCTAssertEqual(missing.exitCode, 1)
    }

    func testDecisionReplayNotFound() async throws {
        let outcome = await runCLI([
            "decision-replay", "--id", "art_none", "--data-dir", dataDirectory.path,
        ])
        XCTAssertEqual(outcome.exitCode, 0)
        let body = try decodeBody(outcome)
        XCTAssertEqual(body["replayed"] as? Bool, false)
        XCTAssertEqual(body["reason"] as? String, "artifact 不存在：art_none")
    }

    func testResumeNotFound() async throws {
        let outcome = await runCLI(["resume", "--id", "job_none", "--data-dir", dataDirectory.path])
        XCTAssertEqual(outcome.exitCode, 0)
        let body = try decodeBody(outcome)
        XCTAssertEqual(body["mode"] as? String, "not-found")
    }

    /// 二十轮 P0 回归：旧形态（仅 fingerprint、无 input）的 queued 行，
    /// resume 必须快速报错退出——修复前 nil 哨兵自旋永久挂死。
    func testResumeLegacyFingerprintOnlyRowFailsFast() async throws {
        let database = try CanonicalStorePaths.openDatabase(in: dataDirectory)
        let job = AgentJob(
            workflowKind: "attribution", inputFingerprint: "legacyfp", createdAt: t0()
        )
        // 旧形态行：input_json 只有 fingerprint（无 input 键）
        let row = AgentJobRow(
            id: job.id, workflow: job.workflowKind,
            idempotencyKey: "\(job.workflowKind)|\(job.inputFingerprint)",
            status: "QUEUED",
            inputJSON: try CanonicalColumnCodec.encodeJSON(["fingerprint": "legacyfp"]),
            createdAt: CanonicalColumnCodec.encodeTimestamp(t0()),
            startedAt: nil, completedAt: nil, errorMessage: nil
        )
        try await database.queue.write { db in
            try row.insert(db)
            for eventRow in try AgentJobRow.eventRows(for: job) {
                try eventRow.insert(db)
            }
        }

        let outcome = await runCLI(["resume", "--id", job.id, "--data-dir", dataDirectory.path])
        XCTAssertEqual(outcome.exitCode, 1, "旧形态行应快速报错（missingInputJSON）")
        let stderr = outcome.stderr ?? ""
        XCTAssertTrue(
            stderr.contains("missingInputJSON") || stderr.contains("input"),
            "错误应指明缺原始输入：\(stderr)"
        )
    }

    private func t0() -> Date { Date(timeIntervalSince1970: 1_700_000_000) }

    // MARK: recover 输出

    func testRecoverOnEmptyQueueReportsProcessed() async throws {
        let outcome = await runCLI(["recover", "--data-dir", dataDirectory.path])
        XCTAssertEqual(outcome.exitCode, 0)
        let body = try decodeBody(outcome)
        XCTAssertEqual(body["processed"] as? Int, 0)
        XCTAssertNotNil(body["breakdown"], "应含 breakdown 分类（二十轮 P2-10）")
    }

    // MARK: 数据目录解析

    func testDataDirectoryOverrideResolution() throws {
        let args = try QiemanCommandArguments(
            ["health", "--data-dir", "/tmp/agent-custom"]
        )
        XCTAssertEqual(
            try InvestmentAgentCLI.resolveDataDirectory(args).path,
            "/tmp/agent-custom"
        )
        // 无覆盖 → App 约定路径
        let defaults = try QiemanCommandArguments(["health"])
        let resolved = try InvestmentAgentCLI.resolveDataDirectory(defaults)
        XCTAssertTrue(
            resolved.path.hasSuffix("QiemanDashboard"),
            "默认路径应是 App 数据目录：\(resolved.path)"
        )
    }
}
