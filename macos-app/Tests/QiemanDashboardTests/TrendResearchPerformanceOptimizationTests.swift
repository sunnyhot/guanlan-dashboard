import XCTest
@testable import QiemanDashboard

// MARK: - 复盘生成耗时优化测试(#1/#2/#3/#5,2026-08-19)
//
// 线上背景:closeReview 15.3 分钟里 14.8 分钟是串行分批生成。
// 本批优化:批量 5→8、拒批教训前移、成功批次上下文短桩、closeReview 并行 fan-out。
// #5 的端到端测试依赖 12 基金 fixture 链,暂以契约源码断言 + 生产实战验证覆盖(缺口已记录)。

final class TrendResearchPerformanceOptimizationTests: XCTestCase {
    // MARK: - #3 批量

    func testAssetBatchSizeIsEightAndToolContractUsesConstant() {
        XCTAssertEqual(TrendReportDraftStore.assetBatchSize, 8)
        let tool = SubmitTrendAssetBatchTool()
        XCTAssertTrue(tool.description.contains("每次最多 8 只"), "工具描述应随常量走,实际:\(tool.description)")
        let schemaJSON = try! JSONEncoder().encode(tool.parameters)
        let schemaText = String(data: schemaJSON, encoding: .utf8) ?? ""
        XCTAssertTrue(schemaText.contains("8"), "schema maxItems 应为 8,实际:\(schemaText.prefix(300))")
    }

    // MARK: - #1 拒批教训

    func testRejectionLessonsAreCappedAtTwoAndDeduplicated() {
        var seen: Set<String> = []
        let errors = ["020602 缺乏底层证券行情证据", "rationale 不能为空", "第三条不应注入"]

        let first = TrendResearchAgent.rejectionLessonMessages(errors: errors, seen: &seen)
        XCTAssertEqual(first.count, 2, "单次失败最多注入前两条")
        XCTAssertTrue(first[0].content?.contains("【拒批教训") ?? false)
        XCTAssertTrue(first[0].content?.contains("020602") ?? false)
        XCTAssertTrue(first[1].content?.contains("rationale") ?? false)

        let repeated = TrendResearchAgent.rejectionLessonMessages(errors: errors, seen: &seen)
        XCTAssertTrue(repeated.isEmpty, "同一条教训只注入一次")

        let fresh = TrendResearchAgent.rejectionLessonMessages(errors: ["新的错误"], seen: &seen)
        XCTAssertEqual(fresh.count, 1)

        let empty = TrendResearchAgent.rejectionLessonMessages(errors: ["  ", ""], seen: &seen)
        XCTAssertTrue(empty.isEmpty, "空教训不注入")
    }

    // MARK: - #2 成功批次上下文短桩

