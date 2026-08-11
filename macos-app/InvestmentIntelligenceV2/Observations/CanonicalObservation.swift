import Foundation

// MARK: - CanonicalObservation 协议（ADR-DATA003）
//
// 所有进入业务层（Factor / Risk / Attribution / Decision）的数据必须实现此协议。
// Provider Adapter 只产 ProviderRecord（raw + adjustment），不写 Canonical；
// Canonical 化在 Pipeline commit 路径上完成（ADR-DATA003 §Decision 3）。

/// 所有 Canonical 观测的统一协议。
///
/// 协议要求：
/// - 稳定 `id`
/// - 带 `vintage`（ADR-DATA008 multi-vintage，Repository 通过 existential 操作时
///   可统一过滤 / 排序 / 选择最新版本，不必做类型分支）
/// - 指向 Canonical Identity（Instrument / Listing / ...）
/// - 带 `temporalEnvelope`（四时间，ADR-DATA002）
/// - 带 `availabilityProvenance`（availableAt 推导溯源，ADR-DATA005）
/// - 带 `dataQuality`（来源可靠性 + 修订状态，ADR-DATA006）
///
/// 业务层只消费 CanonicalObservation；Provider 原始字段只活在 ProviderRecord。
protocol CanonicalObservation: Sendable, Codable, Hashable {
    var id: ObservationID { get }
    var vintage: Vintage { get }
    var temporalEnvelope: TemporalEnvelope { get }
    var availabilityProvenance: AvailabilityProvenance { get }
    var dataQuality: DataQuality { get }
}

// MARK: - DataQuality（ADR-DATA006 提前一小部分，DOM-8 会完整定义）
//
// 这里只放 CanonicalObservation 必需的最小字段，详细 ProviderHealth / Reliability
// 在 DOM-8 完整实现。

/// 单条观测的数据质量标记。
struct DataQuality: Sendable, Codable, Hashable {
    /// 来源 Provider 的可靠性档位（ADR-DATA006 四档）
    let providerReliability: ProviderReliabilityClass
    /// 是否经过修订（vintage > 1 即修订过）
    let isRevised: Bool
    /// 是否仍活跃（未被撤回 / 重述替代）
    let isSuperseded: Bool

    init(
        providerReliability: ProviderReliabilityClass,
        isRevised: Bool = false,
        isSuperseded: Bool = false
    ) {
        self.providerReliability = providerReliability
        self.isRevised = isRevised
        self.isSuperseded = isSuperseded
    }
}

/// Provider 可靠性档位（ADR-DATA006 §Decision 1 四档）。
enum ProviderReliabilityClass: String, Sendable, Codable, Hashable, CaseIterable {
    /// 监管或官方（交易所、SEC、FRED）
    case officialStable = "OFFICIAL_STABLE"
    /// 有文档的免费 API（Stooq、Alpha Vantage、FRED API）
    case documentFreeAPI = "DOCUMENT_FREE_API"
    /// 社区聚合（天天基金、AKShare）
    case communityAggregated = "COMMUNITY_AGGREGATED"
    /// 无文档的公开端点（且慢平台）
    case undocumentedPublicEndpoint = "UNDOCUMENTED_PUBLIC_ENDPOINT"
}

// MARK: - 价格（共用基础类型，ADR-DATA003 §Decision 4 强类型单位）

/// 带货币的价格值（禁止用 Double 隐式约定单位）。
struct Price: Sendable, Codable, Hashable {
    let value: Decimal
    let currency: Currency

    init(value: Decimal, currency: Currency) {
        self.value = value
        self.currency = currency
    }
}

/// 带单位的小数比例（权重 / 收益率，禁止用 Double 隐式）。
struct Ratio: Sendable, Codable, Hashable {
    /// 0-1 小数（如 0.05 表示 5%）
    let value: Decimal

    init(value: Decimal) {
        self.value = value
    }
}

// MARK: - DailyBar（行情日线，ADR-DATA003 raw + adjustment 分离）

/// 单个 Listing 的日 OHLCV + 复权因子。
///
/// ADR-DATA003 §Decision 2：raw（原始 OHLC）+ adjustment（复权因子、汇率）
/// 分离存储，Canonical 在查询时按 vintage 拼装。
struct DailyBar: CanonicalObservation {
    let id: ObservationID
    /// 对应的 Listing（行情是 Listing 维度，不是 Instrument）
    let listingID: ListingID
    let temporalEnvelope: TemporalEnvelope
    let availabilityProvenance: AvailabilityProvenance
    let dataQuality: DataQuality
    let vintage: Vintage

