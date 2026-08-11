import Foundation

// MARK: - ProviderIdentifier
//
// Provider 原始代码到 Canonical Identity 的映射记录（ADR-DATA001 §12）。
// 一个 ProviderIdentifier 表示「Provider X 用代码 Y 指代 Canonical 实体 Z」。
// IdentityResolver 维护此映射表，业务层只通过 Canonical ID 访问实体。

/// Provider 原始标识到 Canonical 实体的单条映射。
///
/// 这是 ADR-DATA001 防火墙 1（Identity）的核心载体：Provider 代码只活在此映射中，
//  业务层（Factor / Risk / Attribution / Decision）永不直接使用 Provider 原始代码。
struct ProviderIdentifier: Sendable, Codable, Hashable {
    /// 哪个 Provider 给的标识
    let providerID: DataProviderID
    /// Provider 内部的代码体系（如 eastmoney 的 "fund_code" / "stock_symbol"、qieman 的 "prodCode"）
    let identifierScheme: String
    /// Provider 内部的实际值（如 "110022"、"LONG_WIN"、"AAPL"）
    let identifierValue: String
    /// 映射到的 Canonical 实体类型 + ID
    let canonical: CanonicalRef
    /// 映射是怎么建立的（4 条正式路径 + fuzzy candidate，见 IdentityResolutionMethod）
    let resolutionMethod: IdentityResolutionMethod
    /// 映射建立时间（用于审计「什么时候这个映射被建立的」）
    let resolvedAt: Date

    init(
        providerID: DataProviderID,
        identifierScheme: String,
        identifierValue: String,
        canonical: CanonicalRef,
        resolutionMethod: IdentityResolutionMethod,
        resolvedAt: Date
    ) {
        self.providerID = providerID
        self.identifierScheme = identifierScheme
        self.identifierValue = identifierValue
        self.canonical = canonical
        self.resolutionMethod = resolutionMethod
        self.resolvedAt = resolvedAt
    }
}

/// ProviderIdentifier 指向的 Canonical 实体引用。
///
/// 用 enum 关联值携带具体 ID 类型，保留「指向哪一层」的语义
///（如天天基金代码指向 FundShareClass，且慢 prodCode 也指向 FundShareClass，
//  股票 symbol 指向 Listing，监管 ID 指向 LegalEntity 或 Instrument）。
enum CanonicalRef: Sendable, Codable, Hashable {
    case legalEntity(LegalEntityID)
    case instrument(InstrumentID)
    case listing(ListingID)
    case fundProduct(FundProductID)
    case fundShareClass(FundShareClassID)

    /// 用于去重 / 索引的稳定字符串（含实体类型前缀，避免跨类型 rawValue 冲突）。
    var stableKey: String {
        switch self {
        case .legalEntity(let id): return "legalEntity:\(id.rawValue)"
        case .instrument(let id): return "instrument:\(id.rawValue)"
        case .listing(let id): return "listing:\(id.rawValue)"
        case .fundProduct(let id): return "fundProduct:\(id.rawValue)"
        case .fundShareClass(let id): return "fundShareClass:\(id.rawValue)"
        }
    }
}

// MARK: - IdentityResolutionMethod（ADR-DATA001 §13 四路径 + fuzzy）

/// Provider → Canonical 映射的建立方式。
///
/// ADR-DATA001 §Decision 3 定义 4 条正式路径 + fuzzy candidate 路径。
/// fuzzy 只产 candidate，必须经 Verification 才能升级为正式映射
///（避免低置信度匹配直接污染 Canonical Master）。
enum IdentityResolutionMethod: String, Sendable, Codable, Hashable, CaseIterable {
    /// 1. Provider authoritative：Provider 自带的官方 cross-ref
    ///（如 Provider 在响应里直接给出 ISIN / 证监会基金号）
    case providerAuthoritative = "PROVIDER_AUTHORITATIVE"

    /// 2. Exchange + symbol exact：交易所 + 代码精确匹配
    ///（如 "SSE + 600519" 全局唯一指向一个 Listing）
    case exchangeSymbolExact = "EXCHANGE_SYMBOL_EXACT"

    /// 3. ISIN / CIK：全球 / 监管唯一标识
    case isinOrCik = "ISIN_OR_CIK"

    /// 4. Manual verified：人工审核登记
    ///（持仓内标的的初始映射通常走这条，REPO-4b）
    case manualVerified = "MANUAL_VERIFIED"

    /// Fuzzy 匹配产出的 candidate（名称相似度、跨源代码相似）。
    /// **fuzzy 不直接写 canonical**，只作为 Verification 的输入。
    case fuzzyCandidate = "FUZZY_CANDIDATE"

    /// 是否为正式路径（已可信任，不需要再 verify）。
    var isAuthoritative: Bool {
        switch self {
        case .providerAuthoritative, .exchangeSymbolExact, .isinOrCik, .manualVerified:
            return true
        case .fuzzyCandidate:
            return false
        }
    }
}

// MARK: - InstrumentRelationship（ADR-DATA001 §14）
//
// 表达两个 Instrument 之间的关系，避免靠命名约定推断。
// 4 类关系：ETF→Index（跟踪）/ ShareClass→Product（归属）/ Stock→Entity（发行）/
// ADR→Stock（存托）。

/// 两个 Instrument 之间的显式关系。
struct InstrumentRelationship: Sendable, Codable, Hashable {
    let id: DomainID
    /// 关系类型
    let kind: RelationshipKind
    /// 源 Instrument（如 ETF）
    let fromInstrumentID: InstrumentID
    /// 目标 Instrument（如被跟踪的 Index）
    let toInstrumentID: InstrumentID
    /// 关系强度（如跟踪误差、A/C 类的归属比例，部分关系无值）
    let strength: Decimal?
    /// 建立此关系的来源（manual / provider / derived）
    let provenance: RelationshipProvenance

    init(
        id: DomainID,
        kind: RelationshipKind,
        fromInstrumentID: InstrumentID,
        toInstrumentID: InstrumentID,
        strength: Decimal? = nil,
        provenance: RelationshipProvenance
    ) {
        self.id = id
        self.kind = kind
        self.fromInstrumentID = fromInstrumentID
        self.toInstrumentID = toInstrumentID
        self.strength = strength
        self.provenance = provenance
    }

    /// 关系类型（ADR-DATA001 §14）。
    enum RelationshipKind: String, Sendable, Codable, Hashable, CaseIterable {
        /// ETF 跟踪指数（如「沪深300ETF」→「沪深300指数」）
        case tracksIndex = "TRACKS_INDEX"
        /// 份额类别归属产品（如「易方达消费 A」→「易方达消费产品」）
        case shareClassOf = "SHARE_CLASS_OF"
        /// 股票归属发行人（Instrument → LegalEntity 通过 Instrument.issuerID
        /// 隐含，但跨 Instrument 的「同一发行人多只股票」用此关系）
        case sameIssuer = "SAME_ISSUER"
        /// ADR 对应基础股票（海外存托凭证 → 本国市场股票）
        case adrUnderlying = "ADR_UNDERLYING"
    }

    /// 关系来源。
    enum RelationshipProvenance: String, Sendable, Codable, Hashable {
        case manual = "MANUAL"
        case provider = "PROVIDER"
        case derived = "DERIVED"  // 如从 issuerID 相同推导 sameIssuer
    }
}