    func testStubAcceptedBatchReplacesArgumentsButKeepsCallChain() {
        let agent = TrendResearchAgent(client: ScriptedTrendAgentClient([]))
        let bigArguments = String(repeating: "x", count: 40_000)
        var messages = [
            AgentChatMessage(role: .system, content: "系统提示"),
            AgentChatMessage(
                role: .assistant,
                content: nil,
                toolCalls: [
                    AgentToolCall(
                        id: "keep-1",
                        function: AgentToolFunctionCall(name: "get_market_snapshot", arguments: "{}")
                    ),
                    AgentToolCall(
                        id: "stub-me",
                        function: AgentToolFunctionCall(
                            name: TrendReportModuleToolName.assetBatch,
                            arguments: bigArguments
                        )
                    ),
                ]
            ),
            AgentChatMessage(role: .tool, content: "已暂存", toolCallID: "stub-me"),
        ]

        agent.stubAcceptedBatchArguments(&messages, callID: "stub-me")

        guard let calls = messages[1].toolCalls else {
            return XCTFail("assistant 消息应保留 toolCalls")
        }
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].id, "keep-1", "其他工具调用不受影响")
        XCTAssertEqual(calls[0].function.arguments, "{}")
        XCTAssertEqual(calls[1].id, "stub-me", "callID 链必须保留,tool 结果才不断裂")
        XCTAssertEqual(calls[1].function.name, TrendReportModuleToolName.assetBatch)
        XCTAssertLessThan(
            calls[1].function.arguments.utf8.count, 200,
            "已提交批次参数应替换为短桩"
        )
        XCTAssertTrue(calls[1].function.arguments.contains("accepted"))
        XCTAssertEqual(messages[2].toolCallID, "stub-me", "tool 消息的 callID 引用不变")

        // 未知 callID:原样不动
        var untouched = messages
        agent.stubAcceptedBatchArguments(&untouched, callID: "not-exist")
        XCTAssertEqual(untouched[1].toolCalls?.count, 2)
    }

    // MARK: - #5 fan-out 契约(源码断言;E2E 缺口记录在基线文档)

    func testCloseReviewFanOutWiringContract() throws {
        let source = try TestSourceReader.source(at: "Core/TrendResearch/TrendResearchAgent.swift")
        XCTAssertTrue(source.contains("closeReviewFanOut("), "run() 应接入 fan-out")
        XCTAssertTrue(source.contains("fanOutMinimumFundCount"), "小额持仓不启并行")
        XCTAssertTrue(source.contains("fanout_fallback_to_interactive"), "任何失败必须回退交互循环")
        XCTAssertTrue(source.contains("finalizeAssembledReport(assembled"), "fan-out 复用同一终检链")
        XCTAssertTrue(source.contains("withThrowingTaskGroup"), "批次并行生成")
        // 2026-09-03 根治(runID 552F6FE4 缺陷 A):market 并入并行波,fanout 可直接收官。
        XCTAssertTrue(
            source.contains("case market"),
            "fan-out 单元应包含市场模块(否则 closeReview 永缺 market,注定回退交互)"
        )
        XCTAssertTrue(
            source.contains("SubmitTrendMarketModuleTool()"),
            "market 单元应挂 submit_trend_market_module 的工具定义"
        )
        XCTAssertTrue(
            source.contains("units.append(.market)"),
            "market 单元必须实际加入并行波"
        )
        XCTAssertTrue(
            source.contains("static let fanoutMaxConcurrentUnits = 3"),
            "并发上限 3 路(网关零重试下的限流保险)"
        )
        // 2026-09-03 根治(缺陷 ③.6):fanout 修复预算与交互循环同用扩容口径。
        XCTAssertTrue(
            source.contains("let invalidBudget = Self.effectiveInvalidSubmissionBudget"),
            "fan-out 修复预算应用扩容口径,而非基础 maxInvalidSubmissions"
        )
    }

    /// closeReview 的 required 模块必须含 market——2026-09-01 机会雷达收编后的
    /// 契约(基线 market 不预填)。若未来 scope 改动悄悄移除,fanout 直收购官的
    /// 前提(缺陷 A 根治)失效,本测试先红。
    func testCloseReviewScopeRequiresMarketModule() {
        let baseline = TrendAnalysisReport.fixture(
            generatedAt: "2026-09-03 10:00:00",
            externalSignalStatus: .partial
        )
        let scope = TrendReportDraftStore.effectiveScope(
            requestedScope: .closeReview,
            baselineReport: baseline,
            expectedFundCodes: ["000001", "000002"]
        )
        XCTAssertEqual(scope, .closeReview, "有基线+非空持仓 → 保持 closeReview")
        XCTAssertTrue(
            scope.requiredModuleToolNameSet.contains(TrendReportModuleToolName.market),
            "closeReview 必重算 market 模块"
        )
        XCTAssertTrue(
            scope.requiredModuleToolNameSet.contains(TrendReportModuleToolName.assetBatch),
            "closeReview 必重算基金批次"
        )
    }
}

enum TestSourceReader {
    static func source(at relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
