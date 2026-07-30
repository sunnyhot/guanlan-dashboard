import Foundation

/// 从 UserPortfolioValuationRow 派生的只读估值上下文
struct PortfolioValuationAlertContext: Equatable {
    let holdingProfitPct: Double?
    let estimateChangePct: Double?
    let estimatePrice: Double?

    init(holdingProfitPct: Double?, estimateChangePct: Double?, estimatePrice: Double?) {
        self.holdingProfitPct = holdingProfitPct
        self.estimateChangePct = estimateChangePct
        self.estimatePrice = estimatePrice
    }
}

/// 单条规则的评估结果
enum PortfolioValuationAlertEvaluation: Equatable {
    /// 未 breached 且达标 → 应触发通知
    case fire
    /// 已 breached 仍在区间 → 不重发（去重）
    case hold
    /// 已 breached 但已回落离开 → 解除 breached
    case clear
    /// 未达标且未 breached → 无动作
    case idle
}

enum PortfolioValuationAlertEvaluator {
    /// 浮点比较容差，与 PersonalWatchlistAlertEvaluator 一致
    static let thresholdEpsilon: Double = 1e-9

    /// 评估单条规则本次应如何处理
    static func evaluate(
        rule: PortfolioValuationAlertRule,
        context: PortfolioValuationAlertContext,
        isCurrentlyBreached: Bool
    ) -> PortfolioValuationAlertEvaluation {
        guard rule.isEnabled else { return .idle }

        // 阈值非有限（仅可能来自手改 JSON 等异常输入）→ 视为规则无效，保持 breached 状态。
        // 与 PersonalWatchlistAlertEvaluator 的 threshold 校验保持一致。
        guard rule.threshold.isFinite else {
            return isCurrentlyBreached ? .hold : .idle
        }

        guard let observedValue = observedValue(for: rule.metric, in: context),
              observedValue.isFinite else {
            // 数据缺失：保持 breached 状态（不解除），避免行情闪烁误解除
            return isCurrentlyBreached ? .hold : .idle
        }

        let inRange: Bool
        switch rule.direction {
        case .above:
            inRange = observedValue >= rule.threshold - thresholdEpsilon
        case .below:
            inRange = observedValue <= rule.threshold + thresholdEpsilon
        }

        if inRange {
            return isCurrentlyBreached ? .hold : .fire
        } else {
            return isCurrentlyBreached ? .clear : .idle
        }
    }

    private static func observedValue(
        for metric: PortfolioValuationAlertMetric,
        in context: PortfolioValuationAlertContext
    ) -> Double? {
        switch metric {
        case .holdingProfitPct: return context.holdingProfitPct
        case .estimateChangePct: return context.estimateChangePct
        case .estimatePrice: return context.estimatePrice
        }
    }

    /// 生成通知正文文案
    static func describe(
        rule: PortfolioValuationAlertRule,
        fundName: String,
        fundCode: String,
        observedValue: Double?
    ) -> String {
        let nameText = "\(fundName)(\(fundCode))"
        let sideText = rule.side == .sell ? "可考虑卖出" : "可考虑加仓"
        let metricName = rule.metric.displayName
        let thresholdText = formatThreshold(rule)

        if let observedValue, observedValue.isFinite {
            let valueText = formatValue(observedValue, metric: rule.metric)
            switch rule.metric {
            case .holdingProfitPct:
                return "\(nameText) 持有收益率达 \(valueText)，超过 \(thresholdText) 目标，\(sideText)"
            case .estimateChangePct:
                return "\(nameText) 盘中估算涨跌 \(valueText)，超过 \(thresholdText) 目标"
            case .estimatePrice:
                return "\(nameText) 估算净值 \(valueText)，超过 \(thresholdText) 目标，\(sideText)"
            }
        } else {
            return "\(nameText) \(metricName)\(rule.direction == .above ? "达到" : "跌破") \(thresholdText) 目标，\(sideText)"
        }
    }

    private static func formatValue(_ value: Double, metric: PortfolioValuationAlertMetric) -> String {
        switch metric {
        case .holdingProfitPct, .estimateChangePct:
            return "\(value >= 0 ? "+" : "")\(String(format: "%.2f", value))%"
        case .estimatePrice:
            return String(format: "%.4f", value)
        }
    }

    private static func formatThreshold(_ rule: PortfolioValuationAlertRule) -> String {
        switch rule.metric {
        case .holdingProfitPct, .estimateChangePct:
            return "\(rule.threshold >= 0 ? "+" : "")\(String(format: "%.2f", rule.threshold))%"
        case .estimatePrice:
            return String(format: "%.4f", rule.threshold)
        }
    }
}
