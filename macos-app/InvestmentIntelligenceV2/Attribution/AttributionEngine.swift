import Foundation

// MARK: - AttributionEngine（ATTR-1，Epic 9）
//
// 组合收益归因：把组合（或组合层组合）的区间收益拆到各持仓成分。
// 数学定义（全部 Decimal）：
// - contribution_i = w_i × r_i（权重 × 成分收益率；r 未知则该成分无贡献）
// - attributedReturn = Σ contribution_i（已知部分合计）
// - coverage = Σ w_i（收益率已知的权重，0-1）
// - residual = portfolioReturn − attributedReturn（仅当调用方提供组合实际
//   收益；包含未知成分的隐含贡献 + 估值口径误差，Renderer 明示语义）
//
// 第一个完整 Workflow 的确定性核心（90% deterministic）：同输入同输出，
// LLM 不参与（ATTR-3 的 Narrative 只是附加叙述，不改这些数字）。

/// 归因主体（基金产品或直接标的）。
enum AttributionSubject: Sendable, Codable, Hashable {
    case fund(FundProductID)
    case listing(ListingID)

    var stableKey: String {
        switch self {
        case .fund(let id): return "fund|\(id.rawValue)"
        case .listing(let id): return "listing|\(id.rawValue)"
        }
    }
}

/// 单个持仓的归因输入。
struct AttributionPositionInput: Sendable, Codable, Hashable {
    let subject: AttributionSubject
    /// 组合内相对权重（内部归一化）
    let weight: Ratio
    /// 当期收益率（nil = 未知：数据缺失日 / 停牌 / 未同步，进 coverage 缺口，不猜）
    let periodReturn: Ratio?
    /// 收益率的溯源 observation（NAV / DailyBar；nil = 无源，如手工输入）
    let sourceObservationID: ObservationID?

    init(
        subject: AttributionSubject, weight: Ratio, periodReturn: Ratio?,
        sourceObservationID: ObservationID? = nil
    ) {
        self.subject = subject
        self.weight = weight
        self.periodReturn = periodReturn
        self.sourceObservationID = sourceObservationID
    }
}

/// 单成分贡献。
struct AttributionContribution: Sendable, Codable, Hashable {
    let subject: AttributionSubject
    /// 归一化后权重
    let weight: Ratio
    /// 成分收益率（已知）
    let periodReturn: Ratio
    /// w × r
    let contribution: Ratio
    let sourceObservationID: ObservationID?
}

/// 归因计算结果（ATTR-1 核心）。
struct AttributionResult: Sendable, Codable, Hashable {
    let engineVersion: String
    /// 各成分贡献（|contribution| 降序，同值按 stableKey 升序）
    let contributions: [AttributionContribution]
    /// 已知部分合计收益（Σ w×r）
    let attributedReturn: Ratio
    /// 收益率已知成分的权重和（0-1）
    let coverage: Ratio
    /// 1 − coverage（未知权重，进 Renderer 的措辞分级）
    let unattributedWeight: Ratio
    /// portfolioReturn − attributedReturn（调用方未提供实际收益时为 nil）
    let residual: Ratio?
}

/// 归因引擎（ATTR-1，纯函数）。
struct AttributionEngine: Sendable {
    static let engineVersion = "v1"

    init() {}

    /// 计算归因。
    ///
    /// - positions：组合持仓（权重内部归一化；空 / 全零返回 nil）
    /// - portfolioReturn：组合实际区间收益（可选；提供时产 residual）
    func compute(
        positions: [AttributionPositionInput],
        portfolioReturn: Ratio?
    ) -> AttributionResult? {
        let totalWeight = positions.reduce(Decimal.zero) { $0 + $1.weight.value }
        guard totalWeight > 0 else { return nil }

        var known: [AttributionContribution] = []
        var attributed = Decimal.zero
        var knownWeight = Decimal.zero

        for position in positions {
            let weight = position.weight.value / totalWeight
            if let ret = position.periodReturn {
                let contribution = weight * ret.value
                attributed += contribution
                knownWeight += weight
                known.append(AttributionContribution(
                    subject: position.subject,
                    weight: Ratio(value: weight),
                    periodReturn: ret,
                    contribution: Ratio(value: contribution),
                    sourceObservationID: position.sourceObservationID
                ))
            }
        }
        known.sort {
            let lhs = abs($0.contribution.value)
            let rhs = abs($1.contribution.value)
            if lhs != rhs { return lhs > rhs }
            return $0.subject.stableKey < $1.subject.stableKey
        }

        return AttributionResult(
            engineVersion: Self.engineVersion,
            contributions: known,
            attributedReturn: Ratio(value: attributed),
            coverage: Ratio(value: knownWeight),
            unattributedWeight: Ratio(value: max(Decimal.one - knownWeight, 0)),
            residual: portfolioReturn.map { Ratio(value: $0.value - attributed) }
        )
    }
}

private extension Decimal {
    static let one = Decimal(1)
}
