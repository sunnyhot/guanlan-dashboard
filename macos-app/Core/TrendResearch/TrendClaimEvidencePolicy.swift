import Foundation

extension TrendActionKind {
    var evidencePolicyLevel: TrendEvidencePolicyLevel {
        switch self {
        case .watch, .waitForConfirmation, .observeInBatches:
            return .informational
        case .pausePlan, .considerIncrease, .considerReduce, .rebalanceReview:
            return .allocationReview
        }
    }
}

extension NextHourGuidanceActionKind {
    var evidencePolicyLevel: TrendEvidencePolicyLevel {
        switch self {
        case .buy, .sell, .buySmall, .reduceSmall:
            return .execution
        case .hold, .watch, .wait, .avoidChasing:
            return .informational
        }
    }
}

struct TrendClaimEvidencePolicy {
    func validateClaim(
        label: String,
        direction: TrendDirection?,
        evidence: TrendClaimEvidence,
        evidenceByID: [String: TrendEvidence],
        entityCode: String? = nil,
        entityName: String? = nil,
        sectorKey: String? = nil
    ) -> [String] {
        var messages: [String] = []
        let missing = Set(evidence.allEvidenceIDs).subtracting(evidenceByID.keys)
        if !missing.isEmpty {
            messages.append("\(label)引用了不存在的证据：\(missing.sorted().joined(separator: "、"))")
        }

        let supporting = Set(evidence.supportingEvidenceIDs)
        let counter = Set(evidence.counterEvidenceIDs)
        let overlap = supporting.intersection(counter)
        if !overlap.isEmpty {
            messages.append("\(label)的支持证据与反向证据不能重复：\(overlap.sorted().joined(separator: "、"))")
        }

        if evidence.supportingEvidenceIDs.isEmpty {
            if direction == .uncertain, evidence.hasStructuredExemption {
                return messages
            }
            messages.append("\(label)缺少 supportingEvidenceIDs；证据不足时必须改为 uncertain 并填写 exemptionReason")
            return messages
        }

        // 非 uncertain 的方向性结论才硬卡证据关联；uncertain（含 App 已降级的）研究结论不硬拒，
        // 由 validateAction 对资金动作单独严卡。
        guard direction != .uncertain else { return messages }
        if lacksAssociatedSupport(
            evidence: evidence,
            evidenceByID: evidenceByID,
            entityCode: entityCode,
            entityName: entityName,
            sectorKey: sectorKey
        ) {
            messages.append("\(label)没有与目标标的或板块关联的支持证据")
        }
        return messages
    }

    /// supporting 证据存在但无一与 claim 的标的/板块关联时返回 true；
    /// supporting 为空或不需要关联时返回 false。供 SubmitTrendReportTool 做降级判断。
    func lacksAssociatedSupport(
        evidence: TrendClaimEvidence,
        evidenceByID: [String: TrendEvidence],
        entityCode: String? = nil,
        entityName: String? = nil,
        sectorKey: String? = nil
    ) -> Bool {
        let supporting = evidence.supportingEvidenceIDs.compactMap { evidenceByID[$0] }
        guard !supporting.isEmpty else { return false }
        let expectsAssociation = [entityCode, entityName, sectorKey].contains {
            guard let value = $0 else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard expectsAssociation else { return false }
        return !supporting.contains {
            $0.metadata.isAssociated(entityCode: entityCode, entityName: entityName, sectorKey: sectorKey)
        }
    }

    func validateAction(
        _ action: TrendActionCandidate,
        evidenceByID: [String: TrendEvidence]
    ) -> [String] {
        var messages = validateClaim(
            label: "行动候选「\(action.title)」",
            direction: nil,
            evidence: action.claimEvidence,
            evidenceByID: evidenceByID,
            entityName: action.targetName
        )
        let supportingEvidence = action.claimEvidence.supportingEvidenceIDs.compactMap {
            evidenceByID[$0]
        }
        if action.targetName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            messages.append("行动必须填写 targetName：\(action.title)")
        }
        let hasPortfolioFact = supportingEvidence.contains {
            $0.metadata.sourceKind == .portfolioSnapshot
                || $0.metadata.sourceKind == .marketQuote
        }
        if !hasPortfolioFact {
            messages.append("行动必须引用目标持仓、净值或行情事实：\(action.title)")
        }

        switch action.kind.evidencePolicyLevel {
        case .informational:
            break

        case .allocationReview:
            let sizingTerms = ["%", "成", "小仓", "分批", "上限", "不超过", "暂停", "停止"]
            if !sizingTerms.contains(where: { action.detail.contains($0) }) {
                messages.append("allocationReview 行动必须说明仓位、分批或暂停边界：\(action.title)")
            }
            let hasResearchEvidence = supportingEvidence.contains {
                switch $0.metadata.sourceKind {
                case .fundDisclosure, .platformSignal, .managerSignal, .webSearch, .marketQuote:
                    return true
                case .portfolioSnapshot, .derived, .unknown:
                    return false
                }
            }
            if !hasResearchEvidence {
                messages.append("allocationReview 行动缺少与建议理由匹配的结构或外部证据：\(action.title)")
            }

        case .execution:
            // 主趋势报告当前不直接生成 execution；下一小时 Agent 使用同一 level，
            // 由其具备行情时效和仓位上下文的 Validator 执行更严格门槛。
            break
        }
        return messages
    }

