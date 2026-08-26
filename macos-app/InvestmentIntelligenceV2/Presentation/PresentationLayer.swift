import Foundation
import GRDB

// MARK: - Presentation Layer（PRES-1，V2.2 §11 三分）
//
// Presentation 层三分：解释（为什么这个 plan 胜）/ 叙述（研究论点故事）/
// 查询（统一 Artifact 读面）。铁律：
// - **只解释不重决**：Narrator 只消费 artifact 已有的结果层（comparison /
//   decision / blockingUnknowns），不重算 scores、不重跑 planner、不产生
//   任何新的决策语义——Presentation 无决策权（V2.2 §11）
// - **UI 改读 Artifact**：ArtifactQueryService 是 UI 读 V2 产出的唯一入口
//   （typed fetch + fail-closed），View 不直接摸 Repository 查询拼装
// - 全部程序化生成（确定性）：同输入同叙述——Presentation 不调 LLM；
//   LLM 润色若将来引入，只允许作用在文案层，不得改变事实字段

// MARK: - DecisionNarrator（解释「为什么这个 plan 胜」）

/// 决策解释（程序化生成，确定性）。
struct DecisionNarrative: Sendable, Codable, Hashable {
    /// 解释对象 artifact。
    let artifactID: String
    /// 一句话结论（singlePreferred / unresolvedTradeoff 两分支措辞固定）。
    let headline: String
    /// 胜者的支配关系解释（逐 pair；unresolved 时为空）。
    let whyWinner: [String]
    /// 并列 / 不可比的取舍说明（unresolved 时非空）。
    let tradeoffs: [String]
    /// 阻断比较的 unknown criterion（透明记录，不假装不存在）。
    let unknownBlockers: [String]
    /// 研究信号背景（ordinal 叙述；不进数学的溯源说明）。
    let researchContext: String
}

struct DecisionNarrator: Sendable {
    /// 从决策 artifact 生成解释（只读结果层，不重算不重决）。
    func narrate(_ artifact: PortfolioDecisionArtifact) -> DecisionNarrative {
        let winner = artifact.decision.admissiblePlans.sorted().first
        let headline: String
        switch artifact.decision.status {
        case .singlePreferred:
            headline = "方案 \(winner ?? "?") 胜出：在全部非无差异 criterion 上不劣于且至少一项严格优于其他方案"
        case .unresolvedTradeoff:
            headline = "多个方案互不支配（\(artifact.decision.admissiblePlans.sorted().joined(separator: "、"))）——系统不强行择一，交由用户裁决"
        }

        var whyWinner: [String] = []
        if artifact.decision.status == .singlePreferred, let winner {
            for (pairKey, dominance) in artifact.comparison.pairwise.sorted(by: { $0.key < $1.key }) {
                let parts = pairKey.split(separator: "|").map(String.init)
                guard parts.count == 2 else { continue }
                switch dominance {
                case .aDominatesB where parts[0] == winner:
                    whyWinner.append("方案 \(parts[0]) 支配方案 \(parts[1])（全部 criterion 不劣、至少一项严格优于）")
                case .bDominatesA where parts[1] == winner:
                    whyWinner.append("方案 \(parts[1]) 支配方案 \(parts[0])（全部 criterion 不劣、至少一项严格优于）")
                case .incomparable:
                    whyWinner.append("方案 \(parts[0]) 与方案 \(parts[1]) 互不可比（各有优势或差异在无差异带内）")
                default:
                    break
                }
            }
        }

        var tradeoffs: [String] = []
        if artifact.decision.status == .unresolvedTradeoff {
            tradeoffs.append(artifact.decision.explanation)
            for planKey in artifact.decision.admissiblePlans.sorted() {
                let actionCount = artifact.plans[planKey]?.actions.count ?? 0
                tradeoffs.append("可采纳方案 \(planKey)：\(actionCount) 条动作（含完整 provenance，详见 artifact）")
            }
        }

        let signalNote = artifact.signalIDs.isEmpty
            ? "本决策无研究信号引用（纯 cardinal 材料决策）"
            : "引用 \(artifact.signalIDs.count) 条研究信号（ordinal 叙述层，不进 criterion 数学）"

        return DecisionNarrative(
            artifactID: artifact.id.rawValue,
            headline: headline,
            whyWinner: whyWinner,
            tradeoffs: tradeoffs,
            unknownBlockers: artifact.comparison.blockingUnknowns,
            researchContext: signalNote
        )
    }
}

