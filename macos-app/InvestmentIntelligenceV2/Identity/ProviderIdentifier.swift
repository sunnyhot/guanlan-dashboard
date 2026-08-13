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
    /// Provider 内部的代码体系（如 eastmoney 的 "fund_code" / "stock_symbol"、stooq 的 "stock_symbol"）
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
///（如天天基金代码指向 FundShareClass，股票 symbol 指向 Listing，
//  监管 ID 指向 LegalEntity 或 Instrument）。
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

    // 自定义 Codable：编码为单键字典 {"fundShareClass": <id>}，
    // 避免 enum with associated value 合成 Codable 的 `_0` 中间层，
    // 让 fixture JSON 可读（`{"canonical": {"fundShareClass": "sc_110022_A"}}`）。
    private enum CodingKeys: String, CodingKey {
        case legalEntity, instrument, listing, fundProduct, fundShareClass
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try? c.decode(LegalEntityID.self, forKey: .legalEntity) {
            self = .legalEntity(id)
        } else if let id = try? c.decode(InstrumentID.self, forKey: .instrument) {
            self = .instrument(id)
        } else if let id = try? c.decode(ListingID.self, forKey: .listing) {
            self = .listing(id)
        } else if let id = try? c.decode(FundProductID.self, forKey: .fundProduct) {
            self = .fundProduct(id)
        } else if let id = try? c.decode(FundShareClassID.self, forKey: .fundShareClass) {
            self = .fundShareClass(id)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: c.allKeys.first ?? .legalEntity,
                in: c,
                debugDescription: "CanonicalRef: no recognized key"
            )
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .legalEntity(let id): try c.encode(id, forKey: .legalEntity)
        case .instrument(let id): try c.encode(id, forKey: .instrument)
        case .listing(let id): try c.encode(id, forKey: .listing)
        case .fundProduct(let id): try c.encode(id, forKey: .fundProduct)
        case .fundShareClass(let id): try c.encode(id, forKey: .fundShareClass)
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

/// 两个 Canonical 实体之间的显式关系（ADR-DATA001 §14）。
///
/// 用 enum with associated values 让每类关系的端点类型在编译期固定，
/// 避免「ShareClass→Product」或「Instrument→LegalEntity」被错误地用
/// InstrumentID 表达。每类关系携带正确的源/目标 ID 类型。
enum InstrumentRelationship: Sendable, Codable, Hashable {
    case tracksIndex(TracksIndex)
    case shareClassOf(ShareClassOf)
    case issuedBy(IssuedBy)
    case adrUnderlying(ADRUnderlying)

    /// 关系实例的唯一 ID（便于在 Repository 中索引 / 引用）。
    var id: DomainID {
        switch self {
        case .tracksIndex(let r): return r.id
        case .shareClassOf(let r): return r.id
        case .issuedBy(let r): return r.id
        case .adrUnderlying(let r): return r.id
        }
    }

    /// 建立此关系的来源（manual / provider / derived）。
    var provenance: RelationshipProvenance {
        switch self {
        case .tracksIndex(let r): return r.provenance
        case .shareClassOf(let r): return r.provenance
        case .issuedBy(let r): return r.provenance
        case .adrUnderlying(let r): return r.provenance
        }
    }

    /// ETF 跟踪指数（如「沪深300ETF」→「沪深300指数」）。
    /// 两端都是 InstrumentID（ETF 是 fund/ETF kind，指数是 index kind）。
    struct TracksIndex: Sendable, Codable, Hashable {
        let id: DomainID
        let etf: InstrumentID
        let index: InstrumentID
        /// 跟踪紧密度（0-1，部分关系无值）
        let strength: Decimal?
        let provenance: RelationshipProvenance
    }

    /// 份额类别归属产品（如「易方达消费 A」→「易方达消费产品」）。
    /// 源是 FundShareClassID，目标是 FundProductID（类型不同，编译期保证不混）。
    struct ShareClassOf: Sendable, Codable, Hashable {
        let id: DomainID
        let shareClass: FundShareClassID
        let product: FundProductID
        let provenance: RelationshipProvenance
    }

    /// 股票 / 基金归属发行人（Instrument → LegalEntity）。
    /// ADR-DATA001 §14 Stock→Entity：目标端是 LegalEntityID 而非 InstrumentID。
    /// （单只 Instrument 的 issuer 可直接读 Instrument.issuerID，本关系用于
    /// 跨 Instrument 的「同一发行人多只标的」图查询。）
    struct IssuedBy: Sendable, Codable, Hashable {
        let id: DomainID
        let instrument: InstrumentID
        let issuer: LegalEntityID
        let provenance: RelationshipProvenance
    }

    /// ADR 对应基础股票（海外存托凭证 → 本国市场股票）。
    /// 两端都是 InstrumentID（ADR instrument → underlying stock instrument）。
    struct ADRUnderlying: Sendable, Codable, Hashable {
        let id: DomainID
        let adr: InstrumentID
        let underlying: InstrumentID
        let provenance: RelationshipProvenance
    }

    /// 关系来源。
    enum RelationshipProvenance: String, Sendable, Codable, Hashable {
        case manual = "MANUAL"
        case provider = "PROVIDER"
        case derived = "DERIVED"  // 如从 issuerID 相同推导 issuedBy
    }
}