    func validateExecution(
        actionKind: NextHourGuidanceActionKind,
        targetName: String,
        targetCode: String?,
        instruction: String,
        trigger: String,
        invalidation: String,
        quoteAssessment: TrendQuoteAssessment,
        marketDataIsFresh: Bool,
        webSearchConfigured: Bool,
        evidenceIDs: [String],
        evidenceByID: [String: TrendEvidence],
        relatedEntityCodes: [String] = [],
        relatedEntityNames: [String] = [],
        relatedSectorKeys: [String] = [],
        requiresFundDisclosure: Bool,
        fundDisclosureEvidencePrefix: String?
    ) -> [String] {
        guard actionKind.evidencePolicyLevel == .execution else { return [] }

        var messages: [String] = []
        let sizingTerms = ["%", "成", "小仓", "分批", "份额"]
        if !sizingTerms.contains(where: { instruction.contains($0) }) {
            messages.append("\(targetName) 的买卖 instruction 必须说明比例、小仓或分批方式")
        }
        if trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || invalidation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append("\(targetName) 的买卖动作必须同时提供触发和失效条件")
        }
        if !marketDataIsFresh {
            messages.append("行情不满足盘中时效要求，\(targetName) 只能给出 hold")
        }
        if !quoteAssessment.isFreshForExecution {
            messages.append("\(targetName) 的标的报价不满足对应品种和交易时段的新鲜度策略，只能给出 hold")
        }
        if !webSearchConfigured {
            messages.append("未配置联网搜索，\(targetName) 只能给出 hold")
        }

        let selectedEvidence = evidenceIDs.compactMap { evidenceByID[$0] }
        let hasLocalTargetFact = selectedEvidence.contains {
            ($0.metadata.sourceKind == .portfolioSnapshot
                || $0.metadata.sourceKind == .marketQuote)
                && $0.metadata.isAssociated(
                    entityCode: targetCode,
                    entityName: targetName
                )
        }
        if !hasLocalTargetFact {
            messages.append("\(targetName) 的买卖动作必须引用目标标的本地行情或净值事实")
        }

        let webEvidence = selectedEvidence.filter {
            $0.metadata.sourceKind == .webSearch || $0.id.hasPrefix("web:tavily:")
        }
        if Set(webEvidence.map(\.id)).count < 2 {
            messages.append("\(targetName) 的买卖动作必须引用至少两个最新网页证据")
        }
        let eligiblePublishers = Set(webEvidence.compactMap { item -> String? in
            guard [.primary, .authoritative, .secondary].contains(item.metadata.sourceTier),
                  let publisher = item.metadata.publisherKey,
                  publisher != "unknown" else {
                return nil
            }
            return publisher
        })
        if eligiblePublishers.count < 2 {
            messages.append("\(targetName) 的买卖动作必须引用两个独立且已识别来源的最新网页证据")
        }
        let hasAssociatedWebEvidence = webEvidence.contains { evidence in
            if evidence.metadata.isAssociated(
                entityCode: targetCode,
                entityName: targetName
            ) {
                return true
            }
            if relatedEntityCodes.contains(where: {
                evidence.metadata.isAssociated(entityCode: $0)
            }) {
                return true
            }
            if relatedEntityNames.contains(where: {
                evidence.metadata.isAssociated(entityName: $0)
            }) {
                return true
            }
            return relatedSectorKeys.contains {
                evidence.metadata.isAssociated(sectorKey: $0)
            }
        }
        if !hasAssociatedWebEvidence {
            messages.append("\(targetName) 的网页证据正文未匹配标的、底层证券或行业；research_target 不能代替正文关联")
        }

        if requiresFundDisclosure {
            guard let fundDisclosureEvidencePrefix else {
                messages.append("\(targetName) 缺少该基金的底层持仓披露，只能给出 hold")
                return messages
            }
            if !evidenceIDs.contains(where: { $0.hasPrefix(fundDisclosureEvidencePrefix) }) {
                messages.append("\(targetName) 的买卖动作必须引用对应基金穿透证据")
            }
        }
        return messages
    }
}
