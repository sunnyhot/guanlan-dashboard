import Foundation

/// 策略技能注入器：把激活的技能渲染成 prompt 段落。
///
/// 语义（对拍 DSA skills 注入规则）：
/// - 用户显式选择技能 → 只注入所选技能，**不注入默认纪律基线**（避免「选了龙头还被塞趋势基线」）；
/// - 未显式选择 → 注入默认纪律基线，不叠加默认技能集；
/// - 技能渲染为分组编号块，标注适用场景与关联理念条目。
enum StrategySkillInjector {
    /// 完整 prompt 段落。explicitIDs 为空表示未显式选择。
    static func promptSection(explicitSkillIDs: [String]) -> String {
        let explicit = explicitSkillIDs.compactMap { StrategySkillLibrary.skill(id: $0) }
        guard !explicit.isEmpty else {
            return CoreTradingSkillPolicy.promptSection()
        }
        return renderSkills(explicit, header: "## 激活的交易技能")
    }

    /// 渲染技能列表（按分类分组、优先级排序、编号标注关联理念）。
    static func renderSkills(_ skills: [StrategySkill], header: String) -> String {
        let ordered = skills.sorted { $0.defaultPriority < $1.defaultPriority }
        var lines: [String] = [header]
        let grouped = Dictionary(grouping: ordered, by: { $0.category })
        let categoryOrder: [StrategySkillCategory] = [.trend, .pattern, .reversal, .framework]
        var index = 0
        for category in categoryOrder {
            guard let items = grouped[category], !items.isEmpty else { continue }
            lines.append("")
            lines.append("### \(category.displayName)类")
            for skill in items {
                index += 1
                let rules = skill.coreRules.map(String.init).joined(separator: "、")
                lines.append("")
                lines.append("#### 技能 \(index)：\(skill.displayName)（关联核心理念：第 \(rules) 条）")
                lines.append("**适用场景**: \(skill.description)")
                lines.append("**适用市场状态**: \(skill.marketRegimes.map(\.displayName).joined(separator: "、"))")
                lines.append("")
                lines.append(skill.instructions)
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// 市场状态路由：由技术分析结果（+可选市场广度）判定 regime，再建议激活的技能集。
/// 对拍 DSA skills/router.py：MA 多头+量能配合 → trendingUp；空头排列 → trendingDown；
/// 均线纠缠 → sideways；巨量分歧 → volatile；涨停潮 → sectorHot。
enum StrategySkillRouter {
    static func regime(
        from analysis: TechnicalAnalysisResult,
        breadth: MarketBreadthStats? = nil
    ) -> MarketRegime {
        if let breadth, breadth.limitUpCount >= 80 {
            return .sectorHot
        }
        if let ratio = analysis.volumeRatio, ratio >= 3.0 {
            return .volatile
        }
        switch analysis.maAlignment {
        case .strongBull, .bull:
            return .trendingUp
        case .bear, .strongBear:
            return .trendingDown
        case .weakBull, .weakBear, .range, nil:
            return .sideways
        }
    }

    /// 该 regime 下建议激活的技能（按优先级升序）。
    static func suggestedSkills(for regime: MarketRegime) -> [StrategySkill] {
        StrategySkillLibrary.all
            .filter { $0.marketRegimes.contains(regime) }
            .sorted { $0.defaultPriority < $1.defaultPriority }
    }

    /// 组合入口：分析结果 → regime → 建议技能。
    static func suggest(from analysis: TechnicalAnalysisResult, breadth: MarketBreadthStats? = nil) -> (regime: MarketRegime, skills: [StrategySkill]) {
        let marketRegime = regime(from: analysis, breadth: breadth)
        return (marketRegime, suggestedSkills(for: marketRegime))
    }
}
