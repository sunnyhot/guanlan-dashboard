import Foundation

// MARK: - InMemoryRepository（REPO-2，M2 验收载体）
//
// Dictionary-backed Repository 实现，用于：
// - M2 阶段验证 Repository 协议 + PIT 语义（不依赖 GRDB，ADR-DATA009）
// - 测试 mock（单测 Factor/Risk 时注入固定数据）
// - 开发期快速迭代（真实 Provider 数据加载后立即查）
//
// 不持久化、不并发优化——M2 通过后 Epic 5 用 GRDBRepository 替代。
// Repository 协议契约不变（GRDB-7），InMemory 时代的 golden test 在 GRDB
// 时代同样通过（rollout §4.2 M4 验收）。

/// Dictionary-backed Repository 实现。
///
/// 线程安全：内部用 NSLock 保护可变存储（多个 Repository 方法可并发读，
/// 写入互斥）。M2 阶段够用；GRDB 阶段换数据库事务。
final class InMemoryRepository: Repository {
    // Identity
    private var instruments: [InstrumentID: Instrument] = [:]
    private var listings: [ListingID: Listing] = [:]
    private var instrumentsToListings: [InstrumentID: [ListingID]] = [:]
    private var legalEntities: [LegalEntityID: LegalEntity] = [:]
    private var fundProducts: [FundProductID: FundProduct] = [:]
    private var fundShareClasses: [FundShareClassID: FundShareClass] = [:]
    private var providerIdentifiers: [String: ProviderIdentifier] = [:]  // key = provider+scheme+value
    private var relationships: [InstrumentID: [InstrumentRelationship]] = [:]

    // Observations（按 domain + canonical ID 索引，每个值是 [vintage] 数组）
    private var dailyBars: [ListingID: [DailyBar]] = [:]
    private var navObservations: [FundShareClassID: [NAVObservation]] = [:]
    private var holdingSnapshots: [FundProductID: [FundHoldingSnapshot]] = [:]
    private var macroObservations: [InstrumentID: [MacroObservation]] = [:]
    private var corporateActions: [ListingID: [CorporateAction]] = [:]

    // Calendar
    private let calendarBackend: TradingCalendar

    private let lock = NSLock()

    init(calendarBackend: TradingCalendar) {
        self.calendarBackend = calendarBackend
    }

    // MARK: - 写入（Builder 风格，供 Fixture loader / Provider staging 用）

    @discardableResult
    func upsert(_ instrument: Instrument) -> Self {
        lock.lock(); defer { lock.unlock() }
        instruments[instrument.id] = instrument
        return self
    }

    @discardableResult
    func upsert(_ listing: Listing) -> Self {
        lock.lock(); defer { lock.unlock() }
        listings[listing.id] = listing
        instrumentsToListings[listing.instrumentID, default: []].append(listing.id)
        return self
    }

    @discardableResult
    func upsert(_ entity: LegalEntity) -> Self {
        lock.lock(); defer { lock.unlock() }
        legalEntities[entity.id] = entity
        return self
    }

    @discardableResult
    func upsert(_ product: FundProduct) -> Self {
        lock.lock(); defer { lock.unlock() }
        fundProducts[product.id] = product
        return self
    }

    @discardableResult
    func upsert(_ shareClass: FundShareClass) -> Self {
        lock.lock(); defer { lock.unlock() }
        fundShareClasses[shareClass.id] = shareClass
        return self
    }

    @discardableResult
    func upsert(_ pid: ProviderIdentifier) -> Self {
        lock.lock(); defer { lock.unlock() }
        let key = Self.providerKey(pid.providerID, scheme: pid.identifierScheme, value: pid.identifierValue)
        providerIdentifiers[key] = pid
        return self
    }

