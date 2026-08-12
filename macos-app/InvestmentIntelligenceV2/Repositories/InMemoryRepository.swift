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

    // MARK: - FundamentalRepository
    // Fundamental 域推迟到 REPO-1b（FundamentalObservation 类型未定义），
    // 不在 Repository 聚合协议内，本类无需实现。

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
    ///
    /// 行为（ADR-DATA002 §Decision 2 + ADR-DATA008）：
    /// - `economicKnowledge` / `operationalKnowledge`：先按 mode 过滤可见性，
    ///   再按 `effectiveAt` 分组、每组只保留可见的最新 vintage（防修订版与原版
    ///   同时进入时间序列导致因子重复计算，审查 P1 修复点）。
    ///   若 `context.vintageFilter` 非空且精确匹配某 vintage，则只返回那一条。
    /// - `exactSnapshot`：返回 `effectiveAt == at` 的全部 vintage（不分组、不去重）。
    ///
    /// `preferredProvider` **未生效**：CanonicalObservation 当前不含 sourceProviderID 字段，
    /// 多 Provider 同 (effectiveAt, vintage) 跨源去重无确定性 tie-breaker。
    /// 该能力从 REPO-2 拆到 **REPO-2b**（rollout 2026-08-12 修订），需先给
    /// CanonicalObservation 加 sourceProviderID/provenance，再实现稳定选择规则。
    static func filterByContext<T: CanonicalObservation>(
        _ observations: [T],
        context: KnowledgeContext
    ) -> [T] {
        // 精确 vintage 过滤优先：若指定且匹配，只返回那一条
        if let wanted = context.vintageFilter {
            let matched = observations.filter { $0.vintage == wanted }
            return matched.filter { contextIncludes(context, envelope: $0.temporalEnvelope) }
                .sorted { $0.vintage < $1.vintage }
        }

        switch context.mode {
        case .exactSnapshot:
            // 返回该 effectiveAt 的全部 vintage，按 vintage 排序
            return observations
                .filter { contextIncludes(context, envelope: $0.temporalEnvelope) }
                .sorted { $0.vintage < $1.vintage }
        case .economicKnowledge, .operationalKnowledge:
            // 先按可见性过滤
            // swiftlint:disable:next identifier_name
            let visible = observations.filter { contextIncludes(context, envelope: $0.temporalEnvelope) }
            // 按 effectiveAt 分组，每组只保留最新 vintage
            var latestPerDay: [Date: T] = [:]
            for obs in visible {
                let day = obs.temporalEnvelope.effectiveAt
                if let existing = latestPerDay[day] {
                    if obs.vintage > existing.vintage { latestPerDay[day] = obs }
                } else {
                    latestPerDay[day] = obs
                }
            }
            return latestPerDay.values.sorted {
                $0.temporalEnvelope.effectiveAt < $1.temporalEnvelope.effectiveAt
            }
        }
    }

    /// 单个 envelope 是否符合 context 的可见性部分（包内 helper）。
    static func contextIncludes(_ context: KnowledgeContext, envelope: TemporalEnvelope) -> Bool {
        context.mode.includes(envelope: envelope)
    }
}
