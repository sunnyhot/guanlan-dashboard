import Foundation

// MARK: - Dashboard Projector（ArtifactQueryService 聚合扩展，产品重构方案 §7.1）
//
// 只做「读 + 解释」：现有 typed fetch + DecisionNarrator / ResearchNarrator，
// 不重跑 planner / factor / comparison；不重决。纪律：
// - fail-closed：损坏行抛错，不静默跳过伪装正常
// - 有效性过滤：盘中 / 决策报告的内嵌 target 必须能在用户意图历史中解析
//   （resolvableTargetIDs）——旧「维持当前配置」自复制 Target 的产物保留
//   在历史（审计），不进入有效结论层
// - DiscoveryCandidate / HistoryItem 等转 DTO 时只做形态映射，不产生新决策语义

extension ArtifactQueryService {

    /// 聚合投资智能主页面快照（UI 唯一读面）。
    func dashboardSnapshot(
        userMaterials: IntelligenceDashboardUserMaterials,
        now: Date = Date()
    ) throws -> InvestmentIntelligenceDashboardSnapshot {
        let allocation = Self.allocationSummary(from: userMaterials)
        let intraday = try latestValidIntradaySummary(
            resolvableTargetIDs: userMaterials.resolvableTargetIDs, now: now)
        let discovery = try latestDiscoverySummary(now: now)
        let readiness = Self.readinessSummary(
            from: userMaterials, marketCoverage: discovery?.coverage)
        let research = try latestResearchSummary(now: now)
        let history = try historyItems(
            limit: 20,
            resolvableTargetIDs: userMaterials.resolvableTargetIDs, now: now)
        let headline = Self.headline(
            readiness: readiness, intraday: intraday, allocation: allocation, now: now)

        return InvestmentIntelligenceDashboardSnapshot(
            generatedAt: now,
            headline: headline,
            allocation: allocation,
            readiness: readiness,
            intraday: intraday,
            discovery: discovery,
            research: research,
            history: history
        )
    }

    // MARK: - 各段投影（private static 纯函数——同输入同快照，可 golden 测试）

    private static func allocationSummary(
        from materials: IntelligenceDashboardUserMaterials
    ) -> InvestmentIntelligenceDashboardSnapshot.AllocationSummary {
        let target = materials.currentTarget
        let weights = materials.currentClassWeights ?? [:]
        let rows = AssetClass.allCases.map { assetClass -> InvestmentIntelligenceDashboardSnapshot.AllocationSummary.Row in
            let current = weights[assetClass]
            let targetWeight = target?.targetWeight(for: assetClass)?.value ?? Decimal.zero
            let deviation: Decimal?
            if let current, target != nil {
                deviation = current - targetWeight
            } else {
                deviation = nil
            }
            return .init(
                assetClass: assetClass,
                currentWeight: current,
                targetWeight: targetWeight,
                deviation: deviation)
        }
        return .init(
            targetConfigured: target != nil,
            targetRecordedAt: target?.createdAt,
            rows: rows)
    }

    private static func readinessSummary(
        from materials: IntelligenceDashboardUserMaterials,
        marketCoverage: InvestmentIntelligenceDashboardSnapshot.ReadinessSummary.MarketCoverage?
    ) -> InvestmentIntelligenceDashboardSnapshot.ReadinessSummary {
        let blocker: InvestmentIntelligenceDashboardSnapshot.ReadinessSummary.Blocker?
        if materials.currentTarget == nil {
            blocker = .missingTarget
        } else if !materials.unresolvedSubjects.isEmpty {
            blocker = .unclassifiedHoldings(materials.unresolvedSubjects)
        } else if let staleAsOf = materials.valuationStaleAsOf {
            blocker = .staleValuation(latestAsOf: staleAsOf)
        } else {
            blocker = nil
        }
        return .init(
            blocker: blocker,
            marketCoverage: marketCoverage,
            providerConfigured: materials.providerConfigured)
    }

    private static func headline(
        readiness: InvestmentIntelligenceDashboardSnapshot.ReadinessSummary,
        intraday: InvestmentIntelligenceDashboardSnapshot.IntradaySummary?,
        allocation: InvestmentIntelligenceDashboardSnapshot.AllocationSummary,
        now: Date
    ) -> InvestmentIntelligenceDashboardSnapshot.Headline {
        let status: InvestmentIntelligenceDashboardSnapshot.Headline.Status
        var validityNote: String?
        if readiness.blocker != nil {
            status = .notReady
        } else if let intraday {
            switch (intraday.decision, intraday.validity) {
            case (.executeRebalance, .current):
                status = .rebalanceSuggested
            case (.hold, .current):
                status = .holdConfigured
            case (_, .expired):
                status = .undecidable
            }
            validityNote = IntelligencePresentationFormatter.intradayValidityLabel(intraday.validity)
        } else {
            status = .undecidable
        }

        let reason = IntelligencePresentationFormatter.headlineReason(
            status: status,
            blocker: readiness.blocker,
            intraday: intraday,
            maxDeviation: IntelligencePresentationFormatter.maxDeviationText(allocation))
        let dataAsOf = intraday?.producedAt ?? allocation.targetRecordedAt

        return .init(
            status: status,
            reason: reason,
            validityNote: validityNote,
            dataAsOf: dataAsOf)
    }

