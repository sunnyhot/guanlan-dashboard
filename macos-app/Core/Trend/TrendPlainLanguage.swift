import Foundation

enum TrendPlainLanguage {
    static func direction(_ direction: TrendDirection) -> String {
        switch direction {
        case .bullish:
            return "走势较强"
        case .neutralPositive:
            return "走势偏强"
        case .neutral:
            return "方向不明"
        case .neutralNegative:
            return "走势偏弱"
        case .bearish:
            return "走势较弱"
        case .uncertain:
            return "暂时看不清"
        }
    }

    static func confidence(_ confidence: TrendConfidence) -> String {
        if confidence.normalizedScore >= 75 {
            return "把握较大"
        }
        if confidence.normalizedScore >= 45 {
            return "把握一般"
        }
        return "把握较小"
    }

    static func actionLabel(_ rawValue: String) -> String {
        switch rawValue {
        case "买入观察":
            return "先观察，等机会"
        case "持有观察":
            return "继续持有"
        case "减仓复核":
            return "检查是否需要减仓"
        case "卖出/减仓":
            return "考虑减仓"
        case "调仓复核", "再平衡复核":
            return "重新检查仓位"
        default:
            return rawValue
        }
    }

    static func actionMethod(_ rawValue: String) -> String {
        switch rawValue {
        case "暂停追买":
            return "暂时不再买入"
        case "等信号再动":
            return "先不操作"
        default:
            return rawValue
        }
    }

    static func sentence(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        for (term, replacement) in replacements {
            value = value.replacingOccurrences(of: term, with: replacement)
        }

        guard let last = value.last else { return value }
        if !"。！？!?；;".contains(last) {
            value.append("。")
        }
        return value
    }

    static func headline(_ rawValue: String) -> String {
        var value = sentence(rawValue)
        while let last = value.last, "。！？!?；;".contains(last) {
            value.removeLast()
        }
        return value
    }

    static func outlookSentence(
        horizon: TrendHorizon,
        direction: TrendDirection,
        confidence: TrendConfidence
    ) -> String {
        "从\(horizon.assetTagText)看，目前\(self.direction(direction))，这项判断\(self.confidence(confidence))。"
    }

    private static let replacements: [(String, String)] = [
        (
            "趋势偏强时只在预算允许且未触发反证下分批买入，优先小额试探或跟随既有计划，避免一次性追高",
            "走势较强时，如果还有可投入资金，也没有出现相反信号，可以先少量买入或按原计划分批投入，不要在价格上涨时一次买太多"
        ),
        ("纳斯达克科技巨头盈利", "纳斯达克大型科技公司的盈利"),
        ("地产链条基本面仍在寻底", "地产行业还没有明显企稳"),
        ("基本面仍在寻底", "经营情况还没有明显企稳"),
        ("基本面无改善", "经营情况没有改善"),
        ("基本面改善", "经营情况改善"),
        ("行业 Beta 向下", "行业整体走势偏弱"),
        ("行业Beta向下", "行业整体走势偏弱"),
        ("盈利动能强劲", "盈利增长较快"),
        ("盈利动能改善", "盈利增长有所改善"),
        ("盈利动能", "盈利增长"),
        ("AI 产业周期", "AI 行业仍在增长"),
        ("AI产业周期", "AI 行业仍在增长"),
        ("地产销售数据未见回暖", "地产销售还没有明显回暖"),
        ("销售超预期回暖", "销售明显好于预期"),
        ("等待基建发力", "还要观察基建需求是否回升"),
        ("水泥价格持续阴跌", "水泥价格持续缓慢下跌"),
        ("强力救市政策", "力度较大的支持政策"),
        ("短期趋势维持偏强", "短期走势仍然较强"),
        ("未触发反证条件", "没有出现相反信号"),
        ("组合仓位仍有预算空间", "组合里还有可投入资金"),
        ("对冲A股波动", "分散 A 股波动带来的风险"),
        ("美股大级别回调", "美股明显下跌"),
        ("微幅盈利", "目前小幅盈利"),
        ("小额试探", "先少量买入"),
        ("跟随既有计划", "按原计划投入"),
        ("一次性追高", "价格上涨时一次买太多"),
        ("未触发反证", "没有出现相反信号"),
        ("反证条件", "相反信号"),
        ("再平衡复核", "重新检查仓位"),
        ("关键心理关口", "重要价格位置"),
        ("估值修复", "价格回到更合理水平"),
        ("风险偏好", "市场情绪"),
        ("跌破支撑位", "跌破近期低点"),
        ("跌破支撑", "跌破近期低点"),
        ("支撑位", "近期低点"),
        ("产业周期", "行业发展阶段"),
        ("科技巨头", "大型科技公司"),
        ("短期趋势", "短期走势"),
        ("量能", "成交量"),
        ("Beta", "整体走势"),
        ("beta", "整体走势"),
        ("动能", "力度")
    ]
}
