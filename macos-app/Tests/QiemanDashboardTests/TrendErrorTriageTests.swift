import XCTest
@testable import QiemanDashboard

// MARK: - 错误分诊测试(P4 #6)
//
// 分诊按消息字符串关键词匹配,而消息来自 OpenAICompatibleAgentClientError
// .errorDescription——耦合用「真实错误 → errorDescription → 分诊」全链路锁定:
// 客户端文案改动会先在这里红,不会静默漏分诊。

final class TrendErrorTriageTests: XCTestCase {
    func testRealClientErrorsAreClassifiedWithActionableReasons() {
        let cases: [(error: OpenAICompatibleAgentClientError, keyword: String)] = [
            (.requestFailed(statusCode: 401, detail: nil), "API Key"),
            (.requestFailed(statusCode: 403, detail: nil), "API Key"),
            (.requestFailed(statusCode: 404, detail: nil), "路径"),
            (.requestFailed(statusCode: 500, detail: nil), "服务商"),
            (.invalidBaseURL, "Base URL"),
            (.invalidResponse("缺少 choices 字段"), "工具调用"),
            (.missingConfiguration, "配置"),
        ]
        for entry in cases {
            let message = entry.error.errorDescription ?? ""
            XCTAssertFalse(message.isEmpty, "\(entry.error) 应有错误描述")
            let explanation = TrendErrorTriage.explain(message)
            let combined = explanation.reasonText + (explanation.actionText ?? "")
            XCTAssertTrue(
                combined.contains(entry.keyword),
                "\(entry.error) 分诊结果应含「\(entry.keyword)」,实际:\(combined)"
            )
        }
    }

    func testAuthAndURLProblemsSuggestOpeningSettings() {
        let unauthorized = OpenAICompatibleAgentClientError.requestFailed(statusCode: 401, detail: nil)
        let explanation = TrendErrorTriage.explain(unauthorized.errorDescription ?? "")
        XCTAssertTrue(explanation.shouldOpenSettings)

        let notFound = TrendErrorTriage.explain(
            OpenAICompatibleAgentClientError.requestFailed(statusCode: 404, detail: nil)
                .errorDescription ?? ""
        )
        XCTAssertTrue(notFound.shouldOpenSettings)

        let incompatible = TrendErrorTriage.explain(
            OpenAICompatibleAgentClientError.invalidResponse("bad json").errorDescription ?? ""
        )
        XCTAssertTrue(incompatible.shouldOpenSettings)
    }

    func testRateLimitKeepsOriginalTextAndDoesNotOpenSettings() {
        let message = OpenAICompatibleAgentClientError.requestFailed(statusCode: 429, detail: "余额不足")
            .errorDescription ?? ""
        let explanation = TrendErrorTriage.explain(message)
        XCTAssertFalse(explanation.shouldOpenSettings)
        XCTAssertTrue(explanation.reasonText.contains("余额不足"), "429 的人话应保留原文")
        XCTAssertEqual(explanation.actionText, "稍后再试,或更换供应商")
    }

    func testTimeoutKeepsOriginalTextWithoutExtraAction() {
        let message = OpenAICompatibleAgentClientError.timedOut(300).errorDescription ?? ""
        let explanation = TrendErrorTriage.explain(message)
        XCTAssertEqual(explanation.reasonText, message, "超时原文已含建议,原样透传")
        XCTAssertNil(explanation.actionText)
        XCTAssertFalse(explanation.shouldOpenSettings)
    }

    func testUnknownMessagePassesThrough() {
        let explanation = TrendErrorTriage.explain("某个未知错误 xyz")
        XCTAssertEqual(explanation.reasonText, "某个未知错误 xyz")
        XCTAssertNil(explanation.actionText)
    }

    func testEmptyMessagePassesThroughSafely() {
        let explanation = TrendErrorTriage.explain("  ")
        XCTAssertEqual(explanation.reasonText, "  ")
        XCTAssertNil(explanation.actionText)
    }
}
