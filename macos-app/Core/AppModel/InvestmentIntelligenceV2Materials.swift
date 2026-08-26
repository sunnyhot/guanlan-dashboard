import Foundation

// MARK: - 投资智能 V2 决策材料（P0：真实战略目标 + 可信资产分类）
//
// 产品重构方案 §6.2 / §6.3：决策输入正确性先行——
// - Target 只来自 StrategicAllocationTargetStore 的用户意图（不再自复制当前
//   仓位伪造「维持当前配置」对照）；
// - 每个可交易持仓的 AssetClass 经解析优先级确定：用户显式 > 直接股票 >
//   基金披露单一类 ≥80%（未过期）> unresolved（fail-closed，不出执行计划）；
// - 权重精确归一（残差只做 Decimal 舍入修正，不掩盖未知持仓）。
//
// 本文件是纯计算层：AppModel 在调用侧装配 Target Store / 分类 Store /
// 穿透披露快照，这里只做确定性推导，不做 I/O。

// MARK: - 分类解析

/// 单个持仓的战略资产分类解析结果。
enum StrategicAssetClassification: Sendable, Equatable {
    case resolved(AssetClass, origin: Origin)
    case unresolved

    enum Origin: Sendable, Equatable {
        /// 用户显式选择（AssetClassAssignmentStore source = .user）。
        case user
        /// 直接股票规则（assetType == .stock 恒真）。
        case stockRule
        /// 基金披露识别（单一资产类占比 ≥80% 且披露未过期）。
        case systemInferred(disclosureDate: String)
    }

    var assetClass: AssetClass? {
        if case let .resolved(assetClass, _) = self { return assetClass }
        return nil
    }
}

/// 分类解析器（纯函数）：按「用户显式 > 股票规则 > 披露识别 > unresolved」
/// 的固定优先级为每个正权重持仓确定战略资产类。
enum StrategicAssetClassificationResolver {

    /// 披露识别的单一资产类占比阈值（≥80% 才可信）。
    static let disclosureDominanceThresholdPct = 80.0
    /// 披露过期阈值（天）：与 FundLookThrough 的 150 天陈旧警告一致。
    static let disclosureStaleDays = 150

    struct Result: Sendable, Equatable {
        /// subjectKey（"fund|code"）→ 分类。
        let classification: [String: StrategicAssetClassification]
        /// unresolved 的 subjectKey（正权重持仓，确定性排序）。
        let unresolvedSubjectKeys: [String]
    }

    /// - Parameters:
    ///   - rows: 持仓行（只对正权重且 code 非空的行解析）。
    ///   - assignments: 分类 Store 当前有效事件（subjectKey → Assignment）。
    ///   - disclosures: 基金穿透披露（App 侧 PortfolioLookThroughSnapshot.disclosures）。
    ///   - now: 披露过期判定基准时间。
    static func resolve(
        rows: [PersonalAssetAggregateRow],
        assignments: [String: StrategicAssetClassAssignmentStore.Assignment],
        disclosures: [String: FundLookThroughDisclosure],
        now: Date
    ) -> Result {
        var classification: [String: StrategicAssetClassification] = [:]
        var unresolved: [String] = []

        for row in rows {
            guard row.effectiveHoldingAmount > 0, let code = row.fundCode, !code.isEmpty else {
                continue
            }
            let subjectKey = "fund|\(code)"
            guard classification[subjectKey] == nil else { continue }

            // 1. 用户显式分类（最高优先级——系统识别不覆盖用户意图）
            if let assignment = assignments[subjectKey] {
                classification[subjectKey] = .resolved(
                    assignment.assetClass, origin: .user)
                continue
            }
            // 2. 直接股票 → equity（规则恒真）
            if row.assetType == .stock {
                classification[subjectKey] = .resolved(.equity, origin: .stockRule)
                continue
            }
            // 3. 基金披露：单一资产类 ≥80% 且披露未过期 → 系统识别
            if let inferred = inferFromDisclosure(
                disclosures[code], now: now)
            {
                classification[subjectKey] = .resolved(
                    inferred.assetClass,
                    origin: .systemInferred(disclosureDate: inferred.disclosureDate))
                continue
            }
            // 4. unresolved：不用 .alternative 静默兜底
            classification[subjectKey] = .unresolved
            unresolved.append(subjectKey)
        }
        return Result(
            classification: classification,
            unresolvedSubjectKeys: unresolved.sorted()
        )
    }

