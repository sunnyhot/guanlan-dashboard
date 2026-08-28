import Foundation

/// W4 结论明确性契约的基线补丁:增量运行复用旧基线数据时,由 App 保证其
/// 满足 `TrendAnalysisValidator` 的明确性校验——模型只提交本次开放模块,
/// 改不了复用部分,不能让旧数据把新报告整份拒批。
///
/// 只作用于「从基线复用」的数据;模型本次提交的新数据照常走校验,
/// 不会被这里静默修补。
enum TrendBaselineContractPatch {
    static func horizons(_ values: [TrendHorizonView]) -> [TrendHorizonView] {
        values.map(horizon)
    }

    static func horizon(_ value: TrendHorizonView) -> TrendHorizonView {
        TrendHorizonView(
            horizon: value.horizon,
            direction: value.direction,
            confidence: value.confidence,
            rationale: patchedRationale(
                value.rationale,
                direction: value.direction,
                exemptionReason: value.claimEvidence.exemptionReason
            ),
            whatWouldChange: nonEmptyOrFallback(value.whatWouldChange, counterSignals: value.counterSignals),
            counterSignals: value.counterSignals,
            claimEvidence: value.claimEvidence
        )
    }

    static func markets(_ values: [TrendMarketOutlook]) -> [TrendMarketOutlook] {
        values.map { market in
            TrendMarketOutlook(
                id: market.id,
                name: market.name,
                category: market.category,
                direction: market.direction,
                confidence: market.confidence,
                rationale: patchedRationale(
                    market.rationale,
                    direction: market.direction,
                    exemptionReason: market.claimEvidence.exemptionReason
                ),
                evidenceIDs: market.evidenceIDs,
                counterSignals: market.counterSignals,
                claimEvidence: market.claimEvidence
            )
        }
    }

    static func sectors(_ values: [TrendSectorView]) -> [TrendSectorView] {
        values.map { sector in
            TrendSectorView(
                id: sector.id,
                name: sector.name,
                exposureText: sector.exposureText,
                direction: sector.direction,
                confidence: sector.confidence,
                rationale: patchedRationale(
                    sector.rationale,
                    direction: sector.direction,
                    exemptionReason: sector.claimEvidence.exemptionReason
                ),
                whatWouldChange: nonEmptyOrFallback(sector.whatWouldChange, counterSignals: sector.counterSignals),
                evidenceIDs: sector.evidenceIDs,
                counterSignals: sector.counterSignals,
                claimEvidence: sector.claimEvidence
            )
        }
    }

    static func opportunities(_ values: [TrendOpportunity]) -> [TrendOpportunity] {
        values.map { opportunity in
            TrendOpportunity(
                id: opportunity.id,
                name: opportunity.name,
                category: opportunity.category,
                scope: opportunity.scope,
                direction: opportunity.direction,
                confidence: opportunity.confidence,
                rationale: patchedRationale(
                    opportunity.rationale,
                    direction: opportunity.direction,
                    exemptionReason: opportunity.claimEvidence.exemptionReason
                ),
                whatWouldChange: nonEmptyOrFallback(
                    opportunity.whatWouldChange,
                    counterSignals: opportunity.invalidatingConditions + opportunity.counterSignals
                ),
                triggerConditions: opportunity.triggerConditions,
                invalidatingConditions: opportunity.invalidatingConditions,
                evidenceIDs: opportunity.evidenceIDs,
                counterSignals: opportunity.counterSignals,
                claimEvidence: opportunity.claimEvidence
            )
        }
    }

    static func actions(_ values: [TrendActionCandidate]) -> [TrendActionCandidate] {
        values.map { action in
            TrendActionCandidate(
                id: action.id,
                kind: action.kind,
                title: action.title,
                detail: action.detail,
                targetName: action.targetName,
                confidence: action.confidence,
                whatWouldChange: nonEmptyOrFallback(
                    action.whatWouldChange,
                    counterSignals: action.invalidatingConditions
                ),
                triggerConditions: action.triggerConditions,
                invalidatingConditions: action.invalidatingConditions,
                claimEvidence: action.claimEvidence
            )
        }
    }

    /// 首句缺方向词 → 以 direction 对应的方向词补前缀;
    /// uncertain 无待观察信号 → 以 exemptionReason(或通用兜底)补出口。
    private static func patchedRationale(
        _ rationale: String,
        direction: TrendDirection,
        exemptionReason: String?
    ) -> String {
        var text = rationale
        let headline = TrendVerdictPresentation.split(rationale: text).headline
        if !TrendAnalysisValidator.directionLeadWords.contains(where: headline.contains) {
            let lead = leadWord(for: direction)
            text = text.isEmpty ? "\(lead)。" : "\(lead),\(text)"
        }
        if direction == .uncertain, !text.contains("待观察信号") {
            let reason = exemptionReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let waiting = reason.isEmpty ? "支撑证据恢复" : reason
            text += (text.isEmpty ? "" : " ") + "待观察信号:\(waiting)后重估方向。"
        }
        return text
    }

    private static func nonEmptyOrFallback(_ value: String, counterSignals: [String]) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        for signal in counterSignals {
            let signalTrimmed = signal.trimmingCharacters(in: .whitespacesAndNewlines)
            if !signalTrimmed.isEmpty { return signalTrimmed }
        }
        return "判断依据或证据边界变化时重估。"
    }

    private static func leadWord(for direction: TrendDirection) -> String {
        switch direction {
        case .bullish: return "偏强"
        case .neutralPositive: return "中性偏强"
        case .neutral: return "中性"
        case .neutralNegative: return "中性偏弱"
        case .bearish: return "偏弱"
        case .uncertain: return "暂不明确"
        }
    }
}
