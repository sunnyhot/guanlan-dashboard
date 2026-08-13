import Foundation

// MARK: - DomainID

/// 所有 V3.1 Canonical Identity / Observation / Decision 实体的 ID 基类。
///
/// 通用约束（每个具体 ID 类型都必须满足，详见 ADR-DATA001）：
/// - `Sendable`：可跨 actor / async 边界传递
/// - `Codable`：可序列化进 GRDB / JSON artifact
/// - `Hashable`：可作 Dictionary key、Set 元素
/// - `RawRepresentable` where `RawValue == String`：底层是稳定字符串，
///   但用专用类型避免跨实体混用（如 `InstrumentID` 不能赋给 `ListingID`）
///
/// ID 一旦写入 Repository 永不更改、永不复用（ADR-DATA001 §Decision 2）。
/// ID 的 `rawValue` 推荐用「实体前缀 + ULID/UUID」格式（如 `inst_01J...`），
/// 由 IdentityResolver / Store 生成，业务层不直接构造。
struct DomainID: Sendable, Codable, Hashable, RawRepresentable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

// MARK: - 具体实体 ID 类型
//
// 每个类型是 DomainID 的轻量包装，通过 phantom type 模式实现类型隔离：
// `InstrumentID` 与 `ListingID` 在编译期不能互换，即使底层 rawValue 格式相同。
// 所有类型走相同的 Codable / Hashable / Sendable 实现（桥接到 DomainID）。

/// 数据 Provider 标识（天天基金 / SEC / FRED / Stooq / AlphaVantage / AKShare / Tavily）。
struct DataProviderID: Sendable, Codable, Hashable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

/// 抽象金融工具 ID（一只基金、一只指数、一只股票的「合约」）。
/// ADR-DATA001 五层实体中的第 2 层。
struct InstrumentID: Sendable, Codable, Hashable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

/// 挂牌 ID（某交易所/平台的挂牌）。同一只股票可沪深港三地挂牌。
/// ADR-DATA001 五层实体中的第 3 层。
struct ListingID: Sendable, Codable, Hashable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

/// 发行人 / 法律实体 ID（基金管理人 / 上市公司）。
/// ADR-DATA001 五层实体中的第 1 层。
struct LegalEntityID: Sendable, Codable, Hashable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

/// 基金产品 ID（含 A/C 类聚合）。
/// ADR-DATA001 五层实体中的第 4 层。
struct FundProductID: Sendable, Codable, Hashable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

/// 基金份额类别 ID（A 类、C 类独立）。
/// ADR-DATA001 五层实体中的第 5 层。
struct FundShareClassID: Sendable, Codable, Hashable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

// MARK: - 派生 ID（用于 Observation / Signal / Artifact 等下游实体）

/// 单条 CanonicalObservation 的 ID（含 vintage 维度，见 ADR-DATA008）。
struct ObservationID: Sendable, Codable, Hashable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

/// Evidence 实例 ID（LLM / 外部研究产出的事实证据，见 ADR-DOM-9）。
struct EvidenceID: Sendable, Codable, Hashable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

/// InvestmentSignal ID（ordinal 信号，LLM Research 的产物，见 ADR-DOM-9）。
struct SignalID: Sendable, Codable, Hashable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

/// FactorSnapshot ID（因子在某 asOf 的快照，见 Epic 7 FAC-1）。
struct FactorSnapshotID: Sendable, Codable, Hashable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

/// Artifact ID（决策 / 归因等产物，含 ValidityPolicy，见 ADR-DOM-10）。
struct ArtifactID: Sendable, Codable, Hashable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

/// Strategic Target Allocation 版本号（D000 Target provenance）。
struct TargetVersion: Sendable, Codable, Hashable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

/// 投资目标 ID（Strategic Allocation Target 的稳定标识）。
///
/// ADR-D000 Target 是 Cardinal Firewall 第一道：每个 Strategic Target Allocation
/// 有唯一 InvestmentTargetID，Agent / LLM / Signal 都不能改它（只能推荐目录
/// 已有模板给用户确认）。业务层（Decision）通过 InvestmentTargetID 引用 Target，
/// 不直接持有权重字典。
struct InvestmentTargetID: Sendable, Codable, Hashable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

// MARK: - 已知 Provider ID 常量
//
// 集中声明便于审查（FREE001 PR checklist：新增 Provider 必须在此登记）。
extension DataProviderID {
    /// 且慢平台标识（identity 命名空间保留，非 V2 数据 Provider）。REPO-6（且慢 Provider）
    /// 已从 V2 market data pipeline 移除——且慢净值转发天天基金（REPO-7 直连源头）、
    /// 独有的主理人调仓动态不属于 CanonicalObservation、AI 分析也不需要。此常量仅供
    /// identity 层通用机制测试（IdentityResolver / 跨源去重 / ProviderHealth）使用。
    static let qieman = DataProviderID(rawValue: "qieman")
    /// 天天基金（社区聚合披露，communityAggregated）
    static let eastmoney = DataProviderID(rawValue: "eastmoney")
    /// SEC EDGAR（监管官方，officialStable）
    static let sec = DataProviderID(rawValue: "sec")
    /// FRED（圣路易斯联储宏观，officialStable / documentFreeAPI）
    static let fred = DataProviderID(rawValue: "fred")
    /// Stooq（美股历史日线，documentFreeAPI，personal use）
    static let stooq = DataProviderID(rawValue: "stooq")
    /// Alpha Vantage（多市场，documentFreeAPI，25/天 free tier）
    static let alphaVantage = DataProviderID(rawValue: "alpha-vantage")
    /// AKShare Collector（社区聚合，进程外 Python，communityAggregated）
    static let akshare = DataProviderID(rawValue: "akshare")
    /// Tavily（web 搜索，documentFreeAPI，月额度）
    static let tavily = DataProviderID(rawValue: "tavily")
}