    /// 披露 → 单一资产类（stockPct/bondPct/cashPct 任一 ≥80%；commodity /
    /// alternative 无法从股票/债券/现金口径区分，交还用户裁决）。
    private static func inferFromDisclosure(
        _ disclosure: FundLookThroughDisclosure?, now: Date
    ) -> (assetClass: AssetClass, disclosureDate: String)? {
        guard let disclosure, let allocation = disclosure.assetAllocation else {
            return nil
        }
        guard !isStale(disclosureDate: disclosure.asOf, now: now) else { return nil }
        let threshold = disclosureDominanceThresholdPct
        if let stockPct = allocation.stockPct, stockPct >= threshold {
            return (.equity, disclosure.asOf)
        }
        if let bondPct = allocation.bondPct, bondPct >= threshold {
            return (.fixedIncome, disclosure.asOf)
        }
        if let cashPct = allocation.cashPct, cashPct >= threshold {
            return (.cash, disclosure.asOf)
        }
        return nil
    }

    private static func isStale(disclosureDate: String, now: Date) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        guard let disclosed = formatter.date(from: String(disclosureDate.prefix(10))) else {
            // 日期不可解析 = 披露不可信 → 视为过期（fail-closed）
            return true
        }
        let days = Calendar.current.dateComponents(
            [.day], from: disclosed, to: now).day ?? 0
        return days > disclosureStaleDays
    }
}

// MARK: - 快照构建（纯函数）

/// 持仓快照构建输出（readiness 材料与 planner 输入的装配面）。
struct LivePortfolioSnapshotBuild: Sendable, Equatable {
    let portfolio: PortfolioSnapshot
    let actionDomain: ActionDomain
    /// 当前资产类聚合权重（Decimal 精确、和恒为 1）。
    let currentClassWeights: [AssetClass: Decimal]
    /// unresolved 的正权重 subject（确定性排序；空 = 分类就绪）。
    let unresolvedSubjectKeys: [String]
    /// 分类覆盖率（已解析权重 / 总权重，0...1）。
    let classificationCoverage: Decimal
    /// 组合内最新估值日期（无可解析日期时 nil）。
    let valuationAsOf: Date?
}

/// 持仓 → PortfolioSnapshot / ActionDomain / readiness 的纯函数构建器。
///
/// 纪律：有任意正权重持仓 unresolved 时抛 `unclassifiedHoldings`——不生成
/// planner run，不用 .alternative 兜底；权重残差只归入最大仓做 Decimal
/// 舍入修正（和恒精确 = 1），不掩盖未知持仓。
enum LivePortfolioSnapshotBuilder {

    /// 估值陈旧阈值（天）：正权重持仓的估值信息全部早于该窗 → stale。
    static let valuationStaleDays = 7

    enum BuildError: Error, Equatable, Sendable {
        case emptyPortfolio
        case unclassifiedHoldings([String])
        case staleValuation(latestAsOf: Date)
    }

