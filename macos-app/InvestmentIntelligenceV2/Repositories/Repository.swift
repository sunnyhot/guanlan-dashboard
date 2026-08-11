import Foundation

// MARK: - Repository 协议族（ADR-DATA001 / DATA002 / REPO-1）
//
// 业务层（Factor / Risk / Attribution / Decision）只通过 Repository 访问数据，
// 每个 API 强制 KnowledgeContext 入参（ADR-DATA002 §Decision 3）。
//
// 协议按域拆分（Instrument / MarketTimeSeries / NAVTimeSeries / FundHolding /
// Fundamental / Macro / CorporateAction / Calendar），便于：
// - InMemory / GRDB 各自按域实现（GRDB-7）
// - 测试 mock 单个域而不必实现全部
// - 未来拆分读写权限
//
// 通用约定：
// - 入参永远含 KnowledgeContext（economicKnowledge / operationalKnowledge /
//   exactSnapshot 三选一），编译期不可省略
// - 出参只含 Canonical 类型（Instrument / Listing / DailyBar / ...），
//   永不含 Provider 原始代码（ADR-DATA001 防火墙 1）
// - 多 vintage 场景：economicKnowledge 取可知最新；exactSnapshot 取全部 vintage
// - 缺口段返回空数组 / nil，不返回默认值或 0（ADR-DATA006）

// MARK: - Identity 域

/// Instrument / Listing / LegalEntity / FundProduct / FundShareClass 查询。
protocol InstrumentRepository: Sendable {
    func instrument(_ id: InstrumentID) -> Instrument?
    func listing(_ id: ListingID) -> Listing?
    func listings(forInstrument id: InstrumentID) -> [Listing]
    func legalEntity(_ id: LegalEntityID) -> LegalEntity?
    func fundProduct(_ id: FundProductID) -> FundProduct?
    func fundShareClass(_ id: FundShareClassID) -> FundShareClass?
    /// 通过 Provider 代码查 Canonical（IdentityResolver 的便捷入口）。
    /// 返回 ProviderIdentifier.canonical；未映射返回 nil。
    func resolve(providerID: DataProviderID, scheme: String, value: String) -> CanonicalRef?
    /// 列出某 Instrument 的关系（ADR-DATA001 §14）。
    func relationships(for instrument: InstrumentID) -> [InstrumentRelationship]
}

// MARK: - Market 行情域

/// 股票 / ETF / 指数日线查询（Listing 维度）。
protocol MarketTimeSeriesRepository: Sendable {
    /// 按 KnowledgeContext 查日线序列。
    /// - economicKnowledge(asOf:)：返回 availableAt ≤ asOf 的最新 vintage 序列
    /// - operationalKnowledge(asOf:)：同上且 ingestedAt ≤ asOf
    /// - exactSnapshot(at:)：返回 effectiveAt = at 的所有 vintage
    func dailyBars(
        listingID: ListingID,
        context: KnowledgeContext
    ) -> [DailyBar]

    /// 单点查询（便捷）。返回符合 context 的最新 vintage 单条；无数据返回 nil。
    func dailyBar(
        listingID: ListingID,
        on day: Date,
        context: KnowledgeContext
    ) -> DailyBar?
}

// MARK: - 基金净值域

/// 基金份额类别的 NAV 时间序列（FundShareClass 维度）。
protocol NAVTimeSeriesRepository: Sendable {
    func navObservations(
        shareClassID: FundShareClassID,
        context: KnowledgeContext
    ) -> [NAVObservation]

    func navObservation(
        shareClassID: FundShareClassID,
        on day: Date,
        context: KnowledgeContext
    ) -> NAVObservation?
}

// MARK: - 基金持仓域

/// 基金产品持仓快照（FundProduct 维度，multi-vintage 必备）。
protocol FundHoldingRepository: Sendable {
    func holdingSnapshots(
        productID: FundProductID,
        context: KnowledgeContext
    ) -> [FundHoldingSnapshot]

    /// 取符合 context 的最新可知持仓快照；无数据返回 nil。
    func latestHoldingSnapshot(
        productID: FundProductID,
        context: KnowledgeContext
    ) -> FundHoldingSnapshot?
}

// MARK: - 基本面域

/// 基本面观测（财务指标、估值等）。Epic 2 DOM-5 未定义具体 FundamentalObservation
/// 类型，此处先占位，Epic 7-8 引入 factor 需要时再补。
protocol FundamentalRepository: Sendable {
    // 占位：待 Epic 7+ 引入 FundamentalObservation 后扩展
}

// MARK: - 宏观域

/// 宏观经济指标查询（FRED vintage 对齐）。
protocol MacroRepository: Sendable {
    func macroObservations(
        indicatorID: InstrumentID,
        context: KnowledgeContext
    ) -> [MacroObservation]
}

// MARK: - 公司行动域

/// 公司行动（分红 / 送股 / 拆股 / 合并）查询。
protocol CorporateActionRepository: Sendable {
    func corporateActions(
        listingID: ListingID,
        context: KnowledgeContext
    ) -> [CorporateAction]
}

// MARK: - 交易日历域

/// 交易日历查询。与 TradingCalendar（DOM-7）协议互补——Repository 提供持久化的
/// 交易日历数据，TradingCalendar 接口基于此判断。
protocol CalendarRepository: Sendable {
    /// 判断某日是否为该法域的交易日。
    func isTradingDay(_ date: Date, jurisdiction: Jurisdiction) -> Bool
    /// 返回 d 之后的第 N 个交易日（不含 d 当日）。
    func tradingDay(after date: Date, offset: Int, jurisdiction: Jurisdiction) -> Date
    /// 返回 d 所在交易日的日界（00:00 本地）。
    func tradingDayStart(_ date: Date, jurisdiction: Jurisdiction) -> Date
}

// MARK: - 聚合 Repository

/// 所有 Repository 子协议的聚合。
///
/// InMemoryRepository / GRDBRepository 实现此聚合协议，业务层只依赖此接口
/// （或具体子协议，按需）。这样测试可以 mock 单个域，生产用全量实现。
protocol Repository: Sendable,
    InstrumentRepository,
    MarketTimeSeriesRepository,
    NAVTimeSeriesRepository,
    FundHoldingRepository,
    FundamentalRepository,
    MacroRepository,
    CorporateActionRepository,
    CalendarRepository {
}