    @discardableResult
    func add(_ relationship: InstrumentRelationship) -> Self {
        lock.lock(); defer { lock.unlock() }
        // 按关系的 from 端 Instrument 索引（tracksIndex/issuedBy/adrUnderlying 的源）
        let fromInstrument: InstrumentID
        switch relationship {
        case .tracksIndex(let r): fromInstrument = r.etf
        case .shareClassOf(let r): fromInstrument = r.shareClass.rawValue.isEmpty
            ? InstrumentID(rawValue: "sc_\(r.shareClass.rawValue)")
            : InstrumentID(rawValue: "sc_proxy_\(r.shareClass.rawValue)")  // ShareClass 无 InstrumentID，用代理键
        case .issuedBy(let r): fromInstrument = r.instrument
        case .adrUnderlying(let r): fromInstrument = r.adr
        }
        relationships[fromInstrument, default: []].append(relationship)
        return self
    }

    @discardableResult
    func upsert(_ bar: DailyBar) -> Self {
        lock.lock(); defer { lock.unlock() }
        dailyBars[bar.listingID, default: []].append(bar)
        return self
    }

    @discardableResult
    func upsert(_ nav: NAVObservation) -> Self {
        lock.lock(); defer { lock.unlock() }
        navObservations[nav.shareClassID, default: []].append(nav)
        return self
    }

    @discardableResult
    func upsert(_ snapshot: FundHoldingSnapshot) -> Self {
        lock.lock(); defer { lock.unlock() }
        holdingSnapshots[snapshot.productID, default: []].append(snapshot)
        return self
    }

    @discardableResult
    func upsert(_ macro: MacroObservation) -> Self {
        lock.lock(); defer { lock.unlock() }
        macroObservations[macro.indicatorID, default: []].append(macro)
        return self
    }

    @discardableResult
    func upsert(_ action: CorporateAction) -> Self {
        lock.lock(); defer { lock.unlock() }
        corporateActions[action.listingID, default: []].append(action)
        return self
    }

    // MARK: - InstrumentRepository

    func instrument(_ id: InstrumentID) -> Instrument? {
        lock.lock(); defer { lock.unlock() }
        return instruments[id]
    }

    func listing(_ id: ListingID) -> Listing? {
        lock.lock(); defer { lock.unlock() }
        return listings[id]
    }

    func listings(forInstrument id: InstrumentID) -> [Listing] {
        lock.lock(); defer { lock.unlock() }
        let ids = instrumentsToListings[id] ?? []
        return ids.compactMap { listings[$0] }
    }

    func legalEntity(_ id: LegalEntityID) -> LegalEntity? {
        lock.lock(); defer { lock.unlock() }
        return legalEntities[id]
    }

    func fundProduct(_ id: FundProductID) -> FundProduct? {
        lock.lock(); defer { lock.unlock() }
        return fundProducts[id]
    }

    func fundShareClass(_ id: FundShareClassID) -> FundShareClass? {
        lock.lock(); defer { lock.unlock() }
        return fundShareClasses[id]
    }

    func resolve(providerID: DataProviderID, scheme: String, value: String) -> CanonicalRef? {
        lock.lock(); defer { lock.unlock() }
        let key = Self.providerKey(providerID, scheme: scheme, value: value)
        return providerIdentifiers[key]?.canonical
    }

    func relationships(for instrument: InstrumentID) -> [InstrumentRelationship] {
        lock.lock(); defer { lock.unlock() }
        return relationships[instrument] ?? []
    }

    // MARK: - MarketTimeSeriesRepository

    func dailyBars(listingID: ListingID, context: KnowledgeContext) -> [DailyBar] {
        lock.lock(); defer { lock.unlock() }
        let all = dailyBars[listingID] ?? []
        return Self.filterByContext(all, context: context)
    }

    func dailyBar(listingID: ListingID, on day: Date, context: KnowledgeContext) -> DailyBar? {
        lock.lock(); defer { lock.unlock() }
        let all = dailyBars[listingID] ?? []
        // 筛出 effectiveAt == day 且符合 context 的 vintage，取最新
        let candidates = all.filter { bar in
            Calendar(identifier: .gregorian).isDate(bar.temporalEnvelope.effectiveAt, inSameDayAs: day)
                && Self.contextIncludes(context, envelope: bar.temporalEnvelope)
        }
        return candidates.max { $0.vintage < $1.vintage }
    }

