import XCTest
@testable import QiemanDashboard

// MARK: - 术语解释表与统一把握档位测试
//
// 词表是「页面术语必须有人话解释」的登记处：新增术语要有完整解释，
// 把握档位阈值(85/75/45)与全站徽章呈现共用，不得出现第二套评分词。
// 阈值与 TrendConfidenceMeter 色带(75/45)及磁盘 label 边界对齐，
// 保证文字档位与色带颜色不打架。

final class ResearchTermGlossaryTests: XCTestCase {
    func testAllTermsHaveCompletePlainLanguageEntries() {
        for term in ResearchTerm.allCases {
            XCTAssertFalse(term.title.isEmpty, "\(term.rawValue) 缺少术语词面")
            XCTAssertGreaterThan(
                term.plainExplanation.count, 10,
                "\(term.rawValue) 缺少人话解释"
            )
            XCTAssertTrue(
                term.example.hasPrefix("例："),
                "\(term.rawValue) 缺少具体例子"
            )
        }
    }

    func testCoreTermsAreRegistered() {
        let titles = Set(ResearchTerm.allCases.map(\.title))
        for expected in ["把握", "触发与失效", "三方判断约束", "独立来源", "穿透覆盖", "姿态"] {
            XCTAssertTrue(titles.contains(expected), "词表缺少核心术语「\(expected)」")
        }
    }

    func testConfidenceExplanationDeniesPriceProbabilityReading() {
        // 最常见的误读是「把握 78 = 78% 概率上涨」，解释必须显式否认。
        XCTAssertTrue(ResearchTerm.confidence.plainExplanation.contains("不是"))
        XCTAssertTrue(
            ResearchTerm.confidence.plainExplanation.contains("概率"),
            "把握解释应说明它不是涨跌概率"
        )
    }

    func testTriggerInvalidationCoversBothDirections() {
        let explanation = ResearchTerm.triggerInvalidation.plainExplanation
        XCTAssertTrue(explanation.contains("触发"))
        XCTAssertTrue(explanation.contains("失效"))
    }

    func testConfidenceGradeBoundaries() {
        XCTAssertEqual(ConfidenceGrade(score: 100), .veryHigh)
        XCTAssertEqual(ConfidenceGrade(score: 85), .veryHigh)
        XCTAssertEqual(ConfidenceGrade(score: 84), .high)
        XCTAssertEqual(ConfidenceGrade(score: 75), .high)
        XCTAssertEqual(ConfidenceGrade(score: 74), .medium)
        XCTAssertEqual(ConfidenceGrade(score: 45), .medium)
        XCTAssertEqual(ConfidenceGrade(score: 44), .low)
        XCTAssertEqual(ConfidenceGrade(score: 0), .low)
    }

    func testConfidenceGradeTexts() {
        XCTAssertEqual(ConfidenceGrade.veryHigh.gradeText, "很高")
        XCTAssertEqual(ConfidenceGrade.high.gradeText, "较高")
        XCTAssertEqual(ConfidenceGrade.medium.gradeText, "中等")
        XCTAssertEqual(ConfidenceGrade.low.gradeText, "偏低")
    }

    func testBadgeTextPutsGradeBeforeNumber() {
        XCTAssertEqual(ConfidenceGrade.badgeText(score: 65), "把握 中等 65")
        XCTAssertEqual(ConfidenceGrade.badgeText(score: 90), "把握 很高 90")
    }
}