// MARK: - ResearchNarrator（Thesis 叙述）

/// 研究叙述（论点故事线 + 信号摘要，程序化生成）。
struct ResearchNarrative: Sendable, Codable, Hashable {
    /// 组合论点 headline（无 portfolio thesis 时降级说明）。
    let headline: String
    /// 组合论点全文。
    let portfolioStatement: String
    /// 资产论点（主体 → 叙述，确定性排序）。
    let assetStories: [String]
    /// 信号摘要（维度×方向×强度，ordinal 摘要非数值）。
    let signalDigest: [String]
}

struct ResearchNarrator: Sendable {
    /// 从 theses + signals 生成研究叙述（纯拼接，无 LLM）。
    func narrate(
        theses: [ResearchThesis], signals: [InvestmentSignal]
    ) -> ResearchNarrative {
        let portfolioThesis = theses
            .first { $0.kind == .portfolio }
        let assetTheses = theses
            .filter { $0.kind == .asset }
            .sorted { $0.subject.entityIDRawValue < $1.subject.entityIDRawValue }

        let headline: String
        if let portfolioThesis {
            let signalCount = portfolioThesis.linkedSignalIDs.count
            let evidenceCount = portfolioThesis.supportingEvidenceIDs.count
            headline = "组合研究：\(assetTheses.count) 份资产论点、\(signalCount) 条信号、\(evidenceCount) 条证据引用"
        } else {
            headline = "尚无组合级论点（研究未产出或未落库）"
        }

        let assetStories = assetTheses.map { thesis in
            let directionSummary = signals
                .filter { thesis.linkedSignalIDs.contains($0.id) }
                .map { "\($0.dimension.rawValue) \($0.direction.rawValue)" }
                .sorted()
                .joined(separator: "、")
            let signalNote = directionSummary.isEmpty ? "无关联信号" : "关联信号：\(directionSummary)"
            return "【\(thesis.subject.entityIDRawValue)】\(thesis.statement)\n\(signalNote)"
        }

        let signalDigest = signals
            .sorted {
                if $0.subjectCanonical.stableKey != $1.subjectCanonical.stableKey {
                    return $0.subjectCanonical.stableKey < $1.subjectCanonical.stableKey
                }
                return $0.dimension.rawValue < $1.dimension.rawValue
            }
            .map { signal in
                "\(signal.subjectCanonical.entityIDRawValue) · \(signal.dimension.rawValue)：\(signal.direction.rawValue)（\(signal.strength.rawValue)，\(signal.derivedFromEvidenceIDs.count) 条证据）"
            }

        return ResearchNarrative(
            headline: headline,
            portfolioStatement: portfolioThesis?.statement ?? "",
            assetStories: assetStories,
            signalDigest: signalDigest
        )
    }
}

// MARK: - Artifact Query Service（UI 统一读面）

/// V2 artifact 查询的统一入口（UI / CLI 只经此服务读产出，不直接拼
/// Repository 查询；全部 typed fetch，损坏行 fail-closed 抛错）。
struct ArtifactQueryService: Sendable {
    let repository: GRDBRepository

    init(repository: GRDBRepository) {
        self.repository = repository
    }

    /// 可查询的 artifact 种类（与 ArtifactRow kind 常量对齐）。
    enum ArtifactKind: String, Sendable, CaseIterable {
        case portfolioDecision
        case marketDiscovery
        case intradayExecution
        case dailyAttribution

        var rowKind: String {
            switch self {
            case .portfolioDecision: return ArtifactRow.portfolioDecisionV2Kind
            case .marketDiscovery: return ArtifactRow.marketDiscoveryKind
            case .intradayExecution: return ArtifactRow.intradayExecutionKind
            case .dailyAttribution: return ArtifactRow.dailyAttributionKind
            }
        }
    }

