import XCTest
@testable import QiemanDashboard

// MARK: - 参数规范化签名

final class TrendResearchArgumentCanonicalizerTests: XCTestCase {
    func testEquivalentCodeFormatsShareSignature() {
        let a = TrendResearchArgumentCanonicalizer.signature(
            toolName: "get_market_snapshot",
            arguments: #"{"asset_codes":["0700.HK"],"include_indices":true}"#
        )
        let b = TrendResearchArgumentCanonicalizer.signature(
            toolName: "get_market_snapshot",
            arguments: #"{"include_indices":true,"asset_codes":["hk700"]}"#
        )
        XCTAssertEqual(a, b, "0700.HK 与 hk700 是等价调用，共享缓存签名")

        let c = TrendResearchArgumentCanonicalizer.signature(
            toolName: "get_market_snapshot",
            arguments: #"{"asset_codes":["sh600519"]}"#
        )
        let d = TrendResearchArgumentCanonicalizer.signature(
            toolName: "get_market_snapshot",
            arguments: #"{"asset_codes":["600519.SH"]}"#
        )
        XCTAssertEqual(c, d, "sh600519 与 600519.SH 等价")

        let e = TrendResearchArgumentCanonicalizer.signature(
            toolName: "get_daily_kline",
            arguments: #"{"code":"1.600519","days":120}"#
        )
        let f = TrendResearchArgumentCanonicalizer.signature(
            toolName: "get_daily_kline",
            arguments: #"{"days":120,"code":"600519"}"#
        )
        XCTAssertEqual(e, f, "东财 secid 与裸代码等价")
    }

