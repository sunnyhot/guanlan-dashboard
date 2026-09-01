import Foundation

/// 2026-09-01 根治修复(2026-08-31 晚 closeReview 五连败实证):模型输出缺字段、
/// 缺前缀、缺 horizons 时,由 App 用保守占位内容补齐,不再让整批拒批进入修复循环。
/// 与 v4.6.1 `appendingMissingEvidenceBoundaryIfNeeded` / v4.8.0 归因降级同一先例:
/// 只往保守方向(uncertain / 低置信 / 原因待确认)补写,不宣称因果,原内容保留。
enum TrendDegradedAssetFactory {
    static let missingImpactText = "本轮模型输出未提供该基金的当日涨跌说明。"
    static let missingRationale = "(模型本轮未提供该基金的分析说明。)"
    static let budgetExhaustedReason = "本轮时间预算耗尽"

    /// 预算终局时未覆盖基金的 impactText;含「缺少」边界词,满足待确认措辞契约。
    static func budgetExhaustedImpactText(reason: String) -> String {
        "原因待确认：\(reason)，缺少该基金的当日归因分析。"
    }

    private static let horizonDisplayNames: [TrendHorizon: String] = [
        .short: "短期",
        .medium: "中期",
        .long: "长期",
    ]

    /// 报告级 Validator 要求每资产三个周期齐全;模型批次缺 horizons 时入库即补,
    /// 否则失败会被推迟到终审,而终审的修复预算更昂贵。
    /// rationale 措辞沿用 SubmitTrendReportTool「待观察信号」先例,保证过校验。
    static func synthesizedHorizons(reason: String) -> [TrendHorizonView] {
        TrendHorizon.allCases.map { horizon in
            let displayName = horizonDisplayNames[horizon] ?? horizon.rawValue
            return TrendHorizonView(
                horizon: horizon,
                direction: .uncertain,
                confidence: TrendConfidence(score: 30, label: TrendConfidence.label(for: 30)),
                rationale: "本轮未完成该基金的\(displayName)判断，证据不足。待观察信号:\(reason)；下次运行覆盖本基金后重估。",
                whatWouldChange: reason + "解除后重估方向。",
                counterSignals: ["该基金行情与证据补齐后重估本周期。"],
                claimEvidence: TrendClaimEvidence(exemptionReason: reason)
            )
        }
    }

    /// 预算终局降级报告用:为尚未覆盖的基金合成完整保守条目。
    static func budgetExhaustedAsset(
        code: String,
        name: String,
        sector: String,
        reason: String = budgetExhaustedReason
    ) -> TrendAssetView {
        TrendAssetView(
            id: "fund:fundmkt:off_exchange:code:\(code)",
            name: name,
            code: code,
            sector: sector,
            impactText: budgetExhaustedImpactText(reason: reason),
            horizons: synthesizedHorizons(reason: reason),
            rationale: missingRationale,
            counterSignals: ["下次运行完成该基金归因后重估。"],
            claimEvidence: TrendClaimEvidence(
                exemptionReason: "\(reason)，未完成该基金分析。"
            )
        )
    }
}