    static func build(
        rows: [PersonalAssetAggregateRow],
        classification: [String: StrategicAssetClassification],
        asOf: Date
    ) throws -> LivePortfolioSnapshotBuild {
        // 正权重 + code 非空的行 → (subjectKey, amount, resolvedClass, valuationDates)
        var entries: [(subjectKey: String, amount: Decimal,
                       assetClass: AssetClass, dates: [Date])] = []
        var unresolved: [String] = []
        var valuationDates: [Date] = []
        let formatter = valuationDateFormatter()

        for row in rows {
            guard row.effectiveHoldingAmount > 0, let code = row.fundCode, !code.isEmpty else {
                continue
            }
            let subjectKey = "fund|\(code)"
            let amount = dec(row.effectiveHoldingAmount)
            guard amount > 0 else { continue }

            switch classification[subjectKey] ?? .unresolved {
            case let .resolved(assetClass, _):
                entries.append((subjectKey, amount, assetClass, []))
            case .unresolved:
                unresolved.append(subjectKey)
            }

            if let valuationRow = row.holdingRow {
                valuationDates.append(
                    contentsOf: Self.parseValuationDates(valuationRow, formatter: formatter))
            }
        }

        guard !entries.isEmpty || !unresolved.isEmpty else {
            throw BuildError.emptyPortfolio
        }
        guard unresolved.isEmpty else {
            throw BuildError.unclassifiedHoldings(unresolved.sorted())
        }

        // 估值陈旧：有可解析日期时，最新日期早于阈值 → fail-closed
        if let latest = valuationDates.max() {
            let days = Calendar.current.dateComponents(
                [.day], from: latest, to: asOf).day ?? 0
            guard days <= valuationStaleDays else {
                throw BuildError.staleValuation(latestAsOf: latest)
            }
        }

        // 权重归一（残差归最大仓，Decimal 和恒精确 = 1）
        let total = entries.map(\.amount).reduce(Decimal.zero, +)
        guard total > 0 else { throw BuildError.emptyPortfolio }
        var normalized = entries.map {
            (subjectKey: $0.subjectKey, assetClass: $0.assetClass, weight: $0.amount / total)
        }
        if let largestIndex = normalized.indices.max(by: {
            normalized[$0].weight == normalized[$1].weight
                ? normalized[$0].subjectKey < normalized[$1].subjectKey
                : normalized[$0].weight < normalized[$1].weight
        }) {
            let othersSum = normalized.enumerated()
                .filter { $0.offset != largestIndex }
                .reduce(Decimal.zero) { $0 + $1.element.weight }
            normalized[largestIndex].weight = Decimal(1) - othersSum
        }

        let positions = normalized.map {
            PortfolioPosition(
                subjectKey: $0.subjectKey,
                assetClass: $0.assetClass,
                weight: Ratio(value: $0.weight)
            )
        }
        let portfolio = PortfolioSnapshot(asOf: asOf, positions: positions)

        // 类聚合权重（展示面「当前配置」）
        var classWeights: [AssetClass: Decimal] = [:]
        for position in positions {
            classWeights[position.assetClass, default: 0] += position.weight.value
        }

        // ActionDomain：每个真实持仓 ±[0,1]（subjectKey 只对应真实可交易持仓，
        // 不把混合基金拆成虚拟 subject）
        let bounds = Dictionary(
            uniqueKeysWithValues: positions.map {
                ($0.subjectKey, ActionDomain.SubjectBounds(
                    lower: Ratio(value: -1), upper: Ratio(value: 1)))
            }
        )
        let actionDomain = ActionDomain(
            perSubjectBounds: bounds,
            eligibleNewSubjects: [:],
            builderVersion: "live-v2",
            newSubjectBuyUpper: Ratio(value: 1)
        )

        return LivePortfolioSnapshotBuild(
            portfolio: portfolio,
            actionDomain: actionDomain,
            currentClassWeights: classWeights,
            unresolvedSubjectKeys: [],
            classificationCoverage: Decimal(1),
            valuationAsOf: valuationDates.max()
        )
    }

    // MARK: - 私有

    private static func dec(_ double: Double) -> Decimal {
        // locale 无关（String(format:) 的 %f 随 locale 出逗号）；金额精度
        // 到分位足够构造权重比例
        Decimal((double * 10_000).rounded() / 10_000)
    }

    private static func valuationDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter
    }

    private static func parseValuationDates(
        _ row: UserPortfolioValuationRow, formatter: DateFormatter
    ) -> [Date] {
        [row.priceTime, row.officialNavDate, row.estimatePriceTime]
            .compactMap { raw in
                raw.flatMap { formatter.date(from: String($0.prefix(10))) }
            }
    }
}

// MARK: - Runtime 决策输入前置条件（fail-closed）

/// 决策 / 研究运行前的输入就绪性错误（P0；P1 映射为带恢复动作的
/// IntelligenceUserFacingError）。
enum IntelligenceInputError: Error, Equatable, Sendable {
    case missingTarget
    case unclassifiedHoldings([String])
    case staleValuation(latestAsOf: Date)
    case emptyPortfolio

    var userFacingMessage: String {
        switch self {
        case .missingTarget:
            return "尚未设定战略配置——先在「战略配置」中设定五类资产的目标占比"
        case .unclassifiedHoldings(let subjects):
            return "\(subjects.count) 项持仓待归类，归类完成前不生成执行计划"
        case .staleValuation(let latest):
            let date = latest.formatted(date: .abbreviated, time: .omitted)
            return "持仓估值数据已过期（最新 \(date)），请先更新持仓数据"
        case .emptyPortfolio:
            return "暂无有效持仓，无法进行决策"
        }
    }
}

// MARK: - 决策材料装配（后台线程，无 actor 隔离）

