import Foundation

// MARK: - DataQueryMode（ADR-DATA002 §Decision 2 双 query mode）

/// Repository 查询的两种模式（ADR-DATA002 §Decision 2）。
///
/// 必须显式选择，没有「无 mode」默认值。Repository 每个 API 都强制带
/// KnowledgeContext，KnowledgeContext 必须带 mode（编译期不可省略）。
enum DataQueryMode: Sendable, Codable, Hashable {
    /// 「站在 T 时刻做决策当时可知」。
    ///
    /// 只返回 `availableAt ≤ asOf` 的观测，防止 lookahead bias。
    /// **回测 / 历史重算 / 历史决策重放必须用此模式**。
    /// 多 vintage 时取 `availableAt ≤ asOf` 中最新的 vintage。
    case economicKnowledge(asOf: Date)

    /// 「精确查询某 vintage 快照」。
    ///
    /// 返回 `effectiveAt = at` 的所有 vintage（DATA008 revision 场景）。
    /// 用于跨 vintage 对比、回测、审计「这条数据当时是哪个版本」。
    case exactSnapshot(at: Date)

    /// 该模式用于过滤观测的截止时间。
    /// - economicKnowledge：`obs.availableAt <= asOf`
    /// - exactSnapshot：`obs.effectiveAt == at`（vintage 任意）
    func includes(envelope: TemporalEnvelope) -> Bool {
        switch self {
        case .economicKnowledge(let asOf):
            return envelope.availableAt <= asOf
        case .exactSnapshot(let at):
            return envelope.effectiveAt == at
        }
    }
}

// MARK: - KnowledgeContext（ADR-DATA002 / REPO-1 强制入参）

/// Repository 每个 API 的强制入参（ADR-DATA002 / REPO-1）。
///
/// 不允许「无上下文查询」存在。KnowledgeContext 携带：
/// - 查询模式（economicKnowledge / exactSnapshot）
/// - 可选 vintage 过滤（精确取某 vintage 时用）
/// - 可选 Provider 偏好（multi-source 时优先用哪个 Provider 的观测）
struct KnowledgeContext: Sendable, Codable, Hashable {
    let mode: DataQueryMode
    /// 指定 vintage（可选，用于精确取修订版本，配合 exactSnapshot）
    let vintageFilter: Vintage?
    /// Provider 偏好（可选，multi-source 选最优 Provider 时用）
    let preferredProvider: DataProviderID?

    init(mode: DataQueryMode, vintageFilter: Vintage? = nil, preferredProvider: DataProviderID? = nil) {
        self.mode = mode
        self.vintageFilter = vintageFilter
        self.preferredProvider = preferredProvider
    }

    /// 便捷构造：economicKnowledge 模式。
    static func economicKnowledge(asOf: Date) -> KnowledgeContext {
        KnowledgeContext(mode: .economicKnowledge(asOf: asOf))
    }

    /// 便捷构造：exactSnapshot 模式。
    static func exactSnapshot(at: Date) -> KnowledgeContext {
        KnowledgeContext(mode: .exactSnapshot(at: at))
    }
}
