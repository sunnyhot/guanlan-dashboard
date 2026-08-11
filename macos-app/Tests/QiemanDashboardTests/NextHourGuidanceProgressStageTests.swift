import XCTest
@testable import QiemanDashboard

final class NextHourGuidanceProgressStageTests: XCTestCase {
    func testProgressStagesExposeRealPipelineOrder() {
        XCTAssertEqual(NextHourGuidanceProgressStage.refreshingPortfolio.completedStepCount, 0)
        XCTAssertEqual(NextHourGuidanceProgressStage.refreshingMarket.completedStepCount, 1)
        XCTAssertEqual(NextHourGuidanceProgressStage.preparingResearch.completedStepCount, 2)
        XCTAssertEqual(NextHourGuidanceProgressStage.analyzing.completedStepCount, 3)
        XCTAssertEqual(NextHourGuidanceProgressStage.finalizing.completedStepCount, 4)
        XCTAssertEqual(NextHourGuidanceProgressStage.completed.completedStepCount, 5)
    }

    func testAnalysisStageNamesThreeIndependentInputs() {
        XCTAssertTrue(NextHourGuidanceProgressStage.analyzing.title.contains("行情"))
        XCTAssertTrue(NextHourGuidanceProgressStage.analyzing.title.contains("新闻"))
        XCTAssertTrue(NextHourGuidanceProgressStage.analyzing.title.contains("持仓"))
        XCTAssertTrue(NextHourGuidanceProgressStage.finalizing.title.contains("证据校验"))
    }
}