    // MARK: - 盘中（有效性过滤：target 必须可解析到用户意图历史）

    private func latestValidIntradaySummary(
        resolvableTargetIDs: Set<String>, now: Date
    ) throws -> InvestmentIntelligenceDashboardSnapshot.IntradaySummary? {
        // includeInvalid = true：过期报告也要展示（标「已过期」+ 重新评估），
        // 但 target 不可解析的旧产物不进入结论层
        let reports = try latestIntradayReports(limit: 20, now: now, includeInvalid: true)
        guard let report = reports.first(where: { report in
            guard let targetID = report.target?.id.rawValue else { return false }
            return resolvableTargetIDs.contains(targetID)
        }) else { return nil }

        let moves = (report.plan?.actions ?? []).map { planned in
            InvestmentIntelligenceDashboardSnapshot.IntradaySummary.PlannedMove(
                subjectKey: planned.action.subjectKey,
                direction: planned.action.deltaWeight.value >= 0 ? .increase : .decrease,
                weightChange: planned.action.deltaWeight.value,
                provenanceKind: {
                    switch planned.provenance {
                    case .targetRebalance: return .targetFollow
                    case .remediation: return .remediation
                    case .userDirective: return .userDirective
                    }
                }())
        }
        return InvestmentIntelligenceDashboardSnapshot.IntradaySummary(
            decision: report.decision == .executeRebalance ? .executeRebalance : .hold,
            holdReasons: report.holdReasons,
            moves: moves,
            validity: report.validityPolicy.isStillValid(at: now) ? .current : .expired,
            producedAt: report.producedAt,
            artifactID: report.id.rawValue,
            targetID: report.target?.id.rawValue)
    }

    // MARK: - 市场发现

    /// 覆盖充分阈值：已覆盖标的数 ≥ 全部 universe 的一半。低于该值归为
    /// 「数据不足」（不显示「暂无机会」误导——方案 §8.5 的两态区分）。
    static let discoveryCoverageSufficiencyRatio = Decimal(string: "0.5")!

    private func latestDiscoverySummary(
        now: Date
    ) throws -> InvestmentIntelligenceDashboardSnapshot.DiscoverySummary? {
        guard let report = try latestMarketDiscoveryReports(limit: 1, now: now).first else {
            return nil
        }
        let coverage = coverage(from: report)
        let state: InvestmentIntelligenceDashboardSnapshot.DiscoverySummary.State
        if !report.candidates.isEmpty {
            state = .hasCandidates
        } else if isCoverageSufficient(coverage) {
            state = .noCandidates
        } else {
            state = .insufficientData
        }
        let top = report.candidates
            .sorted { $0.rank < $1.rank }
            .prefix(5)
            .map { candidate in
                InvestmentIntelligenceDashboardSnapshot.DiscoverySummary.Candidate(
                    rank: candidate.rank,
                    name: candidate.displayName,
                    score: candidate.score,
                    factorsSummary: Self.factorsSummary(candidate.metrics))
            }
        return InvestmentIntelligenceDashboardSnapshot.DiscoverySummary(
            state: state,
            topCandidates: Array(top),
            coverage: coverage,
            producedAt: report.producedAt)
    }

    private func coverage(
        from report: MarketDiscoveryReport
    ) -> InvestmentIntelligenceDashboardSnapshot.ReadinessSummary.MarketCoverage {
        .init(
            covered: report.candidates.count,
            total: report.candidates.count + report.coverageGaps.count)
    }

    private func isCoverageSufficient(
        _ coverage: InvestmentIntelligenceDashboardSnapshot.ReadinessSummary.MarketCoverage
    ) -> Bool {
        // 无缺口 = 全部参与排名（0 候选是「真无过阈标的」，不是缺数据）
        guard coverage.total > 0 else { return true }
        let ratio = Decimal(coverage.covered) / Decimal(coverage.total)
        return ratio >= Self.discoveryCoverageSufficiencyRatio
    }

