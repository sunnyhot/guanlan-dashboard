import XCTest
@testable import QiemanDashboard

// MARK: - 技能库

final class StrategySkillLibraryTests: XCTestCase {
    func testLibraryHoldsFifteenUniqueSkills() {
        XCTAssertEqual(StrategySkillLibrary.all.count, 15)
        let ids = Set(StrategySkillLibrary.all.map(\.id))
        XCTAssertEqual(ids.count, 15, "id 唯一")
        for skill in StrategySkillLibrary.all {
            XCTAssertFalse(skill.displayName.isEmpty, "\(skill.id) displayName 非空")
            XCTAssertFalse(skill.description.isEmpty, "\(skill.id) description 非空")
            XCTAssertFalse(skill.instructions.isEmpty, "\(skill.id) instructions 非空")
            XCTAssertFalse(skill.instructions.count < 80, "\(skill.id) instructions 应为完整策略文本而非占位")
            XCTAssertFalse(skill.marketRegimes.isEmpty, "\(skill.id) 至少声明一个适用 regime")
            XCTAssertFalse(skill.requiredTools.isEmpty, "\(skill.id) 至少声明一个依赖工具")
            XCTAssertTrue(skill.coreRules.allSatisfy { (1...7).contains($0) }, "\(skill.id) coreRules 引用合法基线条目")
        }
    }

    func testKnownSkillIDs() {
        let expected: Set<String> = [
            "bull_trend", "ma_golden_cross", "shrink_pullback", "volume_breakout", "hot_theme",
            "event_driven", "growth_quality", "expectation_repricing", "bottom_volume",
            "dragon_head", "one_yang_three_yin", "box_oscillation", "chan_theory",
            "wave_theory", "emotion_cycle",
        ]
        XCTAssertEqual(Set(StrategySkillLibrary.all.map(\.id)), expected)
    }

    func testRequiredToolsReferenceRealAgentTools() {
        let knownTools: Set<String> = [
            "get_daily_kline", "get_market_breadth", "get_market_snapshot",
            "get_portfolio_overview", "get_portfolio_assets", "web_search",
        ]
        for skill in StrategySkillLibrary.all {
            for tool in skill.requiredTools {
                XCTAssertTrue(knownTools.contains(tool), "\(skill.id) 引用了未注册的工具 \(tool)")
            }
        }
    }

    func testSearchByAlias() {
        XCTAssertEqual(StrategySkillLibrary.search("龙头").first?.id, "dragon_head")
        XCTAssertEqual(StrategySkillLibrary.search("金叉").first?.id, "ma_golden_cross")
        XCTAssertEqual(StrategySkillLibrary.search("缠论").count, 1)
        XCTAssertTrue(StrategySkillLibrary.search("").isEmpty)
        XCTAssertTrue(StrategySkillLibrary.search("不存在的东西").isEmpty)
    }

    func testQuantitativeConditionsPreserved() {
        // 抽查关键量化口径未被移植丢失
        XCTAssertTrue(StrategySkillLibrary.skill(id: "shrink_pullback")?.instructions.contains("70%") ?? false, "缩量 <5 日均量 70%")
        XCTAssertTrue(StrategySkillLibrary.skill(id: "shrink_pullback")?.instructions.contains("1%") ?? false, "MA5 误差 1%")
        XCTAssertTrue(StrategySkillLibrary.skill(id: "volume_breakout")?.instructions.contains("2 倍") ?? false, "放量 2 倍")
        XCTAssertTrue(StrategySkillLibrary.skill(id: "bottom_volume")?.instructions.contains("3 倍") ?? false, "底部放量 3 倍")
        XCTAssertTrue(StrategySkillLibrary.skill(id: "wave_theory")?.instructions.contains("1.618") ?? false, "黄金延伸比例")
        XCTAssertTrue(StrategySkillLibrary.skill(id: "emotion_cycle")?.instructions.contains("0.5%") ?? false, "换手率档位")
    }
}

// MARK: - 注入器与默认基线

final class StrategySkillInjectorTests: XCTestCase {
    func testDefaultBaselineHasSevenRules() {
        XCTAssertEqual(CoreTradingSkillPolicy.rules.count, 7)
        let section = CoreTradingSkillPolicy.promptSection()
        XCTAssertTrue(section.hasPrefix("## 默认交易纪律基线"))
        XCTAssertTrue(section.contains("严禁追高"))
        XCTAssertTrue(section.contains("MA5>MA10>MA20"))
    }

    func testNoExplicitSelectionInjectsBaselineOnly() {
        let section = StrategySkillInjector.promptSection(explicitSkillIDs: [])
        XCTAssertTrue(section.contains("默认交易纪律基线"))
        XCTAssertFalse(section.contains("激活的交易技能"), "未显式选择不注入技能集")
    }

