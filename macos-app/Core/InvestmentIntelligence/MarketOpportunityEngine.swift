import Foundation

/// 将“组合内板块判断”和“独立全市场机会”合并成一张板块决策雷达。
///
/// - 已持有板块：只来自 report.sectors 的投资板块结论；F10 宽行业不直接生成卡片。
/// - 未持有机会：只来自 scope=marketWide 的 opportunities，不能由组合缺口推导。
/// - 高等级机会：除模型置信度外，还要求多个独立外部来源和至少一个权威来源。
enum MarketOpportunityEngine {
    static func analyze(report: TrendAnalysisReport?) -> MarketOpportunityAnalysis? {
        guard let report else { return nil }

        let evidenceByID = Dictionary(
            report.evidence.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let marketWide = report.opportunities.filter { $0.scope == .marketWide }
        let sectorOpportunities = marketWide.filter {
            dimension(for: $0.category) == .marketSector
        }
        let heldSectors = report.sectors.compactMap { sectorView in
            makeHeldSectorSignal(
                sectorView: sectorView,
                opportunity: bestMatchingOpportunity(sectorView.name, in: sectorOpportunities),
                evidenceByID: evidenceByID
            )
        }
        .sorted(by: signalSort)

        let heldKeys = Set(report.sectors.map { normalized($0.name) })
        let unheldSectorOpportunities = sectorOpportunities.compactMap { opportunity -> InvestmentDirectionSignal? in
            guard !heldKeys.contains(normalized(opportunity.name)) else { return nil }
            return makeMarketOpportunitySignal(
                opportunity,
                dimension: .marketSector,
                evidenceByID: evidenceByID
            )
        }
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

        guard !assetClasses.isEmpty
                || !markets.isEmpty
                || !heldSectors.isEmpty
                || !unheldSectorOpportunities.isEmpty else {
            return nil
        }

        return MarketOpportunityAnalysis(
            assetClasses: assetClasses,
            markets: markets,
            heldSectors: heldSectors,
            marketSectorOpportunities: unheldSectorOpportunities,
            marketScanCompleted: marketWide.isEmpty == false,
            generatedAt: report.generatedAt
        )
    }

    private static func makeHeldSectorSignal(
        sectorView: TrendSectorView,
        opportunity: TrendOpportunity?,
        evidenceByID: [String: TrendEvidence]
    ) -> InvestmentDirectionSignal? {
        let evidence = resolvedEvidence(
            ids: evidenceIDs(sectorView) + (opportunity.map(evidenceIDs) ?? []),
            evidenceByID: evidenceByID
        )
        // 没有可追溯依据就不生成卡片，避免用默认文案制造“貌似有结论”的假内容。
        guard !evidence.isEmpty else { return nil }

        let evidenceQuality = evidenceQuality(for: evidence)
        let direction = combinedDirection(
            portfolioDirection: sectorView.direction,
            marketDirection: opportunity?.direction
        )
        let confidence = combinedConfidence(
            portfolio: sectorView.confidence,
            market: opportunity?.confidence,
            directionsConflict: directionsConflict(sectorView.direction, opportunity?.direction)
        )
        let recommendation = heldRecommendation(
            direction: direction,
            confidence: confidence,
            evidenceCount: evidence.count,
            directionsConflict: directionsConflict(sectorView.direction, opportunity?.direction)
        )
        let rationale = joinedRationale(
            portfolio: sectorView.rationale,
            market: opportunity?.rationale,
            fallback: sectorView.rationale
        )

        return InvestmentDirectionSignal(
            id: "held-sector:\(normalized(sectorView.id))",
            name: sectorView.name,
            dimension: .heldSector,
            recommendation: recommendation,
            direction: direction,
            confidence: confidence,
            rationale: rationale,
            portfolioExposureText: nonEmpty(sectorView.exposureText),
            triggerConditions: opportunity?.triggerConditions ?? [],
            invalidatingConditions: opportunity?.invalidatingConditions ?? [],
            counterSignals: unique(
                sectorView.counterSignals + (opportunity?.counterSignals ?? [])
            ),
            evidence: evidence,
            independentExternalSourceCount: evidenceQuality.independentExternalSourceCount,
            hasAuthoritativeEvidence: evidenceQuality.hasAuthoritativeEvidence
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
        let recommendation: InvestmentDirectionRecommendation
        if dimension == .marketSector {
            recommendation = marketSectorRecommendation(
                opportunity: opportunity,
                quality: quality
            )
        } else {
            recommendation = marketContextRecommendation(direction: opportunity.direction)
        }

        return InvestmentDirectionSignal(
            id: opportunity.id,
            name: opportunity.name,
            dimension: dimension,
            recommendation: recommendation,
            direction: opportunity.direction,
            confidence: opportunity.confidence.appNormalized,
            rationale: opportunity.rationale,
            portfolioExposureText: nil,
            triggerConditions: opportunity.triggerConditions,
            invalidatingConditions: opportunity.invalidatingConditions,
            counterSignals: opportunity.counterSignals,
            evidence: evidence,
            independentExternalSourceCount: quality.independentExternalSourceCount,
            hasAuthoritativeEvidence: quality.hasAuthoritativeEvidence
        )
    }

    private static func heldRecommendation(
        direction: TrendDirection,
        confidence: TrendConfidence,
        evidenceCount: Int,
        directionsConflict: Bool
    ) -> InvestmentDirectionRecommendation {
        guard !directionsConflict, evidenceCount > 0 else { return .holdAndReview }
        switch direction {
        case .bullish, .neutralPositive:
            return confidence.normalizedScore >= 65 ? .considerAdd : .holdAndReview
        case .bearish, .neutralNegative:
            return confidence.normalizedScore >= 60 ? .considerReduce : .holdAndReview
        case .neutral, .uncertain:
            return .holdAndReview
        }
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
        case .bullish, .neutralPositive: .marketTailwind
        case .bearish, .neutralNegative: .marketHeadwind
        case .neutral, .uncertain: .marketNeutral
        }
    }

    private static func bestMatchingOpportunity(
        _ name: String,
        in opportunities: [TrendOpportunity]
    ) -> TrendOpportunity? {
        opportunities.first { namesMatch(name, $0.name) }
    }

    private static func combinedDirection(
        portfolioDirection: TrendDirection?,
        marketDirection: TrendDirection?
    ) -> TrendDirection {
        guard !directionsConflict(portfolioDirection, marketDirection) else { return .uncertain }
        return portfolioDirection ?? marketDirection ?? .uncertain
    }

    private static func combinedConfidence(
        portfolio: TrendConfidence,
        market: TrendConfidence?,
        directionsConflict: Bool
    ) -> TrendConfidence {
        if directionsConflict {
            return TrendConfidence(score: 35, label: "低")
        }
        let values = [portfolio.normalizedScore] + [market?.normalizedScore].compactMap { $0 }
        let score = Int(Double(values.reduce(0, +)) / Double(values.count))
        return TrendConfidence(score: score, label: TrendConfidence.label(for: score))
    }

    private static func directionsConflict(
        _ lhs: TrendDirection?,
        _ rhs: TrendDirection?
    ) -> Bool {
        guard let lhs, let rhs else { return false }
        let positive: Set<TrendDirection> = [.bullish, .neutralPositive]
        let negative: Set<TrendDirection> = [.bearish, .neutralNegative]
        return (positive.contains(lhs) && negative.contains(rhs))
            || (negative.contains(lhs) && positive.contains(rhs))
    }

    private static func evidenceIDs(_ sector: TrendSectorView) -> [String] {
        unique(sector.evidenceIDs + sector.claimEvidence.allEvidenceIDs)
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

    private static func joinedRationale(
        portfolio: String?,
        market: String?,
        fallback: String
    ) -> String {
        let portfolioText = portfolio?.trimmingCharacters(in: .whitespacesAndNewlines)
        let marketText = market?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (portfolioText?.isEmpty == false ? portfolioText : nil,
                marketText?.isEmpty == false ? marketText : nil) {
        case (.some(let portfolio), .some(let market)):
            return "组合判断：\(portfolio) 全市场扫描：\(market)"
        case (.some(let portfolio), nil):
            return portfolio
        case (nil, .some(let market)):
            return market
        case (nil, nil):
            return fallback
        }
    }

    private static func dimension(for category: String) -> InvestmentDirectionDimension? {
        switch normalized(category) {
        case "assetclass", "大类资产", "资产大类": .assetClass
        case "index", "market", "broadmarket", "大盘", "指数", "市场": .broadMarket
        case "sector", "industry", "theme", "板块", "行业", "主题": .marketSector
        default: nil
        }
    }

    private static func namesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = normalized(lhs)
        let rhs = normalized(rhs)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return lhs == rhs || lhs.contains(rhs) || rhs.contains(lhs)
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

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
