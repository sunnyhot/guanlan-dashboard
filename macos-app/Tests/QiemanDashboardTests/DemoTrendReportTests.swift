import XCTest
@testable import QiemanDashboard

/// W1.3:示例演示报告的防腐测试。
/// Demo 数据必须始终通过当前 Validator——收紧校验(如 W4.3)时这里先红,
/// 强制同步更新演示数据,保证新用户看到的示例始终是最新范式。
final class DemoTrendReportTests: XCTestCase {
    func testDemoReportPassesCurrentValidator() {
        let result = TrendAnalysisValidator().validate(DemoTrendReport.shared)
        XCTAssertTrue(
            result.isValid,
            "Demo 数据与当前 Validator 不同步,需同步更新 DemoTrendReport: \(result.messages)"
        )
    }

    func testDemoReportCoversMainProductShapes() {
        let report = DemoTrendReport.shared
        XCTAssertEqual(Set(report.horizons.map(\.horizon)), Set(TrendHorizon.allCases), "覆盖短/中/长期")
        XCTAssertFalse(report.marketOutlook.isEmpty, "覆盖大盘/大类资产观点")
        XCTAssertFalse(report.sectors.isEmpty, "覆盖板块判断")
        XCTAssertFalse(report.opportunities.isEmpty, "覆盖全市场机会")
        XCTAssertFalse(report.actions.isEmpty, "覆盖行动候选")
    }

    func testDemoReportIsMarkedAsSample() {
        let disclaimer = DemoTrendReport.shared.disclaimer
        XCTAssertTrue(disclaimer.contains("示例"))
        XCTAssertTrue(disclaimer.contains("非真实"))
        XCTAssertTrue(disclaimer.contains("非投资建议"))
    }

    func testDemoEvidenceIDsAllResolve() {
        let evidenceIDs = Set(DemoTrendReport.shared.evidence.map(\.id))
        for referenced in DemoTrendReport.shared.referencedEvidenceIDs {
            XCTAssertTrue(evidenceIDs.contains(referenced), "演示证据缺失: \(referenced)")
        }
    }
}
