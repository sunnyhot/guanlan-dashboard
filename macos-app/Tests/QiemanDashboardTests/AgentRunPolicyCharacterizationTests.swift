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
        XCTAssertEqual(policy.expandedTotalTimeoutSeconds, 1800)
        XCTAssertEqual(policy.temperature, 0.2, accuracy: 0.001)
        XCTAssertEqual(policy.maxToolResultBytes, 32 * 1024)

        // 静态默认值
        XCTAssertEqual(TrendResearchRunPolicy.defaultPerRequestTimeoutSeconds, 180)
        XCTAssertEqual(TrendResearchRunPolicy.defaultTotalTimeoutSeconds, 1800)
        XCTAssertEqual(TrendResearchRunPolicy.defaultMaxRequestTimeoutRecoveries, 1)
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
