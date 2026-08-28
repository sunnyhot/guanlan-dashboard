import XCTest
@testable import QiemanDashboard

/// W3.3:生成进度人话叙事的纯派生测试。
/// 阶段只进不退、校验重试计轮次、匹配字符串与 `handleTrendAgentEvent`
/// 写入的真实日志文案同源——改日志文案忘了同步这里会先红。
final class TrendRunProgressNarrativeTests: XCTestCase {
    private func log(
        _ message: String,
        level: TrendProgressLog.Level = .activity
    ) -> TrendProgressLog {
        TrendProgressLog(timestamp: "2026-08-27 10:00:00", message: message, detail: nil, level: level)
    }

    func testEmptyLogsStartAtDataPrep() {
        let narrative = TrendRunProgressNarrative.derive(from: [])
        XCTAssertEqual(narrative.stage, .dataPrep)
        XCTAssertEqual(narrative.attemptCount, 1)
        XCTAssertEqual(narrative.statusText, "正在准备持仓与行情…")
    }

    func testStagesAdvanceAndNeverRegress() {
        let narrative = TrendRunProgressNarrative.derive(from: [
            log("开始：读取市场快照"),
            log("开始：读取组合概览"),
            log("完成：读取市场快照"),
        ])
        XCTAssertEqual(narrative.stage, .marketSnapshot)
    }

    func testResearchAndSynthesisStages() {
        let narrative = TrendRunProgressNarrative.derive(from: [
            log("完成：读取市场快照"),
            log("开始：Tavily 搜索行业与政策"),
            log("开始：校验并提交趋势报告"),
        ])
        XCTAssertEqual(narrative.stage, .synthesis)
        XCTAssertEqual(narrative.statusText, "正在汇总与校验结论…")
    }

    func testValidationRejectionCountsAttempts() {
        let narrative = TrendRunProgressNarrative.derive(from: [
            log("开始：校验并提交趋势报告"),
            log("报告校验失败，正在自动修正", level: .warning),
            log("报告校验失败，正在自动修正", level: .warning),
        ])
        XCTAssertEqual(narrative.stage, .synthesis)
        XCTAssertEqual(narrative.attemptCount, 3)
        XCTAssertEqual(narrative.statusText, "校验修复中(第 3 次尝试)")
    }

    func testValidReportMarksDone() {
        let narrative = TrendRunProgressNarrative.derive(from: [
            log("Agent 已生成有效报告", level: .success),
        ])
        XCTAssertEqual(narrative.stage, .done)
        XCTAssertEqual(narrative.statusText, "已完成")
    }
}