    enum QueryError: Error, Equatable, Sendable {
        /// kind 与 id 不匹配（行存在但不是请求的类型）。
        case kindMismatch(requested: String, actual: String)
    }

    // MARK: 点查

    func portfolioDecision(id: String) throws -> PortfolioDecisionArtifact? {
        try repository.portfolioDecision(id: id)
    }

    func marketDiscoveryReport(id: String) throws -> MarketDiscoveryReport? {
        try repository.marketDiscoveryReport(id: id)
    }

    func intradayExecutionReport(id: String) throws -> IntradayExecutionReport? {
        try repository.database.queue.read { db in
            try ArtifactRow.fetchIntradayExecutionReport(id: id, from: db)
        }
    }

    // MARK: 最新列表（producedAt 降序；默认只返回仍有效的产物）

    /// 最新**仍有效**的决策 artifact 概要列表（十六轮审查 P2：昨天的
    /// 过期产物不再冒充「最新」——immutableHistorical 的决策报告恒有效；
    /// untilDependencyChanges 的发现报告默认全部返回,精确失效需依赖
    /// 传播状态,由调用方按 ID 细查）。
    func latestPortfolioDecisions(
        limit: Int = 20, now: Date = Date()
    ) throws -> [PortfolioDecisionSummary] {
        let ids = try latestArtifactIDs(kind: .portfolioDecision, limit: limit)
        return try ids.compactMap { id in
            try repository.portfolioDecision(id: id).map {
                PortfolioDecisionSummary(
                    artifactID: $0.id.rawValue,
                    producedAt: $0.producedAt,
                    status: $0.decision.status.rawValue,
                    admissiblePlans: $0.decision.admissiblePlans.sorted(),
                    signalCount: $0.signalIDs.count,
                    isStillValid: $0.validityPolicy.isStillValid(at: now)
                )
            }
        }
    }

    /// 最新发现报告列表（untilDependencyChanges 粗粒度恒有效——精确实效
    /// 依赖依赖传播状态,列表不假装判断;isStillValid 字段透明携带）。
    func latestMarketDiscoveryReports(
        limit: Int = 10, now: Date = Date()
    ) throws -> [MarketDiscoveryReport] {
        // 分离两层读（latestArtifactIDs 内部各持一次 queue.read——
        // DatabaseQueue 不可重入,嵌套即 crash）
        let ids = try latestArtifactIDs(kind: .marketDiscovery, limit: limit)
        return try repository.database.queue.read { db in
            try ids.compactMap {
                try ArtifactRow.fetchMarketDiscoveryReport(id: $0, from: db)
            }
        }
    }

    /// 最新盘中执行报告列表——**默认只返回当前交易时段仍有效的**（上一
    /// 时段的报告不再冒充最新;需要历史时传 includeInvalid = true）。
    func latestIntradayReports(
        limit: Int = 20, now: Date = Date(), includeInvalid: Bool = false
    ) throws -> [IntradayExecutionReport] {
        let ids = try latestArtifactIDs(kind: .intradayExecution, limit: limit)
        let reports = try repository.database.queue.read { db in
            try ids.compactMap {
                try ArtifactRow.fetchIntradayExecutionReport(id: $0, from: db)
            }
        }
        guard !includeInvalid else { return reports }
        return reports.filter { $0.validityPolicy.isStillValid(at: now) }
    }

    // MARK: 私有

    /// kind + producedAt 降序取前 N 个 artifact id。
    private func latestArtifactIDs(kind: ArtifactKind, limit: Int) throws -> [String] {
        try repository.database.queue.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT id FROM artifacts
                WHERE artifact_kind = ?
                ORDER BY produced_at DESC
                LIMIT ?
                """,
                arguments: [kind.rowKind, max(limit, 0)]
            )
        }
    }
}

/// 决策 artifact 概要（列表 UI 用；不展开完整 plans）。
struct PortfolioDecisionSummary: Sendable, Codable, Hashable {
    let artifactID: String
    let producedAt: Date
    let status: String
    let admissiblePlans: [String]
    let signalCount: Int
    /// 当前是否仍有效（透明携带,UI 自行决定过滤或标注）
    let isStillValid: Bool
}
