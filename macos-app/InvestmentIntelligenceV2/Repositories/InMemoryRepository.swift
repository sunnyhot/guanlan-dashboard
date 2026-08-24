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
/// 线程安全：所有可变存储的读写都经由 `lock`（NSLock）串行化。
/// Swift 6 严格并发默认不允许 `Sendable` class 持有 `var` 存储属性——
/// 编译器无法证明 NSLock 能覆盖所有路径。这里显式声明 `@unchecked Sendable`，
/// 责任在维护者：**任何新增的可变存储属性都必须经由 `lock.lock(); defer { lock.unlock() }` 访问**。
/// 未来如需更高吞吐可换 actor / Mutex；M2 阶段 lock 足够。
final class InMemoryRepository: @unchecked Sendable, Repository {
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
    private var fundamentals: [LegalEntityID: [FundamentalObservation]] = [:]

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
        // 幂等：只在首次登记时追加到 instrument→listings 索引（重复 upsert 同一
        // listing 不产生重复条目，审查 P2 修复点）
        var ids = instrumentsToListings[listing.instrumentID, default: []]
        if !ids.contains(listing.id) { ids.append(listing.id) }
        instrumentsToListings[listing.instrumentID] = ids
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
        dailyBars[bar.listingID, default: []] = Self.upsertObservation(
            dailyBars[bar.listingID, default: []], bar
        )
        return self
    }

    @discardableResult
    func upsert(_ nav: NAVObservation) -> Self {
        lock.lock(); defer { lock.unlock() }
        navObservations[nav.shareClassID, default: []] = Self.upsertObservation(
            navObservations[nav.shareClassID, default: []], nav
        )
        return self
    }

    @discardableResult
    func upsert(_ snapshot: FundHoldingSnapshot) -> Self {
        lock.lock(); defer { lock.unlock() }
        holdingSnapshots[snapshot.productID, default: []] = Self.upsertObservation(
            holdingSnapshots[snapshot.productID, default: []], snapshot
        )
        return self
    }

    @discardableResult
    func upsert(_ macro: MacroObservation) -> Self {
        lock.lock(); defer { lock.unlock() }
        macroObservations[macro.indicatorID, default: []] = Self.upsertObservation(
            macroObservations[macro.indicatorID, default: []], macro
        )
        return self
    }

    @discardableResult
    func upsert(_ action: CorporateAction) -> Self {
        lock.lock(); defer { lock.unlock() }
        corporateActions[action.listingID, default: []] = Self.upsertObservation(
            corporateActions[action.listingID, default: []], action
        )
        return self
    }

    @discardableResult
    func upsert(_ fundamental: FundamentalObservation) -> Self {
        lock.lock(); defer { lock.unlock() }
        fundamentals[fundamental.entityID, default: []] = Self.upsertObservation(
            fundamentals[fundamental.entityID, default: []], fundamental
        )
        return self
    }

    /// 幂等 upsert helper：按 observation.id 替换已存在的同 id 条目，
    /// 否则追加。重复 upsert 同一条 observation 不会产生重复（审查 P2 修复点）。
    private static func upsertObservation<T: CanonicalObservation>(
        _ existing: [T], _ observation: T
    ) -> [T] {
        var result = existing
        if let idx = result.firstIndex(where: { $0.id == observation.id }) {
            result[idx] = observation
        } else {
            result.append(observation)
        }
        return result
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
        // 防火墙 1 入口：fuzzyCandidate 不能直接返回 canonical
        // （ADR-DATA001 §Decision 3：fuzzy 只产 candidate，必须经 Verification）
        lock.lock(); defer { lock.unlock() }
        let key = Self.providerKey(providerID, scheme: scheme, value: value)
        guard let pid = providerIdentifiers[key], pid.resolutionMethod.isAuthoritative else {
            return nil
        }
        return pid.canonical
    }

    func relationships(for instrument: InstrumentID) -> [InstrumentRelationship] {
        lock.lock(); defer { lock.unlock() }
        return relationships[instrument] ?? []
    }

    /// 导出所有已登记的 ProviderIdentifier（供 IdentityResolver 构造）。
    func allProviderIdentifiers() -> [ProviderIdentifier] {
        lock.lock(); defer { lock.unlock() }
        return Array(providerIdentifiers.values)
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

    // MARK: - FundamentalRepository（REPO-1b）

    func fundamentalObservations(
        entityID: LegalEntityID,
        metricKey: String?,
        context: KnowledgeContext
    ) -> [FundamentalObservation] {
        lock.lock(); defer { lock.unlock() }
        var all = fundamentals[entityID] ?? []
        if let metricKey {
            all = all.filter { $0.metricKey == metricKey }
        }
        // 分组键含 (metricKey, unit, periodStart, periodEnd)：revenue 与 assets
        // 同 periodEnd、Q2 与 H1 区间同 periodEnd 都不互相覆盖——它们是不同事实；
        // 同期间的多次申报（修订）在同一组内按 vintage 择新（ADR-DATA008）。
        return Self.filterByContext(all, context: context) { obs in
            FundamentalPeriodKey(
                metricKey: obs.metricKey,
                unit: obs.unit,
                periodStart: obs.periodStart,
                periodEnd: obs.periodEnd
            )
        }
    }

    /// 基本面事实的期间身份（economic 查询的分组键，REPO-1b）。
    private struct FundamentalPeriodKey: Hashable {
        let metricKey: String
        let unit: String
        let periodStart: Date?
        let periodEnd: Date
    }

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
    //
    // 查询语义（filterByContext / isPreferred / ...）自 GRDB-7 起抽到
    // ObservationQuerySemantics（InMemory 与 GRDB 共用的单一权威）；
    // 本类保留同名 static 薄转发，既有调用点与测试不需改动。

    /// Provider 映射的稳定 key。
    static func providerKey(_ providerID: DataProviderID, scheme: String, value: String) -> String {
        "\(providerID.rawValue)::\(scheme)::\(value)"
    }

    /// 按 KnowledgeContext 过滤观测序列（语义见 `ObservationQuerySemantics`）。
    static func filterByContext<T: CanonicalObservation>(
        _ observations: [T],
        context: KnowledgeContext,
        grouping: (T) -> AnyHashable = { $0.temporalEnvelope.effectiveAt }
    ) -> [T] {
        ObservationQuerySemantics.filterByContext(observations, context: context, grouping: grouping)
    }

    /// 同 effectiveAt 分组内的择优比较（语义见 `ObservationQuerySemantics`）。
    static func isPreferred<T: CanonicalObservation>(candidate: T, over existing: T) -> Bool {
        ObservationQuerySemantics.isPreferred(candidate: candidate, over: existing)
    }

    static func reliabilityPreferenceRank(_ cls: ProviderReliabilityClass) -> Int {
        ObservationQuerySemantics.reliabilityPreferenceRank(cls)
    }

    static func providerSortKey(_ rawValue: String) -> String {
        ObservationQuerySemantics.providerSortKey(rawValue)
    }

    /// 单个 envelope 是否符合 context 的可见性部分。
    static func contextIncludes(_ context: KnowledgeContext, envelope: TemporalEnvelope) -> Bool {
        ObservationQuerySemantics.contextIncludes(context, envelope: envelope)
    }
}