    /// 原始（不复权）OHLC
    let rawOpen: Price
    let rawHigh: Price
    let rawLow: Price
    let rawClose: Price
    let volume: Int64?

    /// 复权因子（累计，便于回算复权价 = raw * factor）
    let adjustmentFactor: Decimal
    /// 汇率（若 tradingCurrency 与 baseCurrency 不同时使用）
    let fxRate: Decimal?

    init(
        id: ObservationID,
        listingID: ListingID,
        temporalEnvelope: TemporalEnvelope,
        availabilityProvenance: AvailabilityProvenance,
        dataQuality: DataQuality,
        vintage: Vintage,
        rawOpen: Price,
        rawHigh: Price,
        rawLow: Price,
        rawClose: Price,
        volume: Int64?,
        adjustmentFactor: Decimal,
        fxRate: Decimal? = nil
    ) {
        self.id = id
        self.listingID = listingID
        self.temporalEnvelope = temporalEnvelope
        self.availabilityProvenance = availabilityProvenance
        self.dataQuality = dataQuality
        self.vintage = vintage
        self.rawOpen = rawOpen
        self.rawHigh = rawHigh
        self.rawLow = rawLow
        self.rawClose = rawClose
        self.volume = volume
        self.adjustmentFactor = adjustmentFactor
        self.fxRate = fxRate
    }
}

// MARK: - NAVObservation（基金净值）

/// 基金份额类别的净值观测（单位净值 + 累计净值 + 累计分红）。
struct NAVObservation: CanonicalObservation {
    let id: ObservationID
    /// 对应的份额类别（NAV 是 ShareClass 维度，不是 Product）
    let shareClassID: FundShareClassID
    let temporalEnvelope: TemporalEnvelope
    let availabilityProvenance: AvailabilityProvenance
    let dataQuality: DataQuality
    let vintage: Vintage

    /// 单位净值（每份基金值多少钱）
    let unitNAV: Price
    /// 累计净值（含分红再投资）
    let accumulatedNAV: Price
    /// 累计每份分红（用于反推总回报）
    let cumulativeDividendPerShare: Price

    init(
        id: ObservationID,
        shareClassID: FundShareClassID,
        temporalEnvelope: TemporalEnvelope,
        availabilityProvenance: AvailabilityProvenance,
        dataQuality: DataQuality,
        vintage: Vintage,
        unitNAV: Price,
        accumulatedNAV: Price,
        cumulativeDividendPerShare: Price
    ) {
        self.id = id
        self.shareClassID = shareClassID
        self.temporalEnvelope = temporalEnvelope
        self.availabilityProvenance = availabilityProvenance
        self.dataQuality = dataQuality
        self.vintage = vintage
        self.unitNAV = unitNAV
        self.accumulatedNAV = accumulatedNAV
        self.cumulativeDividendPerShare = cumulativeDividendPerShare
    }
}

// MARK: - FundHoldingSnapshot（基金持仓快照，multi-vintage 必备）

/// 单条持仓 position（FundHoldingSnapshot 内含多个）。
struct FundHoldingPosition: Sendable, Codable, Hashable {
    /// 持仓标的（穿透后的 Canonical Listing 或 Instrument）
    let listingID: ListingID
    /// 持仓权重（0-1 小数）
    let weight: Ratio
    /// 持仓股数（披露范围内）
    let shares: Decimal?
    /// 持仓市值（本币）
    let marketValue: Price?
    /// 该 position 是否被披露（前十大重仓 = true，其余可能未披露）
    let isDisclosed: Bool

    init(
        listingID: ListingID,
        weight: Ratio,
        shares: Decimal?,
        marketValue: Price?,
        isDisclosed: Bool
    ) {
        self.listingID = listingID
        self.weight = weight
        self.shares = shares
        self.marketValue = marketValue
        self.isDisclosed = isDisclosed
    }
}

/// 基金产品的持仓快照（某报告期 + vintage）。
struct FundHoldingSnapshot: CanonicalObservation {
    let id: ObservationID
    /// 对应的基金产品（持仓是 Product 维度，A/C 类共享）
    let productID: FundProductID
    let temporalEnvelope: TemporalEnvelope
    let availabilityProvenance: AvailabilityProvenance
    let dataQuality: DataQuality
    let vintage: Vintage

