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
}
