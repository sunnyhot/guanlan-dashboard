import Foundation
import XCTest
@testable import QiemanDashboard

// AgentRunPolicy 与 ArtifactStore 行为冻结测试。
//
// 冻结 TrendResearchRunPolicy 的预算常量(防止"顺手优化")和
// TrendAgentRunArtifactStore 的持久化契约(完全无现有测试覆盖)。
// 见 docs/ai-pipeline-baseline.md 第 2.3 节(预算)和第 5 节(磁盘契约)。
final class AgentRunPolicyCharacterizationTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-artifact-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    // MARK: - RunPolicy 常量冻结

    func testRunPolicyBaselineConstants() {
        // 冻结默认预算常量。这些数字决定运行边界,改造时若有意调整需主动更新本测试。
        let policy = TrendResearchRunPolicy()
        XCTAssertEqual(policy.maxTurns, 18)
        XCTAssertEqual(policy.expandedMaxTurns, 48)
        XCTAssertEqual(policy.maxToolCalls, 40)
        XCTAssertEqual(policy.expandedMaxToolCalls, 96)
        XCTAssertEqual(policy.reservedSubmitToolCalls, 8)
        XCTAssertEqual(policy.maxInvalidSubmissions, 4)
        XCTAssertEqual(policy.maxPlainTextResponses, 2)
        XCTAssertEqual(policy.perRequestTimeoutSeconds, 180)
        XCTAssertEqual(policy.totalTimeoutSeconds, 1800)
        // 2026-09-01 根治:1800 → 3600,激活 effectiveTotalTimeout 的随组合扩容
        //(此前 base=cap=1800,扩容恒等于 1800 是死代码)。
        XCTAssertEqual(policy.expandedTotalTimeoutSeconds, 3600)
        XCTAssertEqual(policy.temperature, 0.2, accuracy: 0.001)
        XCTAssertEqual(policy.maxToolResultBytes, 32 * 1024)
        // 2026-09-01 根治(runID 0A55B952):单请求输出上限 32K,封住退化生成的无界输出。
        XCTAssertEqual(policy.maxOutputTokensPerRequest, 32_768)

        // 静态默认值
        XCTAssertEqual(TrendResearchRunPolicy.defaultPerRequestTimeoutSeconds, 180)
        XCTAssertEqual(TrendResearchRunPolicy.defaultTotalTimeoutSeconds, 1800)
        XCTAssertEqual(TrendResearchRunPolicy.defaultMaxRequestTimeoutRecoveries, 1)
    }

    /// 2026-09-03 根治(runID 552F6FE4):扩容改为按报告批次数(8只/批 × 400s/轮流式实测)，
    /// 仍被 3600 上限钳制。旧的每资产 4s 外推对 29 只只给 1916s，必然撞墙。
    func testEffectiveTotalTimeoutScalesWithReportBatches() {
        let policy = TrendResearchRunPolicy()
        XCTAssertEqual(policy.effectiveTotalTimeout(assetCount: 0), 1800)
        // 29 只 → 4 批 → 1800 + 4×400 = 3400
        XCTAssertEqual(
            policy.effectiveTotalTimeout(assetCount: 29),
            3400,
            "1800 + ceil(29/8)×400"
        )
        // 100 只 → 13 批 → 1800+5200 = 7000,被 expanded 上限钳到 3600
        XCTAssertEqual(
            policy.effectiveTotalTimeout(assetCount: 100),
            3600,
            "被 expanded 上限钳制"
        )
        // 报告标的数优先于持仓资产数(snapshot.expectedFundCodes 驱动批次)
        XCTAssertEqual(
            policy.effectiveTotalTimeout(assetCount: 50, reportAssetCount: 9),
            1800 + 2 * 400,
            "9 只报告标的 → ceil(9/8)=2 批"
        )
    }

    /// 2026-09-03 根治(runID 552F6FE4 轮 5):单步预算止损分阶段——研究轮 60s 不变,
    /// 提交/fanout 修复轮对齐批报告轮成本(400s),避免「剩 331s 发起注定中途被杀
    /// 的提交轮,输出全白烧且 0 暂存导致降级也失败」。
    func testStepBudgetPhasedByTurnKind() {
        let policy = TrendResearchRunPolicy()
        XCTAssertEqual(
            TrendResearchAgent.stepBudgetSeconds(isSubmissionTurn: false, policy: policy),
            60,
            "研究轮维持 60s"
        )
        XCTAssertEqual(
            TrendResearchAgent.stepBudgetSeconds(isSubmissionTurn: true, policy: policy),
            400,
            "提交轮对齐 totalTimeoutPerReportBatchSeconds"
        )
        XCTAssertEqual(
            TrendResearchAgent.stepBudgetSeconds(isSubmissionTurn: true, policy: policy),
            policy.totalTimeoutPerReportBatchSeconds,
            "与批次预算常量同源,改常量时本测试同步更新"
        )
    }

    /// 2026-09-03 计量:model_response trace 落盘 usage 与推理链/正文分片分类,
    /// 推理链占比可从诊断日志直接读出(runID 552F6FE4 复盘的前置)。
    func testModelResponseTraceEncodesUsageAndChunkSplit() throws {
        let result = AgentCompletionResult(
            assistantMessage: AgentChatMessage(role: .assistant, content: "ok"),
            toolCalls: [],
            stopReason: .stop,
            finishReason: "stop",
            usage: AgentTokenUsage(
                promptTokens: 1200, completionTokens: 800, totalTokens: 2000
            ),
            reasoningChunkCount: 22_720,
            contentChunkCount: 243
        )
        let trace = AIAgentModelResponseTrace(result: result, durationSeconds: 617.5)
        let data = try JSONEncoder().encode(trace)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["reasoningChunkCount"] as? Int, 22_720)
        XCTAssertEqual(object["contentChunkCount"] as? Int, 243)
        let usage = try XCTUnwrap(object["usage"] as? [String: Any])
        XCTAssertEqual(usage["completion_tokens"] as? Int, 800)
        XCTAssertEqual(object["stopReason"] as? String, "stop")
    }

    // MARK: - effectiveLimits 扩张钳制

    func testEffectiveLimitsClampedByExpandedCap() {
        let policy = TrendResearchRunPolicy()

        // 资产数极大时,所有限制被 expanded 硬上限钳制
        let huge = policy.effectiveLimits(assetCount: 10_000, sectorCount: 100)
        XCTAssertEqual(huge.maxTurns, 48, "maxTurns 不得超 expandedMaxTurns")
        XCTAssertEqual(huge.maxToolCalls, 96, "maxToolCalls 不得超 expandedMaxToolCalls")

        // 空资产时回到 baseline
        let empty = policy.effectiveLimits(assetCount: 0)
        XCTAssertEqual(empty.maxTurns, 18)
        XCTAssertEqual(empty.maxToolCalls, 40)
    }

    // MARK: - makeFailure artifact 结构冻结

    func testMakeFailureArtifactStructure() throws {
        let snapshot = makeMinimalSnapshot()
        let evidence = TrendEvidence(
            id: "portfolio:overview:\(snapshot.runID.uuidString)",
            sourceName: "组合概览", title: "测试",
            url: nil, publishedAt: nil, retrievedAt: snapshot.createdAt,
            summary: "敏感信息 sk-1234567890abcdef 应被脱敏",
            metadata: .unknown
        )

        let artifact = TrendAgentRunArtifact.makeFailure(
            snapshot: snapshot,
            settings: TrendAIProviderSettings.empty,
            completedAt: "2026-08-05 10:00:00",
            toolCalls: [],
            canonicalEvidence: [evidence],
            message: "测试失败原因"
        )

        // 顶层固定字段
        XCTAssertEqual(artifact.runID, snapshot.runID)
        XCTAssertEqual(artifact.agentKind, "trend-research")
        XCTAssertEqual(artifact.startedAt, snapshot.createdAt)
        XCTAssertEqual(artifact.trigger, "unknown")
        XCTAssertEqual(artifact.reportSchemaVersion, TrendAnalysisReport.currentSchemaVersion)
        XCTAssertEqual(artifact.reportDisposition, .insufficientEvidence)
        XCTAssertTrue(artifact.claimEvidenceLinks.isEmpty)
        XCTAssertTrue(artifact.confidenceNormalizationResults.isEmpty)
        XCTAssertTrue(artifact.verifierResults.isEmpty)

        // message 嵌套在 validatorResults
        XCTAssertEqual(artifact.validatorResults.count, 1)
        XCTAssertEqual(artifact.validatorResults.first?.accepted, false)
        XCTAssertEqual(artifact.validatorResults.first?.messages, ["测试失败原因"])

        // canonicalEvidence 被脱敏(敏感 token 不出现在脱敏后的 summary 里)
        XCTAssertEqual(artifact.canonicalEvidenceLedger.count, 1)
        let redactedSummary = artifact.canonicalEvidenceLedger.first?.summary ?? ""
        XCTAssertFalse(redactedSummary.contains("sk-1234567890abcdef"),
                       "makeFailure 必须脱敏 canonical evidence 中的敏感信息")
    }

    // MARK: - ArtifactStore rotation(完全无现有测试)

    func testArtifactStoreRotatesToMaximumCount() throws {
        let store = TrendAgentRunArtifactStore(maximumArtifactCount: 3)
        let snapshot = makeMinimalSnapshot()

        // 保存 5 个 artifact(不同 runID),只应保留最近 3 个
        for i in 0..<5 {
            let artifact = TrendAgentRunArtifact.makeFailure(
                snapshot: snapshot,
                settings: TrendAIProviderSettings.empty,
                    completedAt: "2026-08-0\(i + 1) 10:00:00",
                toolCalls: [],
                canonicalEvidence: [],
                message: "run-\(i)"
            )
            try store.save(artifact, in: tempDir)
            // 微小延迟确保 mtime 不同(rotation 按 mtime 排序)
            Thread.sleep(forTimeInterval: 0.05)
        }

        let files = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(files.count, 3, "maximumArtifactCount=3 时应只保留 3 个")
    }

    func testArtifactStoreFileNameFormatAndPermissions() throws {
        let store = TrendAgentRunArtifactStore()
        let snapshot = makeMinimalSnapshot()
        let completedAt = "2026-08-05 10:00:00"

        let artifact = TrendAgentRunArtifact.makeFailure(
            snapshot: snapshot,
            settings: TrendAIProviderSettings.empty,
            completedAt: completedAt,
            toolCalls: [],
            canonicalEvidence: [],
            message: "测试"
        )
        try store.save(artifact, in: tempDir)

        // 文件名格式:<completedAt 前10字符>-<runID>.json
        let expectedName = "2026-08-05-\(snapshot.runID.uuidString).json"
        let expectedURL = tempDir.appendingPathComponent(expectedName, isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedURL.path),
                      "文件名应为 <YYYY-MM-DD>-<runID>.json,实际期望:\(expectedName)")

        // 权限 0o600
        let attrs = try FileManager.default.attributesOfItem(atPath: expectedURL.path)
        let permissions = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o600, "ArtifactStore 应设置 0o600 权限")

        // round-trip
        let loaded = try store.load(from: expectedURL)
        XCTAssertEqual(loaded.runID, snapshot.runID)
        XCTAssertEqual(loaded.agentKind, "trend-research")
    }

    // MARK: - 完整 AI 诊断日志

    func testDiagnosticRecorderWritesCompleteToolExchangeAndRedactsCredentials() async throws {
        let runID = UUID()
        let recorder = try AIAgentDiagnosticRecorder(
            directoryURL: tempDir,
            metadata: AIAgentDiagnosticRunMetadata(
                runID: runID,
                agentKind: "trend-research",
                scope: "closeReview",
                trigger: "manual",
                providerName: "test",
                baseURL: "https://example.test/v1?api_key=plain-base-url-secret",
                model: "test-model",
                privacyMode: TrendPrivacyMode.sanitized.rawValue,
                startedAt: "2026-08-10 18:00:00"
            )
        )
        let call = AgentToolCall(
            id: "call-1",
            function: AgentToolFunctionCall(
                name: TrendReportModuleToolName.assetBatch,
                arguments: """
                {"api_key":"sk-test-secret-123456","market_value":275478,"direction":"up"}
                """
            )
        )

        await AIAgentDiagnosticLog.$recorder.withValue(recorder) {
            await AIAgentDiagnosticLog.recordToolResult(
                turn: 3,
                call: call,
                contentJSON: """
                {"ok":false,"error":{"message":"Cannot initialize TrendDirection from invalid String value up."}}
                """,
                modelContentJSON: """
                {"ok":false,"error":{"message":"Cannot initialize TrendDirection from invalid String value up."}}
                """,
                isError: true
            )
        }

        let content = try String(contentsOf: recorder.fileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("275478"), "本地完整日志应保留分析问题所需的业务数据")
        XCTAssertTrue(content.contains("Cannot initialize TrendDirection"))
        XCTAssertTrue(content.contains("[redacted]"))
        XCTAssertFalse(content.contains("sk-test-secret-123456"))
        XCTAssertFalse(content.contains("plain-base-url-secret"))

        let entries = try content
            .split(separator: "\n")
            .map { line in
                try JSONDecoder().decode(
                    AIAgentDiagnosticTraceEntry.self,
                    from: Data(line.utf8)
                )
            }
        XCTAssertEqual(entries.map(\.event), ["run_started", "tool_result"])
        XCTAssertEqual(entries.last?.turn, 3)
        XCTAssertEqual(entries.last?.toolName, TrendReportModuleToolName.assetBatch)

        let attrs = try FileManager.default.attributesOfItem(atPath: recorder.fileURL.path)
        let permissions = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o600)
    }

    func testDiagnosticRecorderRotatesJSONLFiles() throws {
        for index in 0..<4 {
            _ = try AIAgentDiagnosticRecorder(
                directoryURL: tempDir,
                metadata: AIAgentDiagnosticRunMetadata(
                    runID: UUID(),
                    agentKind: "trend-research",
                    scope: "marketRadar",
                    trigger: "scheduled",
                    providerName: "test",
                    baseURL: "https://example.test/v1",
                    model: "test-model",
                    privacyMode: TrendPrivacyMode.sanitized.rawValue,
                    startedAt: "2026-08-1\(index) 09:00:00"
                ),
                maximumFileCount: 2
            )
            Thread.sleep(forTimeInterval: 0.02)
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "jsonl" }
        XCTAssertEqual(files.count, 2)
    }

    // MARK: - 辅助

    private func makeMinimalSnapshot() -> TrendResearchSnapshot {
        TrendResearchSnapshot(
            runID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            createdAt: "2026-08-05 09:00:00",
            dataAsOf: "2026-08-05 09:00:00",
            privacyMode: .sanitized,
            portfolio: TrendContextPortfolio(
                assetCount: 0, holdingCount: 0,
                activePlanCount: 0, pendingAssetCount: 0,
                totalMarketValue: nil, totalPendingCashAmount: nil,
                totalEstimatedNextPlanAmount: nil, totalEffectiveHoldingAmount: nil
            ),
            assets: [],
            sectors: [],
            platformSignals: [],
            managerSignals: [],
            marketQuotes: [],
            lookThrough: nil,
            insightHeadline: "测试",
            sourceWarnings: [],
            sourceStatuses: []
        )
    }
}