    // MARK: - NAVTimeSeriesRepository

    func navObservations(shareClassID: FundShareClassID, context: KnowledgeContext) -> [NAVObservation] {
        lock.lock(); defer { lock.unlock() }
        let all = navObservations[shareClassID] ?? []
        return Self.filterByContext(all, context: context)
    }

    func navObservation(shareClassID: FundShareClassID, on day: Date, context: KnowledgeContext) -> NAVObservation? {
        lock.lock(); defer { lock.unlock() }
        let all = navObservations[shareClassID] ?? []
        let candidates = all.filter { nav in
            Calendar(identifier: .gregorian).isDate(nav.temporalEnvelope.effectiveAt, inSameDayAs: day)
                && Self.contextIncludes(context, envelope: nav.temporalEnvelope)
        }
        return candidates.max { $0.vintage < $1.vintage }
    }

    // MARK: - FundHoldingRepository

    func holdingSnapshots(productID: FundProductID, context: KnowledgeContext) -> [FundHoldingSnapshot] {
        lock.lock(); defer { lock.unlock() }
        let all = holdingSnapshots[productID] ?? []
        return Self.filterByContext(all, context: context)
    }

    func latestHoldingSnapshot(productID: FundProductID, context: KnowledgeContext) -> FundHoldingSnapshot? {
        let snaps = holdingSnapshots(productID: productID, context: context)
        // effectiveAt 相同时取 vintage 最新（ADR-DATA008：economicKnowledge 取可知最新 vintage）
        return snaps.max {
            if $0.temporalEnvelope.effectiveAt != $1.temporalEnvelope.effectiveAt {
                return $0.temporalEnvelope.effectiveAt < $1.temporalEnvelope.effectiveAt
            }
            return $0.vintage < $1.vintage
        }
    }

    // MARK: - FundamentalRepository（占位，Epic 7+ 扩展）

    // 无方法

    // MARK: - MacroRepository

    func macroObservations(indicatorID: InstrumentID, context: KnowledgeContext) -> [MacroObservation] {
        lock.lock(); defer { lock.unlock() }
        let all = macroObservations[indicatorID] ?? []
        return Self.filterByContext(all, context: context)
    }

    // MARK: - CorporateActionRepository

    func corporateActions(listingID: ListingID, context: KnowledgeContext) -> [CorporateAction] {
        lock.lock(); defer { lock.unlock() }
        let all = corporateActions[listingID] ?? []
        return Self.filterByContext(all, context: context)
    }

    // MARK: - CalendarRepository

    func isTradingDay(_ date: Date, jurisdiction: Jurisdiction) -> Bool {
        calendarBackend.isTradingDay(date, jurisdiction: jurisdiction)
    }

    func tradingDay(after date: Date, offset: Int, jurisdiction: Jurisdiction) -> Date {
        calendarBackend.tradingDay(after: date, offset: offset, jurisdiction: jurisdiction)
    }

    func tradingDayStart(_ date: Date, jurisdiction: Jurisdiction) -> Date {
        calendarBackend.tradingDayStart(date, jurisdiction: jurisdiction)
    }

    // MARK: - Helpers

    /// Provider 映射的稳定 key。
    static func providerKey(_ providerID: DataProviderID, scheme: String, value: String) -> String {
        "\(providerID.rawValue)::\(scheme)::\(value)"
    }

    /// 按 KnowledgeContext 过滤观测序列（泛型，所有 Observation 域共用）。
    static func filterByContext<T: CanonicalObservation>(
        _ observations: [T],
        context: KnowledgeContext
    ) -> [T] {
        observations.filter { contextIncludes(context, envelope: $0.temporalEnvelope) }
            .sorted { $0.vintage < $1.vintage }
    }

    /// 单个 envelope 是否符合 context（包内 helper）。
    static func contextIncludes(_ context: KnowledgeContext, envelope: TemporalEnvelope) -> Bool {
        context.mode.includes(envelope: envelope)
    }
}