    /// metric 键前缀 → 人话因子方向（|值| 最大的前两个）。
    private static func factorsSummary(_ metrics: [String: Decimal]) -> String {
        let nameByKeyPrefix: [(String, String)] = [
            ("momentum", "动量"), ("trend", "趋势"),
            ("volatility", "波动"), ("drawdown", "回撤"),
        ]
        let parts = metrics
            .sorted {
                abs($0.value) == abs($1.value)
                    ? $0.key < $1.key : abs($0.value) > abs($1.value)
            }
            .prefix(2)
            .compactMap { key, value -> String? in
                guard let name = nameByKeyPrefix.first(where: { key.hasPrefix($0.0) })?.1 else {
                    return nil
                }
                return "\(name) \(value >= 0 ? "↑" : "↓")"
            }
        return parts.joined(separator: " · ")
    }

    // MARK: - 组合研究（Narrator 只解释）

    private func latestResearchSummary(
        now: Date
    ) throws -> InvestmentIntelligenceDashboardSnapshot.ResearchSummary? {
        let subject = CanonicalRef.fundShareClass(
            FundShareClassID(rawValue: "portfolio_live"))
        let summaries = try latestPortfolioDecisions(limit: 1, now: now)
        var narrativeHeadline = "尚无组合研究结论"
        var portfolioStatement = ""
        var topSignals: [String] = []
        var evidenceCount = 0
        var signalCount = 0
        var producedAt: Date?

        if let summary = summaries.first {
            producedAt = summary.producedAt
            signalCount = summary.signalCount
            if let artifact = try portfolioDecision(id: summary.artifactID) {
                let narrative = DecisionNarrator().narrate(artifact)
                narrativeHeadline = narrative.headline
            }
        }

        let theses = try repository.theses(kind: .portfolio, subject: subject)
        let signals = try repository.signals(subject: subject)
        if let portfolioThesis = theses.first {
            evidenceCount = portfolioThesis.supportingEvidenceIDs.count
            if !portfolioThesis.statement.isEmpty {
                portfolioStatement = portfolioThesis.statement
            }
        }
        let researchNarrative = ResearchNarrator().narrate(theses: theses, signals: signals)
        if producedAt == nil {
            producedAt = theses.first?.createdAt
        }
        // 研究故事优先用 portfolio thesis 存在时的 ResearchNarrator headline
        if !theses.isEmpty {
            narrativeHeadline = researchNarrative.headline
        }
        topSignals = Array(researchNarrative.signalDigest.prefix(3))

        return InvestmentIntelligenceDashboardSnapshot.ResearchSummary(
            narrativeHeadline: narrativeHeadline,
            portfolioStatement: portfolioStatement,
            topSignals: topSignals,
            evidenceCount: evidenceCount,
            signalCount: signalCount,
            producedAt: producedAt)
    }

    // MARK: - 最近记录（跨 kind 时间倒序）

    private func historyItems(
        limit: Int,
        resolvableTargetIDs: Set<String>,
        now: Date
    ) throws -> [InvestmentIntelligenceDashboardSnapshot.HistoryItem] {
        var items: [InvestmentIntelligenceDashboardSnapshot.HistoryItem] = []

        let intradayReports = try latestIntradayReports(
            limit: limit, now: now, includeInvalid: true)
        for report in intradayReports {
            let targetResolvable = report.target.map {
                resolvableTargetIDs.contains($0.id.rawValue)
            } ?? false
            items.append(.init(
                kind: .intraday,
                conclusionText: report.decision == .executeRebalance
                    ? "建议调整（\(report.plan?.actions.count ?? 0) 条动作）"
                    : "持有不动",
                producedAt: report.producedAt,
                isValid: report.validityPolicy.isStillValid(at: now),
                artifactID: report.id.rawValue,
                targetResolvable: targetResolvable))
        }

        for summary in try latestPortfolioDecisions(limit: limit, now: now) {
            let targetResolvable = (try portfolioDecision(id: summary.artifactID))
                .flatMap { $0.target }
                .map { resolvableTargetIDs.contains($0.id.rawValue) } ?? false
            items.append(.init(
                kind: .decision,
                conclusionText: summary.admissiblePlans.count > 1
                    ? "多方案待裁决" : "已产出决策方案",
                producedAt: summary.producedAt,
                isValid: summary.isStillValid,
                artifactID: summary.artifactID,
                targetResolvable: targetResolvable))
        }

        for report in try latestMarketDiscoveryReports(limit: limit, now: now) {
            items.append(.init(
                kind: .discovery,
                conclusionText: report.candidates.isEmpty
                    ? "无候选（缺口 \(report.coverageGaps.count)）"
                    : "筛出 \(report.candidates.count) 个候选",
                producedAt: report.producedAt,
                isValid: report.validityPolicy.isStillValid(at: now),
                artifactID: report.id.rawValue,
                targetResolvable: true))
        }

        return Array(
            items.sorted { $0.producedAt > $1.producedAt }
                .prefix(limit))
    }
}
