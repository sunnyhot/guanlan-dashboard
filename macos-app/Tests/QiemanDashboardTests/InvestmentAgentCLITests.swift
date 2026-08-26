import XCTest
@testable import QiemanDashboard

/// AGENT-2 单元测试：investment-agent CLI 的可测入口（run(arguments:)，
/// 注入临时数据目录 / 环境 / 无真实网络路径）。
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
        environment: [String: String] = [:]
    ) -> InvestmentAgentCLI.RunOutcome {
        InvestmentAgentCLI.run(
            arguments: arguments, environment: environment, now: { Date() }
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

    func testVersionOutputsSchemaVersion() throws {
        let outcome = runCLI(["version"])
        XCTAssertEqual(outcome.exitCode, 0)
        let body = try decodeBody(outcome)
        XCTAssertEqual(body["schema_version"] as? Int, CanonicalDatabase.schemaVersion)
        XCTAssertEqual(body["agent_version"] as? String, InvestmentAgentCLI.agentVersion)
    }

    func testHelpAndUnknownCommand() throws {
        let help = runCLI(["help"])
        XCTAssertEqual(help.exitCode, 0)
        let body = try decodeBody(help)
        XCTAssertTrue(
            (body["help"] as? String ?? "").contains("investment-agent"),
            "help 应含用法说明"
        )

        let unknown = runCLI(["nope-command"])
        XCTAssertEqual(unknown.exitCode, 1)
        XCTAssertTrue(
            (unknown.stderr ?? "").contains("未知命令"),
            "未知命令应报错：\(unknown.stderr ?? "")"
        )
    }

    func testHealthWithDataDirOverrideCreatesDatabase() throws {
        let outcome = runCLI(["health", "--data-dir", dataDirectory.path])
        XCTAssertEqual(outcome.exitCode, 0)
        let body = try decodeBody(outcome)
        XCTAssertEqual(body["data_directory"] as? String, dataDirectory.path)
        XCTAssertEqual(body["schema_version"] as? Int, 7)
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

    func testAttributionRunWithCostBasisWeightsAndFullCoverageGap() throws {
        try writePortfolio(sampleHoldings)
        let outcome = runCLI(["attribution", "--data-dir", dataDirectory.path])
        XCTAssertEqual(outcome.exitCode, 0)
        let body = try decodeBody(outcome)
        XCTAssertEqual(body["executed"] as? Bool, true)
        XCTAssertEqual(body["status"] as? String, "COMPLETED")
        XCTAssertEqual(body["workflow"] as? String, "attribution")
        let summary = body["summary"] as? String ?? ""
        XCTAssertTrue(summary.contains("coverage 0.0%"), "无 NAV 数据时覆盖应为 0：\(summary)")
        // artifact 已落库（DAILY_ATTRIBUTION kind）
        let health = try decodeBody(
            runCLI(["health", "--data-dir", dataDirectory.path])
        )
        let counts = health["artifact_counts"] as? [String: Int] ?? [:]
        XCTAssertEqual(counts["DAILY_ATTRIBUTION"], 1)
    }

    func testAttributionIdempotentResubmit() throws {
        try writePortfolio(sampleHoldings)
        let first = try decodeBody(
            runCLI(["attribution", "--data-dir", dataDirectory.path])
        )
        XCTAssertEqual(first["executed"] as? Bool, true)
        let second = try decodeBody(
            runCLI(["attribution", "--data-dir", dataDirectory.path])
        )
        XCTAssertEqual(second["executed"] as? Bool, false, "同输入已完成应幂等命中")
        XCTAssertEqual(
            second["job_id"] as? String, first["job_id"] as? String
        )
    }

    func testAttributionEmptyPortfolioFails() throws {
        let outcome = runCLI(["attribution", "--data-dir", dataDirectory.path])
        XCTAssertEqual(outcome.exitCode, 1)
        // 失败作业入列（attempt 可重试）
        let jobs = try decodeBody(
            runCLI(["jobs", "--data-dir", dataDirectory.path])
        )
        let entries = jobs["jobs"] as? [[String: Any]] ?? []
        XCTAssertEqual(entries.first?["status"] as? String, "FAILED")
    }

    func testMarketResearchProducesDiscoveryReportAndJobsEntry() throws {
        let outcome = runCLI(["market-research", "--data-dir", dataDirectory.path, "--limit", "3"])
        XCTAssertEqual(outcome.exitCode, 0)
        let body = try decodeBody(outcome)
        XCTAssertEqual(body["executed"] as? Bool, true)
        XCTAssertEqual(body["workflow"] as? String, "marketDiscovery")
        let ids = body["artifact_ids"] as? [String] ?? []
        XCTAssertEqual(ids.count, 1, "应产出 MARKET_DISCOVERY_REPORT artifact")

        let jobs = try decodeBody(
            runCLI(["jobs", "--data-dir", dataDirectory.path])
        )
        let entries = jobs["jobs"] as? [[String: Any]] ?? []
        XCTAssertEqual(entries.first?["workflow"] as? String, "marketDiscovery")
        XCTAssertEqual(entries.first?["status"] as? String, "COMPLETED")
    }

    // MARK: portfolio-review 凭据门槛

    func testPortfolioReviewRequiresLLMEnvironment() throws {
        let outcome = runCLI(
            ["portfolio-review", "--data-dir", dataDirectory.path], environment: [:]
        )
        XCTAssertEqual(outcome.exitCode, 1)
        XCTAssertTrue(
            (outcome.stderr ?? "").contains("QIEMAN_LLM"),
            "缺配置应提示环境变量：\(outcome.stderr ?? "")"
        )
        let partial = runCLI(
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

    func testIdentityInspectSchemeHeuristicAndUnresolved() throws {
        try writePortfolio(sampleHoldings)
        let fund = try decodeBody(
            runCLI(["identity-inspect", "--code", "110022", "--data-dir", dataDirectory.path])
        )
        XCTAssertEqual(fund["resolved"] as? Bool, false)
        XCTAssertEqual(fund["scheme"] as? String, "fund_code", "纯数字缺省基金 scheme")
        let stock = try decodeBody(
            runCLI(["identity-inspect", "--code", "AAPL", "--data-dir", dataDirectory.path])
        )
        XCTAssertEqual(stock["scheme"] as? String, "stock_symbol", "含字母缺省股票 scheme")
        // 缺 --code 报用法错
        let missing = runCLI(["identity-inspect", "--data-dir", dataDirectory.path])
        XCTAssertEqual(missing.exitCode, 1)
    }

    func testDecisionReplayNotFound() throws {
        let outcome = runCLI([
            "decision-replay", "--id", "art_none", "--data-dir", dataDirectory.path,
        ])
        XCTAssertEqual(outcome.exitCode, 0)
        let body = try decodeBody(outcome)
        XCTAssertEqual(body["replayed"] as? Bool, false)
        XCTAssertEqual(body["reason"] as? String, "artifact 不存在：art_none")
    }

    func testResumeNotFound() throws {
        let outcome = runCLI(["resume", "--id", "job_none", "--data-dir", dataDirectory.path])
        XCTAssertEqual(outcome.exitCode, 0)
        let body = try decodeBody(outcome)
        XCTAssertEqual(body["mode"] as? String, "not-found")
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
