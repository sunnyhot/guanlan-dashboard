import XCTest
@testable import QiemanDashboard

/// W4.4:结论卡四要素拆分的纯派生测试(首句做结论、其余做理由、反证做作废降级)。
final class TrendVerdictPresentationTests: XCTestCase {
    func testSplitsFirstSentenceAsHeadline() {
        let content = TrendVerdictPresentation.split(rationale: "看多，量能持续放大。板块轮动健康，回踩有支撑。")
        XCTAssertEqual(content.headline, "看多，量能持续放大。")
        XCTAssertEqual(content.reasoning, "板块轮动健康，回踩有支撑。")
    }

    func testSingleSentenceAllHeadline() {
        let content = TrendVerdictPresentation.split(rationale: "只有一个判断句")
        XCTAssertEqual(content.headline, "只有一个判断句")
        XCTAssertEqual(content.reasoning, "")
    }

    func testEmptyRationale() {
        let content = TrendVerdictPresentation.split(rationale: "  \n ")
        XCTAssertEqual(content.headline, "")
        XCTAssertEqual(content.reasoning, "")
    }

    func testNewlineSeparator() {
        let content = TrendVerdictPresentation.split(rationale: "第一行结论\n第二行理由")
        XCTAssertEqual(content.headline, "第一行结论")
        XCTAssertEqual(content.reasoning, "第二行理由")
    }

    func testInvalidationFallbackUsesFirstNonEmptyCounterSignal() {
        XCTAssertNil(TrendVerdictPresentation.invalidationText(counterSignals: []))
        XCTAssertNil(TrendVerdictPresentation.invalidationText(counterSignals: ["  ", ""]))
        XCTAssertEqual(
            TrendVerdictPresentation.invalidationText(counterSignals: ["", "跌破前低"]),
            "跌破前低"
        )
    }

    // MARK: - W4.2/W4.5 后的优先级与出口

    func testInvalidationPrefersWhatWouldChangeOverCounterSignals() {
        XCTAssertEqual(
            TrendVerdictPresentation.invalidationText(
                whatWouldChange: "量能连续放大后升级",
                counterSignals: ["跌破前低"]
            ),
            "量能连续放大后升级",
            "whatWouldChange 是一等来源"
        )
        XCTAssertEqual(
            TrendVerdictPresentation.invalidationText(
                whatWouldChange: "  ",
                counterSignals: ["跌破前低"]
            ),
            "跌破前低",
            "whatWouldChange 为空时降级用反证首条"
        )
        XCTAssertNil(
            TrendVerdictPresentation.invalidationText(whatWouldChange: "", counterSignals: [])
        )
    }

    func testWatchSignalExtractsTextAfterMarker() {
        XCTAssertEqual(
            TrendVerdictPresentation.watchSignal(rationale: "暂不明确,信号不足。待观察信号:量能放大突破 20 日均线。"),
            "量能放大突破 20 日均线"
        )
        XCTAssertEqual(
            TrendVerdictPresentation.watchSignal(rationale: "暂不明确,信号不足。待观察信号:利差收窄至 30% 分位。"),
            "利差收窄至 30% 分位",
            "兼容全角冒号"
        )
        XCTAssertNil(
            TrendVerdictPresentation.watchSignal(rationale: "暂不明确,信号不足。"),
            "没有出口标记时返回 nil(UI 显示「依据不足」)"
        )
        XCTAssertNil(TrendVerdictPresentation.watchSignal(rationale: ""))
    }
}
