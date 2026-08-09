import Foundation

struct TrendValidationResult: Hashable {
    let isValid: Bool
    let messages: [String]

    static let valid = TrendValidationResult(isValid: true, messages: [])
}

struct TrendAnalysisValidator {
    private let requiredHorizons = Set(TrendHorizon.allCases)
    private let forbiddenTerms = [
        "必须买入",
        "必须卖出",
        "一定上涨",
        "一定卖出",
        "保证上涨",
        "保证收益"
    ]

    func validate(_ report: TrendAnalysisReport, expectedFundCodes: [String] = [], expectedPrivacyMode: TrendPrivacyMode? = nil) -> TrendValidationResult {
        var messages: [String] = []

        let horizonKinds = Set(report.horizons.map(\.horizon))
        if report.horizons.count != requiredHorizons.count || horizonKinds != requiredHorizons {
            messages.append("短中长期趋势必须完整包含 short/medium/long 且各出现一次。")
        }
        for horizon in report.horizons where horizon.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append("短中长期趋势缺少 rationale/判断依据：\(horizon.horizon.rawValue)")
        }
        for horizon in report.horizons where horizon.counterSignals.isEmpty {
            messages.append("短中长期趋势缺少 counterSignals/反证条件：\(horizon.horizon.rawValue)")
        }
        if !report.disclaimer.contains("非投资建议") {
            messages.append("缺少明确的非投资建议声明。")
        }
        let hasExternalResearchEvidence = report.evidence.contains {
            $0.metadata.sourceKind.isExternalResearch
                || $0.id.hasPrefix("official:sec:")
                || $0.id.hasPrefix("web:tavily:")
        }
        if report.externalSignalStatus == .available && !hasExternalResearchEvidence {
            messages.append("externalSignalStatus 为 available 时必须引用本次官方源或联网搜索产生的外部证据。")
        }
        if report.externalSignalStatus != .available && hasExternalResearchEvidence {
            messages.append("报告已经引用官方源或联网搜索证据，externalSignalStatus 应为 available。")
        }

        // 证据账本解析：sectors/marketOutlook/opportunities 引用的 evidenceID 必须都在 report.evidence 中。
        let evidenceIDs = Set(report.evidence.map(\.id))
        for id in report.referencedEvidenceIDs where !evidenceIDs.contains(id) {
            messages.append("引用的证据 ID 不存在：\(id)")
        }

        // confidence 分数范围 0...100。
        for confidence in collectConfidenceScores(report) where confidence.score < 0 || confidence.score > 100 {
            messages.append("confidence score 必须在 0...100 之间：\(confidence.score)")
        }
        if report.schemaVersion >= TrendAnalysisReport.currentSchemaVersion {
            for confidence in collectConfidenceScores(report)
            where confidence.label != confidenceLabel(for: confidence.score) {
                messages.append(
                    "confidence label 必须由 score 派生：\(confidence.score) 应为「\(confidenceLabel(for: confidence.score))」"
                )
            }
            validateSourceStatuses(report, messages: &messages)
            validateClaimEvidence(report, messages: &messages)
            validateDisposition(report, messages: &messages)
        }

        // privacyMode 必须与本次分析快照一致（App 在 submit 阶段已覆盖，这里做防御性校验）。
        if let expectedPrivacyMode, report.privacyMode != expectedPrivacyMode {
            messages.append("privacyMode 必须与本次分析快照一致（\(expectedPrivacyMode.rawValue)）。")
        }

        if report.marketOutlook.isEmpty && report.sectors.isEmpty {
            messages.append("市场视图不能为空：marketOutlook 和 sectors 至少需要一项判断。")
        }

