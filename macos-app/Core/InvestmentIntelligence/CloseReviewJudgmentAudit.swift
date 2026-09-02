import Foundation

// MARK: - 昨日判断验证（2026-09-02，收盘复盘对账切片）
//
// 每日收盘复盘生成时，把上一次复盘快照的 marketPulse 方向判断与今日实际
// 指数行情做确定性对账——复盘从「生成新判断」升级为「生成 + 验证昨日判断」，
// 让模型与用户都能看到判断的历史命中情况。纯本地计算，零 LLM 成本。
//
// 口径保守：|涨跌幅| < 0.2% 视为无波动；neutral/uncertain 判断无法单日验证，
// 一律记 inconclusive，不做惩罚。这是 L6 信号闭环精神的最小落地形态
// （全套信号化/触发价结算/胜率校准待本切片验证价值后再评估）。

struct YesterdayJudgmentAuditEntry: Codable, Hashable, Identifiable {
    enum Outcome: String, Codable, Hashable {
        /// 方向判断与当日实际走势一致。
        case hit
        /// 方向判断与当日实际走势相反。
        case miss
        /// 无波动、neutral/uncertain 判断或当日行情缺失——单日无法验证。
        case inconclusive
    }

    var id: String { name }
    /// 昨日判断的指数/资产名（与 marketPulse 同名）。
    let name: String
    /// 昨日判断方向。
    let direction: TrendDirection
    /// 今日实际涨跌幅（%）；行情缺失为 nil。
    let changePct: Double?
    let outcome: Outcome
    /// 一句话结论文案（UI/prompt 共用）。
    let verdictText: String
}

enum CloseReviewJudgmentAudit {
    /// |涨跌幅| ≥ 该阈值（%）才视为有效涨/跌，否则记无结论。
    static let significanceThresholdPct = 0.2

    /// 昨日 marketPulse 与今日指数行情对账。名称精确相等或互为包含即视为同标的。
    static func audit(
        pulse: [MarketCloseReviewSnapshot.PulseItem],
        indexQuotes: [MarketIndexKind: MarketIndexQuote]
    ) -> [YesterdayJudgmentAuditEntry] {
        pulse.map { item in
            let changePct = indexQuotes.values
                .first { matches(name: item.name, quoteName: $0.name) }?
                .changePct
            return entry(name: item.name, direction: item.direction, changePct: changePct)
        }
    }

    /// 汇总文案（prompt 注入与 UI 副标题共用）；无对账数据返回 nil。
    static func summaryText(_ entries: [YesterdayJudgmentAuditEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        let hits = entries.filter { $0.outcome == .hit }.count
        let misses = entries.filter { $0.outcome == .miss }.count
        let rest = entries.count - hits - misses
        return "昨日判断验证：\(hits) 印证 · \(misses) 失误 · \(rest) 无结论"
    }

    private static func entry(
        name: String,
        direction: TrendDirection,
        changePct: Double?
    ) -> YesterdayJudgmentAuditEntry {
        let outcome = outcome(direction: direction, changePct: changePct)
        let directionText = direction.displayText
        let verdict: String
        switch outcome {
        case .hit:
            verdict = "昨日\(directionText) · 今日\(formatPct(changePct)) · 印证"
        case .miss:
            verdict = "昨日\(directionText) · 今日\(formatPct(changePct)) · 判断失误"
        case .inconclusive:
            if let changePct {
                verdict = "昨日\(directionText) · 今日\(formatPct(changePct)) · 单日无结论"
            } else {
                verdict = "昨日\(directionText) · 今日行情缺失 · 未验证"
            }
        }
        return YesterdayJudgmentAuditEntry(
            name: name,
            direction: direction,
            changePct: changePct,
            outcome: outcome,
            verdictText: verdict
        )
    }

    private static func outcome(direction: TrendDirection, changePct: Double?) -> YesterdayJudgmentAuditEntry.Outcome {
        guard let changePct else { return .inconclusive }
        let directionIsPositive: Bool
        switch direction {
        case .bullish, .neutralPositive:
            directionIsPositive = true
        case .bearish, .neutralNegative:
            directionIsPositive = false
        case .neutral, .uncertain:
            // 中性判断无法用单日涨跌验证，不奖不罚。
            return .inconclusive
        }
        let movedUp = changePct >= significanceThresholdPct
        let movedDown = changePct <= -significanceThresholdPct
        if movedUp == movedDown { return .inconclusive }  // ±0.2% 内视为无波动
        return (movedUp == directionIsPositive) ? .hit : .miss
    }

    private static func matches(name: String, quoteName: String) -> Bool {
        let a = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = quoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }

    private static func formatPct(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%+.2f%%", value)
    }
}