    /// 报告期类型（季报 / 半年报 / 年报）
    let reportPeriod: ReportPeriod
    /// 持仓明细（前十大重仓 + 部分披露的其他）
    let positions: [FundHoldingPosition]
    /// 披露覆盖率（已披露 weight 总和，0-1，用于 lookthrough coverage 判断）
    let disclosedWeightTotal: Ratio

    enum ReportPeriod: String, Sendable, Codable, Hashable {
        case q1 = "Q1"
        case q2 = "Q2"
        case q3 = "Q3"
        case q4 = "Q4"           // 年报
        case semiAnnual = "SEMI_ANNUAL"
    }

    init(
        id: ObservationID,
        productID: FundProductID,
        temporalEnvelope: TemporalEnvelope,
        availabilityProvenance: AvailabilityProvenance,
        dataQuality: DataQuality,
        vintage: Vintage,
        reportPeriod: ReportPeriod,
        positions: [FundHoldingPosition],
        disclosedWeightTotal: Ratio
    ) {
        self.id = id
        self.productID = productID
        self.temporalEnvelope = temporalEnvelope
        self.availabilityProvenance = availabilityProvenance
        self.dataQuality = dataQuality
        self.vintage = vintage
        self.reportPeriod = reportPeriod
        self.positions = positions
        self.disclosedWeightTotal = disclosedWeightTotal
    }
}

// MARK: - MacroObservation（宏观指标，对齐 FRED vintage）

/// 宏观经济指标观测（GDP / CPI / 利率 / 失业率等）。
struct MacroObservation: CanonicalObservation {
    let id: ObservationID
    /// 指标 Canonical ID（如 GDP、CPI_US、FED_FUNDS_RATE）
    let indicatorID: InstrumentID
    let temporalEnvelope: TemporalEnvelope
    let availabilityProvenance: AvailabilityProvenance
    let dataQuality: DataQuality
    let vintage: Vintage

    /// 指标值（单位在 unit 字段声明）
    let value: Decimal
    /// 单位（如 "%"、"index"、"USD"）
    let unit: MacroUnit
    /// 频率
    let frequency: MacroFrequency
    /// 是否季节调整
    let isSeasonallyAdjusted: Bool
    /// 基期（DATA003 §Decision 4 要求）。仅 index / 链式指标有意义
    /// （如 CPI「2020=100」、GDP deflator）。非指数指标（%、USD）留 nil。
    let basePeriod: MacroBasePeriod?

    enum MacroUnit: String, Sendable, Codable, Hashable {
        case percent = "PERCENT"
        case index = "INDEX"
        case usd = "USD"
        case cny = "CNY"
        case basisPoints = "BPS"
        case count = "COUNT"   // 就业人数等
    }

    enum MacroFrequency: String, Sendable, Codable, Hashable {
        case daily = "DAILY"
        case weekly = "WEEKLY"
        case monthly = "MONTHLY"
        case quarterly = "QUARTERLY"
        case annual = "ANNUAL"
    }

    /// 基期（指数 / 链式指标的口径，跨 Provider 规范化必须保留）。
    struct MacroBasePeriod: Sendable, Codable, Hashable {
        /// 基期描述（如 "2020" 表示 2020 年均值=100；"2020-01" 表示某月）
        let periodLabel: String
        /// 基期对应的值（通常 100）
        let baseValue: Decimal
    }

    init(
        id: ObservationID,
        indicatorID: InstrumentID,
        temporalEnvelope: TemporalEnvelope,
        availabilityProvenance: AvailabilityProvenance,
        dataQuality: DataQuality,
        vintage: Vintage,
        value: Decimal,
        unit: MacroUnit,
        frequency: MacroFrequency,
        isSeasonallyAdjusted: Bool,
        basePeriod: MacroBasePeriod? = nil
    ) {
        self.id = id
        self.indicatorID = indicatorID
        self.temporalEnvelope = temporalEnvelope
        self.availabilityProvenance = availabilityProvenance
        self.dataQuality = dataQuality
        self.vintage = vintage
        self.value = value
        self.unit = unit
        self.frequency = frequency
        self.isSeasonallyAdjusted = isSeasonallyAdjusted
        self.basePeriod = basePeriod
    }
}

// MARK: - CorporateAction（公司行动）

/// 公司行动（分红 / 送股 / 拆股 / 合并）。
struct CorporateAction: CanonicalObservation {
    let id: ObservationID
    let listingID: ListingID
    let temporalEnvelope: TemporalEnvelope
    let availabilityProvenance: AvailabilityProvenance
    let dataQuality: DataQuality
    let vintage: Vintage

