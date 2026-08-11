import Foundation

// MARK: - DataQueryMode（ADR-DATA002 §Decision 2 双 query mode）

/// Repository 查询的模式（ADR-DATA002 §Decision 2 双 query mode + §Decision 4
/// operationalKnowledge）。
///
/// 必须显式选择，没有「无 mode」默认值。Repository 每个 API 都强制带
/// KnowledgeContext，KnowledgeContext 必须带 mode（编译期不可省略）。
///
/// 三种 mode 对应三种「当时可知」语义，区别在用哪个时间戳过滤：
/// - **economicKnowledge**：客观经济可知——「T 时点，外部世界已经能看到这条数据吗？」
/// - **operationalKnowledge**：本机实际已知——「T 时点，本系统真的抓到了吗？」
/// - **exactSnapshot**：精确 vintage 查询——「把 effectiveAt = T 的所有版本都给我」
enum DataQueryMode: Sendable, Codable, Hashable {
    /// 「站在 T 时刻，外部世界客观上已经能看到这条数据」。
    ///
    /// 只返回 `availableAt ≤ asOf` 的观测，**不考虑本机是否已抓到**。
    /// 用于回测 / 历史重算 / 历史决策重放，保证「同一外部信息集 → 同一决策」。
    /// 这条数据本机实际何时抓到（ingestedAt）与回放语义无关。
    ///
    /// 多 vintage 时取 `availableAt ≤ asOf` 中最新的 vintage。
    case economicKnowledge(asOf: Date)

    /// 「站在 T 时刻，本系统实际已经掌握这条数据」。
    ///
    /// 必须同时满足 `availableAt ≤ asOf` **且** `ingestedAt ≤ asOf`。
    /// 用于回答「7-21 这天，App 界面上实际能给用户看什么」——
    /// 即使数据客观可知（availableAt = 7-21），如果本机因 Provider 故障到 8-01
    /// 才抓到（ingestedAt = 8-01），那 7-21 的运行时界面上是看不到的。
    ///
    /// 这是 economicKnowledge 的严格化版本：economicKnowledge 假设「本机总能及时抓到」，
    /// operationalKnowledge 承认「本机可能滞后」，仅用于实时 UI / 历史界面还原。
    case operationalKnowledge(asOf: Date)

    /// 「精确查询某 vintage 快照」。
    ///
    /// 返回 `effectiveAt = at` 的所有 vintage（DATA008 revision 场景）。
    /// 用于跨 vintage 对比、回测、审计「这条数据当时是哪个版本」。
    case exactSnapshot(at: Date)

    /// 该模式是否包含给定 envelope（PIT 过滤）。
    ///
    /// - economicKnowledge：`availableAt <= asOf`（不看 ingestedAt）
    /// - operationalKnowledge：`availableAt <= asOf && ingestedAt <= asOf`
    /// - exactSnapshot：`effectiveAt == at`（vintage 任意）
    func includes(envelope: TemporalEnvelope) -> Bool {
        switch self {
        case .economicKnowledge(let asOf):
            return envelope.availableAt <= asOf
        case .operationalKnowledge(let asOf):
            return envelope.availableAt <= asOf && envelope.ingestedAt <= asOf
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

    /// 便捷构造：operationalKnowledge 模式。
    static func operationalKnowledge(asOf: Date) -> KnowledgeContext {
        KnowledgeContext(mode: .operationalKnowledge(asOf: asOf))
    }

    /// 便捷构造：exactSnapshot 模式。
    static func exactSnapshot(at: Date) -> KnowledgeContext {
        KnowledgeContext(mode: .exactSnapshot(at: at))
    }
}