/// Runtime 决策材料装配器：Target Store 读取 + 分类解析 + 系统识别回写
/// （幂等）→ LivePortfolioDecisionMaterials。在后台线程调用（文件 IO），
/// disclosures 由调用方在 MainActor 捕获后传入。
enum LiveDecisionMaterialsAssembler {

    static func assemble(
        rows: [PersonalAssetAggregateRow],
        disclosures: [String: FundLookThroughDisclosure],
        runtime: AppModel.IntelligenceV2Runtime,
        now: Date
    ) throws -> LivePortfolioDecisionMaterials {
        guard let target = try runtime.targetStore.currentTarget() else {
            throw IntelligenceInputError.missingTarget
        }
        let assignments = try runtime.assignmentStore.currentAssignments()
        let resolved = StrategicAssetClassificationResolver.resolve(
            rows: rows, assignments: assignments, disclosures: disclosures, now: now)
        // 系统识别结果回写事件（幂等；source = .systemInferred，不伪装用户选择）
        for (subjectKey, classification) in resolved.classification.sorted(by: { $0.key < $1.key }) {
            if case let .resolved(assetClass, .systemInferred(disclosureDate)) = classification {
                let assignment = StrategicAssetClassAssignmentStore.makeAssignment(
                    subjectKey: subjectKey,
                    assetClass: assetClass,
                    source: .systemInferred,
                    recordedAt: now,
                    disclosureDate: disclosureDate
                )
                _ = try? runtime.assignmentStore.record(assignment)
            }
        }
        guard resolved.unresolvedSubjectKeys.isEmpty else {
            throw IntelligenceInputError.unclassifiedHoldings(resolved.unresolvedSubjectKeys)
        }
        return LivePortfolioDecisionMaterials(
            rows: rows, classification: resolved.classification, target: target, now: now)
    }
}

// MARK: - 决策材料供给（真实 target）

/// 从 App 持仓行 + 已解析分类 + 真实用户 Target 构造 V2 决策输入。
///
/// 与旧实现的本质差异（P0）：target 由调用方传入（Target Store 的用户意图），
/// 不再从当前仓位自复制——60/40 现状对 50/50 目标会产出真实的非零调整。
struct LivePortfolioDecisionMaterials: PortfolioDecisionMaterialsProviding {
    let rows: [PersonalAssetAggregateRow]
    let classification: [String: StrategicAssetClassification]
    let target: AllocationTarget
    let now: Date

    enum LiveMaterialsError: Error, Equatable, Sendable {
        case emptyPortfolio
        case unclassifiedHoldings([String])
        case staleValuation(latestAsOf: Date)
    }

    func materials(asOf: Date) throws -> PortfolioDecisionMaterials {
        let build: LivePortfolioSnapshotBuild
        do {
            build = try LivePortfolioSnapshotBuilder.build(
                rows: rows, classification: classification, asOf: asOf)
        } catch let error as LivePortfolioSnapshotBuilder.BuildError {
            switch error {
            case .emptyPortfolio:
                throw LiveMaterialsError.emptyPortfolio
            case let .unclassifiedHoldings(subjects):
                throw LiveMaterialsError.unclassifiedHoldings(subjects)
            case let .staleValuation(latest):
                throw LiveMaterialsError.staleValuation(latestAsOf: latest)
            }
        }

        let definition = CriterionDefinition(
            id: "costIntensity", version: "v1", evaluatorKind: .weightedSum,
            inputReferences: [CriterionDefinition.InputReference(
                kind: .planMetric, referenceID: PlanMetrics.turnover, weight: 1)],
            unit: .ratio, higherIsBetter: false
        )
        let plannerRun = DecisionReplayer.PlannerRun(
            portfolio: build.portfolio,
            target: target,
            remediationTargets: [],
            userDirectives: [],
            actionDomain: build.actionDomain,
            plannerParameters: TargetRebalancePlanner.Parameters()
        )
        return PortfolioDecisionMaterials(
            replayerMaterials: DecisionReplayer.ReplayMaterials(
                criterionDefinitions: [definition.fingerprint: definition],
                factorSnapshots: [:], observations: [:],
                band: IndifferenceBand(
                    policyID: "live-band", version: "v1",
                    defaultBand: Decimal(string: "0.01")!,
                    rationale: "生产默认带——turnover 差 1% 内视为无差异"
                )
            ),
            plannerRuns: ["current": plannerRun],
            target: target,
            knowledgeContextSummary: "economicKnowledge(自 \(now))· live materials v2（用户 Target）"
        )
    }
}