    func testExplicitSelectionInjectsSkillsWithoutBaseline() {
        let section = StrategySkillInjector.promptSection(explicitSkillIDs: ["dragon_head", "ma_golden_cross"])
        XCTAssertTrue(section.contains("激活的交易技能"))
        XCTAssertTrue(section.contains("龙头策略"))
        XCTAssertTrue(section.contains("均线金叉"))
        XCTAssertFalse(section.contains("默认交易纪律基线"), "显式选择不叠加基线")
        // 优先级排序：均线金叉(20) 在 龙头策略(90) 前
        let crossRange = section.range(of: "均线金叉")
        let dragonRange = section.range(of: "龙头策略")
        if let crossRange, let dragonRange {
            XCTAssertLessThan(crossRange.lowerBound, dragonRange.lowerBound, "按 defaultPriority 升序渲染")
        }
    }

    func testUnknownSkillIDsAreDropped() {
        let section = StrategySkillInjector.promptSection(explicitSkillIDs: ["not_a_skill"])
        XCTAssertTrue(section.contains("默认交易纪律基线"), "全部未知 id 回退基线")
    }

    func testRenderIncludesRegimeAndCoreRules() {
        let rendered = StrategySkillInjector.renderSkills([StrategySkillLibrary.dragonHead], header: "## 激活的交易技能")
        XCTAssertTrue(rendered.contains("关联核心理念：第 2、7 条"))
        XCTAssertTrue(rendered.contains("**适用市场状态**: 板块热点"))
        XCTAssertTrue(rendered.contains("板块领涨地位"))
    }
}

// MARK: - 路由

final class StrategySkillRouterTests: XCTestCase {
    private func analysis(alignment: MAAlignment?, volumeRatio: Double? = nil) -> TechnicalAnalysisResult {
        TechnicalAnalysisResult(
            code: "600519", asOf: "2026-08-28", score: 60, scoreBreakdown: [:],
            signalBand: .watch, maAlignment: alignment, volumePriceState: nil,
            macdState: nil, rsiState: nil,
            ma5: 10, ma10: 9.9, ma20: 9.8, ma60: nil, biasMA5: 1,
            support: 9.9, resistance: 10.5, volumeRatio: volumeRatio, close: 10.1,
            reasons: [], riskFactors: [], dataBoundary: ""
        )
    }

    func testRegimeFromAlignment() {
        XCTAssertEqual(StrategySkillRouter.regime(from: analysis(alignment: .strongBull)), .trendingUp)
        XCTAssertEqual(StrategySkillRouter.regime(from: analysis(alignment: .bull)), .trendingUp)
        XCTAssertEqual(StrategySkillRouter.regime(from: analysis(alignment: .bear)), .trendingDown)
        XCTAssertEqual(StrategySkillRouter.regime(from: analysis(alignment: .strongBear)), .trendingDown)
        XCTAssertEqual(StrategySkillRouter.regime(from: analysis(alignment: .range)), .sideways)
        XCTAssertEqual(StrategySkillRouter.regime(from: analysis(alignment: .weakBull)), .sideways)
        XCTAssertEqual(StrategySkillRouter.regime(from: analysis(alignment: nil)), .sideways)
    }

    func testHugeVolumeOverridesToVolatile() {
        XCTAssertEqual(StrategySkillRouter.regime(from: analysis(alignment: .bull, volumeRatio: 3.5)), .volatile, "巨量分歧优先于趋势判定")
        XCTAssertEqual(StrategySkillRouter.regime(from: analysis(alignment: .bull, volumeRatio: 1.5)), .trendingUp)
    }

    func testLimitUpFrenzyOverridesToSectorHot() {
        var breadth = MarketBreadthStats()
        breadth.limitUpCount = 120
        XCTAssertEqual(StrategySkillRouter.regime(from: analysis(alignment: .bear, volumeRatio: 3.5), breadth: breadth), .sectorHot, "涨停潮最高优先")
        breadth.limitUpCount = 30
        XCTAssertEqual(StrategySkillRouter.regime(from: analysis(alignment: .bear), breadth: breadth), .trendingDown)
    }

    func testSuggestedSkillsMatchRegime() {
        let trending = StrategySkillRouter.suggestedSkills(for: .trendingUp)
        XCTAssertTrue(trending.contains { $0.id == "bull_trend" })
        XCTAssertTrue(trending.contains { $0.id == "ma_golden_cross" })
        XCTAssertFalse(trending.contains { $0.id == "box_oscillation" })

        let suggest = StrategySkillRouter.suggest(from: analysis(alignment: .strongBull))
        XCTAssertEqual(suggest.regime, .trendingUp)
        XCTAssertEqual(suggest.skills.first?.id, "bull_trend", "优先级最低值排最前（默认策略优先）")
    }
}
