import Foundation

/// W4.4:结论卡的四要素拆分(纯派生,双端可复用)。
///
/// 把 `rationale` 拆成「一句话结论 + 为什么」两段:第一句做 headline,
/// 其余做 reasoning。`whatWouldChange`(W4.2)落地前,「什么情况作废」
/// 降级用 `counterSignals` 首条;两者都缺时返回 nil,UI 不渲染该行。
enum TrendVerdictPresentation {
    struct Content: Equatable {
        /// 结论句(rationale 第一句)。
        let headline: String
        /// 支撑理由(其余句子);第一句即全部时为空。
        let reasoning: String
    }

    static func split(rationale: String) -> Content {
        let trimmed = rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Content(headline: "", reasoning: "") }
        guard let range = trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "。!?!?…\n")) else {
            return Content(headline: trimmed, reasoning: "")
        }
        let headline = String(trimmed[..<range.lowerBound])
        let separator = String(trimmed[range])
        let rest = String(trimmed[range.upperBound...])
        let reasoning = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        // 首个分隔符就是换行/省略号时,headline 已是完整句;句读符并入 headline 更自然。
        if separator == "。" || separator == "!" || separator == "?" {
            let withMark = headline + separator
            return Content(headline: withMark, reasoning: reasoning)
        }
        return Content(headline: headline, reasoning: reasoning)
    }

    /// 「什么情况作废/升级」的降级取值:反证信号首条(W4.2 前的旧数据路径)。
    static func invalidationText(counterSignals: [String]) -> String? {
        for signal in counterSignals {
            let trimmed = signal.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// 「什么情况作废/升级」的取值优先级(W4.2 落地后):
    /// `whatWouldChange` > 反证信号首条;两者都缺时返回 nil,UI 不渲染该行。
    static func invalidationText(whatWouldChange: String, counterSignals: [String]) -> String? {
        let trimmed = whatWouldChange.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return invalidationText(counterSignals: counterSignals)
    }

    /// W4.5:「暂不明确 · 在等 XX」的等待内容——取 rationale 中
    /// 「待观察信号:」之后的尾句;没有则返回 nil(UI 降级显示「依据不足」)。
    static func watchSignal(rationale: String) -> String? {
        guard let range = rationale.range(of: "待观察信号") else { return nil }
        let rest = String(rationale[range.upperBound...])
            .drop { $0 == ":" || $0 == "：" || $0.isWhitespace }
        let trimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。"))
        return trimmed.isEmpty ? nil : trimmed
    }
}
