import Foundation

/// 将独立全市场研究报告投影为机会雷达。
///
/// 只消费 `scope = marketWide` 的机会，不读取组合板块、组合权重或持仓名称。
/// 高等级机会除模型置信度外，还要求多个独立外部来源和至少一个权威来源。
enum MarketOpportunityEngine {
    static func analyze(
        report: TrendAnalysisReport?,
        generatedAt: String? = nil
    ) -> MarketOpportunityAnalysis? {
        guard let report else { return nil }

        let evidenceByID = Dictionary(
            report.evidence.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let marketWide = report.opportunities.filter { $0.scope == .marketWide }

        let sectorOpportunities = marketWide.compactMap { opportunity -> InvestmentDirectionSignal? in
            guard dimension(for: opportunity.category) == .marketSector else { return nil }
            return makeMarketOpportunitySignal(
                opportunity,
                dimension: .marketSector,
                evidenceByID: evidenceByID
            )
        }
        .deduplicatedByNormalizedName()
        .sorted(by: signalSort)

        let assetClasses = marketWide.compactMap { opportunity -> InvestmentDirectionSignal? in
            guard dimension(for: opportunity.category) == .assetClass else { return nil }
            return makeMarketOpportunitySignal(
                opportunity,
                dimension: .assetClass,
                evidenceByID: evidenceByID
            )
        }
        .deduplicatedByNormalizedName()
        .sorted(by: signalSort)

        let markets = marketWide.compactMap { opportunity -> InvestmentDirectionSignal? in
            guard dimension(for: opportunity.category) == .broadMarket else { return nil }
            return makeMarketOpportunitySignal(
                opportunity,
                dimension: .broadMarket,
                evidenceByID: evidenceByID
            )
        }
        .deduplicatedByNormalizedName()
        .sorted(by: signalSort)

        guard !assetClasses.isEmpty || !markets.isEmpty || !sectorOpportunities.isEmpty else {
            return nil
        }

        return MarketOpportunityAnalysis(
            assetClasses: assetClasses,
            markets: markets,
            marketSectorOpportunities: sectorOpportunities,
            marketScanCompleted: !marketWide.isEmpty,
            generatedAt: generatedAt ?? report.generatedAt
        )
    }

    private static func makeMarketOpportunitySignal(
        _ opportunity: TrendOpportunity,
        dimension: InvestmentDirectionDimension,
        evidenceByID: [String: TrendEvidence]
    ) -> InvestmentDirectionSignal {
        let evidence = resolvedEvidence(
            ids: evidenceIDs(opportunity),
            evidenceByID: evidenceByID
        )
        let quality = evidenceQuality(for: evidence)
        let recommendation = dimension == .marketSector
            ? marketSectorRecommendation(opportunity: opportunity, quality: quality)
            : marketContextRecommendation(direction: opportunity.direction)

        return InvestmentDirectionSignal(
            id: opportunity.id,
            name: opportunity.name,
            dimension: dimension,
            recommendation: recommendation,
            direction: opportunity.direction,
            confidence: opportunity.confidence.appNormalized,
            rationale: opportunity.rationale,
            triggerConditions: opportunity.triggerConditions,
            invalidatingConditions: opportunity.invalidatingConditions,
            counterSignals: opportunity.counterSignals,
            evidence: evidence,
            independentExternalSourceCount: quality.independentExternalSourceCount,
            hasAuthoritativeEvidence: quality.hasAuthoritativeEvidence
        )
    }

    private static func marketSectorRecommendation(
        opportunity: TrendOpportunity,
        quality: EvidenceQuality
    ) -> InvestmentDirectionRecommendation {
        let isPositive = [.bullish, .neutralPositive].contains(opportunity.direction)
        if opportunity.direction == .bullish,
           opportunity.confidence.normalizedScore >= 75,
           quality.independentExternalSourceCount >= 2,
           quality.hasAuthoritativeEvidence {
            return .considerBuying
        }
        if isPositive,
           opportunity.confidence.normalizedScore >= 60,
           quality.independentExternalSourceCount >= 1 {
            return .keyOpportunity
        }
        return .startWatching
    }

    private static func marketContextRecommendation(
        direction: TrendDirection
    ) -> InvestmentDirectionRecommendation {
        switch direction {
        case .bullish, .neutralPositive:
            .marketTailwind
        case .bearish, .neutralNegative:
            .marketHeadwind
        case .neutral, .uncertain:
            .marketNeutral
        }
    }

    private static func evidenceIDs(_ opportunity: TrendOpportunity) -> [String] {
        unique(opportunity.evidenceIDs + opportunity.claimEvidence.allEvidenceIDs)
    }

    private static func resolvedEvidence(
        ids: [String],
        evidenceByID: [String: TrendEvidence]
    ) -> [TrendEvidence] {
        unique(ids).compactMap { evidenceByID[$0] }
    }

    private static func evidenceQuality(for evidence: [TrendEvidence]) -> EvidenceQuality {
        let external = evidence.filter { $0.metadata.sourceKind.isExternalResearch }
        return EvidenceQuality(
            independentExternalSourceCount: EvidenceIndependencePolicy.independentCount(
                for: external
            ),
            hasAuthoritativeEvidence: external.contains {
                $0.metadata.sourceTier == .primary || $0.metadata.sourceTier == .authoritative
            }
        )
    }

    private static func dimension(for category: String) -> InvestmentDirectionDimension? {
        switch normalized(category) {
        case "assetclass", "大类资产", "资产大类":
            .assetClass
        case "index", "market", "broadmarket", "大盘", "指数", "市场":
            .broadMarket
        case "sector", "industry", "theme", "板块", "行业", "主题":
            .marketSector
        default:
            nil
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    private static func signalSort(
        _ lhs: InvestmentDirectionSignal,
        _ rhs: InvestmentDirectionSignal
    ) -> Bool {
        if lhs.recommendation.priority != rhs.recommendation.priority {
            return lhs.recommendation.priority < rhs.recommendation.priority
        }
        if lhs.confidence.normalizedScore != rhs.confidence.normalizedScore {
            return lhs.confidence.normalizedScore > rhs.confidence.normalizedScore
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private struct EvidenceQuality {
        let independentExternalSourceCount: Int
        let hasAuthoritativeEvidence: Bool
    }
}

private extension Array where Element == InvestmentDirectionSignal {
    func deduplicatedByNormalizedName() -> [InvestmentDirectionSignal] {
        var seen = Set<String>()
        return filter { signal in
            let key = signal.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }
            return !key.isEmpty && seen.insert(key).inserted
        }
    }
}