    func testDifferentArgumentsDifferInSignature() {
        let a = TrendResearchArgumentCanonicalizer.signature(toolName: "t", arguments: #"{"code":"600519"}"#)
        let b = TrendResearchArgumentCanonicalizer.signature(toolName: "t", arguments: #"{"code":"000001"}"#)
        XCTAssertNotEqual(a, b)
        let c = TrendResearchArgumentCanonicalizer.signature(toolName: "other", arguments: #"{"code":"600519"}"#)
        XCTAssertNotEqual(a, c, "工具名不同签名不同")
    }

    func testNaturalLanguageArgumentsUntouched() {
        let query = "贵州茅台 2026 年半年报 业绩如何"
        let a = TrendResearchArgumentCanonicalizer.signature(toolName: "web_search", arguments: #"{"query":"\#(query)"}"#)
        XCTAssertTrue(a.contains("贵州茅台"), "自然语言参数不做代码化改写")
    }

    func testInvalidJSONReturnsTrimmedRaw() {
        let canonical = TrendResearchArgumentCanonicalizer.canonicalJSON("  not-json  ")
        XCTAssertEqual(canonical, "not-json")
        XCTAssertEqual(TrendResearchArgumentCanonicalizer.canonicalJSON(""), "")
    }

    func testNumericAndBooleanValuesPassThrough() {
        let canonical = TrendResearchArgumentCanonicalizer.canonicalJSON(#"{"days":120,"flag":true,"nested":{"code":"hk700"},"list":["0700.HK","不是代码的查询词"]}"#)
        XCTAssertTrue(canonical.contains("\"days\":120"))
        XCTAssertTrue(canonical.contains("\"code\":\"HK00700\""))
        XCTAssertTrue(canonical.contains("\"list\":[\"HK00700\",\"不是代码的查询词\"]"), "数组内逐值规范化，非代码字符串保留")
    }
}

// MARK: - BUDGET_SKIP

final class TrendResearchBudgetSkipTests: XCTestCase {
    func testMinimumStepBudgetConstant() {
        // 2026-09-01 根治:8 → 60(2026-08-31 实证剩 23s 照样放行,流式 405s 超限
        // 382s 才终止;60s 仍远小于正常单轮,但能拦住注定跑不完的请求)。
        XCTAssertEqual(TrendResearchAgent.minimumStepBudgetSeconds, 60, accuracy: 0.001)
    }

    func testBudgetSkipErrorDistinctFromTimeout() {
        let skip = TrendResearchAgentError.budgetSkipBeforeRequest(remaining: 5.2)
        let message = skip.errorDescription ?? ""
        XCTAssertTrue(message.contains("止损"), "budgetSkip 有独立可观测语义")
        XCTAssertTrue(message.contains("5"))
        let timeout = TrendResearchAgentError.totalTimeoutExceeded(limit: 300)
        XCTAssertNotEqual(
            skip.errorDescription, timeout.errorDescription,
            "两种预算耗尽的错误信息可区分"
        )
    }
}

// MARK: - MarketSnapshotTool scope guard

final class MarketSnapshotScopeGuardTests: XCTestCase {
    private func makeContext(fundCodes: [String]) -> TrendResearchToolContext {
        let snapshot = TrendResearchSnapshot(
            runID: UUID(),
            createdAt: "2026-08-28 15:00:00",
            dataAsOf: "2026-08-28 15:00:00",
            privacyMode: .sanitized,
            portfolio: TrendContextPortfolio(
                assetCount: fundCodes.count,
                holdingCount: fundCodes.count,
                activePlanCount: 0,
                pendingAssetCount: 0,
                totalMarketValue: nil,
                totalPendingCashAmount: nil,
                totalEstimatedNextPlanAmount: nil,
                totalEffectiveHoldingAmount: nil
            ),
            assets: [],
            sectors: [],
            platformSignals: [],
            managerSignals: [],
            marketQuotes: fundCodes.map { code in
                TrendResearchQuote(
                    kind: "fund-estimate",
                    evidenceID: "quote:\(code)",
                    code: code,
                    name: "基金\(code)",
                    price: 1.5,
                    changePct: 0.5,
                    changeAmount: nil,
                    quotedAt: nil,
                    sourceLabel: nil
                )
            },
            lookThrough: nil,
            insightHeadline: "测试",
            sourceWarnings: []
        )
        return TrendResearchToolContext(snapshot: snapshot, evidenceLedger: TrendEvidenceLedger())
    }

    func testAllUnknownCodesRejectedAsScopeViolation() async throws {
        let context = makeContext(fundCodes: ["000001", "510300"])
        let call = AgentToolCall(
            id: "snap",
            function: AgentToolFunctionCall(
                name: "get_market_snapshot",
                arguments: #"{"asset_codes":["999999","888888"]}"#
            )
        )
        let result = await TrendResearchToolRegistry().execute(call, context: context)
        XCTAssertTrue(result.isError, "完全越界应硬拒绝")
        let envelope = try XCTUnwrap(Data(result.contentJSON.utf8))
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: envelope) as? [String: Any])
        XCTAssertEqual((payload["error"] as? [String: Any])?["code"] as? String, "scope_violation")
        let message = (payload["error"] as? [String: Any])?["message"] as? String ?? ""
        XCTAssertTrue(message.contains("999999"))
        XCTAssertTrue(message.contains("冻结范围"))
    }

    func testPartialMissKeepsWarningBehavior() async throws {
        let context = makeContext(fundCodes: ["000001"])
        let call = AgentToolCall(
            id: "snap",
            function: AgentToolFunctionCall(
                name: "get_market_snapshot",
                arguments: #"{"asset_codes":["000001","519001"]}"#
            )
        )
        let result = await TrendResearchToolRegistry().execute(call, context: context)
        XCTAssertFalse(result.isError, "部分缺失不硬拒绝，维持既有 warning 语义")
        let envelope = try XCTUnwrap(Data(result.contentJSON.utf8))
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: envelope) as? [String: Any])
        let warnings = payload["warnings"] as? [String] ?? []
        XCTAssertTrue(warnings.contains { $0.contains("519001") })
    }

    func testKnownCodeSucceedsNormally() async throws {
        let context = makeContext(fundCodes: ["000001"])
        let call = AgentToolCall(
            id: "snap",
            function: AgentToolFunctionCall(
                name: "get_market_snapshot",
                arguments: #"{"asset_codes":["000001"]}"#
            )
        )
        let result = await TrendResearchToolRegistry().execute(call, context: context)
        XCTAssertFalse(result.isError)
    }
}