    let kind: Kind
    /// 除权除息日
    let exDate: Date
    /// 登记日
    let recordDate: Date?
    /// 派发日
    let payDate: Date?
    /// 行动比例（每股分红金额 / 送股比例 / 拆股比例）
    let ratio: Decimal
    /// 分红货币（仅 cashDividend 有）
    let currency: Currency?

    enum Kind: String, Sendable, Codable, Hashable {
        case cashDividend = "CASH_DIVIDEND"
        case stockDividend = "STOCK_DIVIDEND"
        case stockSplit = "STOCK_SPLIT"
        case reverseSplit = "REVERSE_SPLIT"
        case merger = "MERGER"
    }

    init(
        id: ObservationID,
        listingID: ListingID,
        temporalEnvelope: TemporalEnvelope,
        availabilityProvenance: AvailabilityProvenance,
        dataQuality: DataQuality,
        vintage: Vintage,
        kind: Kind,
        exDate: Date,
        recordDate: Date?,
        payDate: Date?,
        ratio: Decimal,
        currency: Currency? = nil
    ) {
        self.id = id
        self.listingID = listingID
        self.temporalEnvelope = temporalEnvelope
        self.availabilityProvenance = availabilityProvenance
        self.dataQuality = dataQuality
        self.vintage = vintage
        self.kind = kind
        self.exDate = exDate
        self.recordDate = recordDate
        self.payDate = payDate
        self.ratio = ratio
        self.currency = currency
    }
}

// MARK: - EvidenceObservation（证据观测，DOM-9 会扩展 EvidenceFact）
//
// Evidence 是 LLM Research 产出的「事实证据」，归入 Observation 因为它也需要
// PIT / vintage 语义（同一事实可能被不同来源 / 不同时间记录）。

/// 证据观测（LLM Research 产出的结构化事实）。
///
/// 与 EvidenceFact（DOM-9）区别：EvidenceObservation 是 Observation 层的载体，
/// EvidenceFact 是更细粒度的「事实 + extractionMethod + verificationStatus」。
///
/// **Evidence 逻辑身份（EvidenceID）**：EvidenceObservation 同时携带
/// `id: ObservationID`（CanonicalObservation 协议要求）和
/// `evidenceID: EvidenceID`（Evidence 逻辑身份）。下游引用（EvidenceFact.evidenceID、
/// InvestmentSignal.derivedFromEvidenceIDs）一律用 `EvidenceID`，**不允许用
/// ObservationID 冒充**——这样一条 DailyBar 或 NAV 的 ObservationID 无法被当作
/// Evidence 引用（审查 P1 修复点：编译期类型隔离）。
struct EvidenceObservation: CanonicalObservation {
    let id: ObservationID
    /// Evidence 逻辑身份（与 id 一一对应，但类型独立，下游引用专用）
    let evidenceID: EvidenceID
    let temporalEnvelope: TemporalEnvelope
    let availabilityProvenance: AvailabilityProvenance
    let dataQuality: DataQuality
    let vintage: Vintage

    /// 证据内容（自由文本或结构化 JSON 字符串，DOM-9 会收紧为 EvidenceFact）
    let content: String
    /// 来源（SEC filing / Tavily 网页 / Provider 公告 等）
    let source: EvidenceSource
    /// 关联的 Canonical 实体（如某股票 / 某基金）
    let subjectCanonical: CanonicalRef

    enum EvidenceSource: String, Sendable, Codable, Hashable {
        case secFiling = "SEC_FILING"
        case providerAnnouncement = "PROVIDER_ANNOUNCEMENT"
        case webSearch = "WEB_SEARCH"
        case news = "NEWS"
        case research = "RESEARCH"
    }

    init(
        id: ObservationID,
        evidenceID: EvidenceID,
        temporalEnvelope: TemporalEnvelope,
        availabilityProvenance: AvailabilityProvenance,
        dataQuality: DataQuality,
        vintage: Vintage,
        content: String,
        source: EvidenceSource,
        subjectCanonical: CanonicalRef
    ) {
        self.id = id
        self.evidenceID = evidenceID
        self.temporalEnvelope = temporalEnvelope
        self.availabilityProvenance = availabilityProvenance
        self.dataQuality = dataQuality
        self.vintage = vintage
        self.content = content
        self.source = source
        self.subjectCanonical = subjectCanonical
    }
}
