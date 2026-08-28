import XCTest
@testable import QiemanDashboard

// TrendLiveOutputModel：缓冲节流 / 展示截断 / 种类分隔标记。
@MainActor
final class TrendLiveOutputModelTests: XCTestCase {

    func testUpdatePublishesImmediatelyWhenIntervalIsZero() {
        let model = TrendLiveOutputModel(flushInterval: 0)
        model.update(turn: 1, kind: .reasoning, delta: "先想想")
        model.update(turn: 1, kind: .reasoning, delta: "再想想")
        XCTAssertEqual(model.output?.text, "〔思考〕先想想再想想")
        XCTAssertEqual(model.output?.turn, 1)
        XCTAssertEqual(model.displayText, "〔思考〕先想想再想想")
    }

    func testKindSwitchInsertsSeparators() {
        let model = TrendLiveOutputModel(flushInterval: 0)
        model.update(turn: 1, kind: .reasoning, delta: "想")
        model.update(turn: 1, kind: .content, delta: "答")
        model.update(turn: 1, kind: .toolCall, delta: "\n[调用工具 t] {}")
        model.update(turn: 1, kind: .content, delta: "继续")
        XCTAssertEqual(model.output?.text, "〔思考〕想\n答\n[调用工具 t] {}\n继续")
    }

    func testTurnChangeResetsText() {
        let model = TrendLiveOutputModel(flushInterval: 0)
        model.update(turn: 1, kind: .content, delta: "第一轮")
        model.update(turn: 2, kind: .content, delta: "第二轮")
        XCTAssertEqual(model.output?.turn, 2)
        XCTAssertEqual(model.output?.text, "第二轮")
    }

    func testDisplayTextTruncatedToTail() {
        let model = TrendLiveOutputModel(flushInterval: 0)
        let long = String(repeating: "字", count: TrendLiveOutputModel.displayLimit + 500)
        model.update(turn: 1, kind: .content, delta: long)
        let display = model.displayText ?? ""
        XCTAssertEqual(display.first, "…")
        XCTAssertEqual(display.count, TrendLiveOutputModel.displayLimit + 1)
    }

    func testResetClearsEverything() {
        let model = TrendLiveOutputModel(flushInterval: 0)
        model.update(turn: 1, kind: .content, delta: "文本")
        model.reset()
        XCTAssertNil(model.output)
        XCTAssertNil(model.displayText)
    }
}