        // marketOutlook（大盘/大类资产）与 sectors（行业板块）互斥：不得出现同名主题。
        let marketNames = Set(report.marketOutlook.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) })
        let sectorNames = Set(report.sectors.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) })
        for name in marketNames.intersection(sectorNames).sorted() where !name.isEmpty {
            messages.append("「\(name)」同时出现在 marketOutlook 与 sectors：两者互斥，指数/大类资产只放 marketOutlook，行业板块只放 sectors，请只保留一处。")
        }

        for sector in report.sectors {
            if sector.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.append("板块缺少 rationale/判断依据：\(sector.name)")
            }
            if sector.counterSignals.isEmpty {
                messages.append("板块缺少 counterSignals/反证条件：\(sector.name)")
            }
        }

        for market in report.marketOutlook {
            if market.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.append("大盘/大类资产缺少 rationale/判断依据：\(market.name)")
            }
            if market.counterSignals.isEmpty {
                messages.append("大盘/大类资产缺少 counterSignals/反证条件：\(market.name)")
            }
        }

        for opportunity in report.opportunities {
            if opportunity.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.append("投资机会缺少 rationale/判断依据：\(opportunity.name)")
            }
            if opportunity.triggerConditions.isEmpty {
                messages.append("投资机会缺少 triggerConditions/触发条件：\(opportunity.name)")
            }
            if opportunity.invalidatingConditions.isEmpty {
                messages.append("投资机会缺少 invalidatingConditions/反证条件：\(opportunity.name)")
            }
            if opportunity.counterSignals.isEmpty {
                messages.append("投资机会缺少 counterSignals/反向信号：\(opportunity.name)")
            }
        }

        for asset in report.keyAssets {
            validate(asset: asset, label: "关键资产", messages: &messages)
        }

        for asset in report.assetTrends {
            validate(asset: asset, label: "已持有基金趋势", messages: &messages)
        }

        let reportedFundCodes = Set(report.assetTrends.compactMap { normalizedCode($0.code) })
        for code in Set(expectedFundCodes.compactMap(normalizedCode)).sorted() where !reportedFundCodes.contains(code) {
            messages.append("已持有基金缺少 assetTrends 趋势分析：\(code)")
        }

        for action in report.actions {
            if action.triggerConditions.isEmpty {
                messages.append("行动候选缺少 trigger/触发条件：\(action.title)")
            }
            if action.invalidatingConditions.isEmpty {
                messages.append("行动候选缺少 invalidating/反证条件：\(action.title)")
            }
        }

        let portfolioParts = [report.portfolio.headline, report.portfolio.summary, report.disclaimer]
        let actionParts = report.actions.flatMap { [$0.title, $0.detail] }
        let horizonParts = report.horizons.flatMap { [$0.rationale] + $0.counterSignals }
        let sectorParts = report.sectors.flatMap { [$0.rationale] + $0.counterSignals }
        let marketParts = report.marketOutlook.flatMap { [$0.rationale] + $0.counterSignals }
        let opportunityParts = report.opportunities.flatMap {
            [$0.rationale] + $0.triggerConditions + $0.invalidatingConditions + $0.counterSignals
        }
        let assetParts = (report.keyAssets + report.assetTrends).flatMap { [$0.impactText, $0.rationale] + $0.counterSignals }
        let searchableParts = portfolioParts + actionParts + horizonParts + sectorParts + marketParts + opportunityParts + assetParts
        let searchableText = searchableParts.joined(separator: "\n")
        for term in forbiddenTerms where searchableText.contains(term) {
            messages.append("包含强制或 absolute 表述：\(term)")
        }

        return messages.isEmpty ? .valid : TrendValidationResult(isValid: false, messages: messages)
    }

    private func validate(asset: TrendAssetView, label: String, messages: inout [String]) {
            if asset.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.append("\(label)缺少 rationale/判断依据：\(asset.name)")
            }
            if asset.counterSignals.isEmpty {
                messages.append("\(label)缺少 counterSignals/反证条件：\(asset.name)")
            }
            for horizon in asset.horizons {
                if horizon.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    messages.append("\(label)周期缺少 rationale/判断依据：\(asset.name) \(horizon.horizon.rawValue)")
                }
                if horizon.counterSignals.isEmpty {
                    messages.append("\(label)周期缺少 counterSignals/反证条件：\(asset.name) \(horizon.horizon.rawValue)")
                }
            }
    }

    private func normalizedCode(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.uppercased().filter { $0.isLetter || $0.isNumber }
        return normalized.isEmpty ? nil : normalized
    }

    /// 报告里所有 TrendConfidence，用于范围校验。
    private func collectConfidenceScores(_ report: TrendAnalysisReport) -> [TrendConfidence] {
        var scores: [TrendConfidence] = []
        scores.append(contentsOf: report.horizons.map(\.confidence))
        scores.append(contentsOf: report.sectors.map(\.confidence))
        scores.append(contentsOf: report.marketOutlook.map(\.confidence))
        scores.append(contentsOf: report.opportunities.map(\.confidence))
        scores.append(contentsOf: report.actions.map(\.confidence))
        scores.append(contentsOf: (report.keyAssets + report.assetTrends).flatMap(\.horizons).map(\.confidence))
        return scores
    }

    private func validateSourceStatuses(
        _ report: TrendAnalysisReport,
        messages: inout [String]
    ) {
        let grouped = Dictionary(grouping: report.sourceStatuses, by: \.source)
        for source in TrendDataSource.allCases {
            let values = grouped[source] ?? []
            if values.count != 1 {
                messages.append("sourceStatuses 必须且只能包含一条 \(source.rawValue) 状态")
            }
        }
    }

    private func validateClaimEvidence(
        _ report: TrendAnalysisReport,
        messages: inout [String]
    ) {
        let policy = TrendClaimEvidencePolicy()
        let evidenceByID = Dictionary(
            report.evidence.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        messages.append(contentsOf: policy.validateClaim(
            label: "组合结论",
            direction: nil,
            evidence: report.portfolio.claimEvidence,
            evidenceByID: evidenceByID
        ))
        for horizon in report.horizons {
            messages.append(contentsOf: policy.validateClaim(
                label: "\(horizon.horizon.rawValue) 周期趋势",
                direction: horizon.direction,
                evidence: horizon.claimEvidence,
                evidenceByID: evidenceByID
            ))
        }
        for market in report.marketOutlook {
            messages.append(contentsOf: policy.validateClaim(
                label: "大盘/大类资产「\(market.name)」",
                direction: market.direction,
                evidence: market.claimEvidence,
                evidenceByID: evidenceByID,
                entityName: market.name
            ))
        }
        for sector in report.sectors {
            messages.append(contentsOf: policy.validateClaim(
                label: "板块「\(sector.name)」",
                direction: sector.direction,
                evidence: sector.claimEvidence,
                evidenceByID: evidenceByID,
                sectorKey: sector.name
            ))
        }
        for opportunity in report.opportunities {
            messages.append(contentsOf: policy.validateClaim(
                label: "机会「\(opportunity.name)」",
                direction: opportunity.direction,
                evidence: opportunity.claimEvidence,
                evidenceByID: evidenceByID,
                entityName: opportunity.name
            ))
        }
        for asset in report.keyAssets + report.assetTrends {
            messages.append(contentsOf: policy.validateClaim(
                label: "资产「\(asset.name)」",
                direction: nil,
                evidence: asset.claimEvidence,
                evidenceByID: evidenceByID,
                entityCode: asset.code,
                entityName: asset.name,
                sectorKey: asset.sector
            ))
            for horizon in asset.horizons {
                messages.append(contentsOf: policy.validateClaim(
                    label: "资产「\(asset.name)」\(horizon.horizon.rawValue) 周期",
                    direction: horizon.direction,
                    evidence: horizon.claimEvidence,
                    evidenceByID: evidenceByID,
                    entityCode: asset.code,
                    entityName: asset.name,
                    sectorKey: asset.sector
                ))
            }
        }
        for action in report.actions {
            messages.append(contentsOf: policy.validateAction(
                action,
                evidenceByID: evidenceByID
            ))
        }
    }

    private func validateDisposition(
        _ report: TrendAnalysisReport,
        messages: inout [String]
    ) {
        let hasAllocationAction = report.actions.contains {
            $0.kind.evidencePolicyLevel == .allocationReview
        }
        switch report.disposition {
        case .actionable:
            if !hasAllocationAction {
                messages.append("actionable 报告必须至少包含一条通过证据门槛的 allocationReview 行动")
            }
        case .analysisOnly:
            if hasAllocationAction {
                messages.append("analysisOnly 报告不能包含 allocationReview 行动")
            }
        case .insufficientEvidence:
            if !report.actions.isEmpty {
                messages.append("insufficientEvidence 报告必须禁用全部行动候选")
            }
            if report.horizons.first(where: { $0.horizon == .short })?.direction != .uncertain {
                messages.append("insufficientEvidence 报告的 short 周期必须降为 uncertain")
            }
            for asset in report.keyAssets + report.assetTrends {
                if let short = asset.horizons.first(where: { $0.horizon == .short }),
                   short.direction != .uncertain {
                    messages.append("insufficientEvidence 报告的资产短期方向必须降为 uncertain：\(asset.name)")
                }
            }
        }
    }

    private func confidenceLabel(for score: Int) -> String {
        if score >= 75 { return "高" }
        if score >= 45 { return "中" }
        return "低"
    }
}
