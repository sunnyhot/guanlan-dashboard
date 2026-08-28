import XCTest
@testable import QiemanDashboard

/// W2.3:「今天一句话」hero 派生测试——优先级、冲突语义、降级路径。
final class TodayVerdictDerivationTests: XCTestCase {
    func testEmptyInputReturnsNil() {
        XCTAssertNil(TodayVerdictDerivation.derive(TodayVerdictDerivation.Input()))
    }

    func testPosturePlusMediumRendersDualPhrase() {
        let verdict = TodayVerdictDerivation.derive(
            TodayVerdictDerivation.Input(intradayPosture: .defensive, mediumDirection: .bearish)
        )
        XCTAssertEqual(verdict, "短线防守 · 中线看淡")
    }

    func testConflictingDirectionsUseContrastPhrasingNotMush() {
        // 盘中防御 + 中期看多 → 固定对照措辞,绝不平均成中性句。
        let bullishMedium = TodayVerdictDerivation.derive(
            TodayVerdictDerivation.Input(intradayPosture: .defensive, mediumDirection: .bullish)
        )
        XCTAssertEqual(bullishMedium, "短线防御 · 中线逢低布局")

        let bearishMedium = TodayVerdictDerivation.derive(
            TodayVerdictDerivation.Input(intradayPosture: .opportunistic, mediumDirection: .bearish)
        )
        XCTAssertEqual(bearishMedium, "短线进攻 · 中线注意回撤")
    }

    func testPostureOnlySinglePhrase() {
        XCTAssertEqual(
            TodayVerdictDerivation.derive(TodayVerdictDerivation.Input(intradayPosture: .selective)),
            "短线择机"
        )
    }

    func testMediumUncertainFallsBackToPostureOnly() {
        let verdict = TodayVerdictDerivation.derive(
            TodayVerdictDerivation.Input(intradayPosture: .balanced, mediumDirection: .uncertain)
        )
        XCTAssertEqual(verdict, "短线均衡")
    }

    func testRadarSignalFallbackWhenNoPostureNoMedium() {
        let verdict = TodayVerdictDerivation.derive(
            TodayVerdictDerivation.Input(
                topRadarSignalName: "中证红利",
                topRadarRecommendation: .startWatching
            )
        )
        XCTAssertEqual(verdict, "中证红利:开始关注")
    }

    func testMediumOnlyFallback() {
        XCTAssertEqual(
            TodayVerdictDerivation.derive(TodayVerdictDerivation.Input(mediumDirection: .neutralPositive)),
            "中线看多"
        )
    }

    func testAllOutputsStayWithinTwentyCharacters() {
        let inputs = [
            TodayVerdictDerivation.Input(intradayPosture: .defensive, mediumDirection: .bullish),
            TodayVerdictDerivation.Input(intradayPosture: .opportunistic, mediumDirection: .bearish),
            TodayVerdictDerivation.Input(intradayPosture: .balanced, mediumDirection: .neutral),
            TodayVerdictDerivation.Input(topRadarSignalName: "沪深300指数增强", topRadarRecommendation: .keyOpportunity),
            TodayVerdictDerivation.Input(mediumDirection: .neutralNegative)
        ]
        for input in inputs {
            if let verdict = TodayVerdictDerivation.derive(input) {
                XCTAssertLessThanOrEqual(verdict.count, 20, "hero 超过 20 字: \(verdict)")
            }
        }
    }
}
