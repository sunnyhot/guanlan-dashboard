import Foundation
import GRDB

// MARK: - GRDBRepository（GRDB-7，Canonical Store 的 Repository 实现）
//
// 八域 Repository 协议的 GRDB 实现，替代 InMemoryRepository 进入生产
//（M4 验收：Repository 契约不变；InMemory 时代的 golden test 同样过）。
//
// **行为等价的结构保证**：PIT 过滤 / multi-vintage 择优 / 跨源去重不经手写
// SQL 重实现——SQL 只做「维度键取行」（WHERE listing_id = ? 这类索引点查），
// 读回 domain 后统一走 `ObservationQuerySemantics`（与 InMemoryRepository
// 共用的单一权威）。golden test 以 parity 形式守护（GRDBRepositoryParityTests：
// 同一 fixture 灌进两套实现，所有查询 API 在多种 context 下输出必须相等）。
//
// **写入语义**（显式冲突语义，一轮审查后废弃 INSERT OR REPLACE）：按
// (维度, effectiveAt, vintage, provider) 身份键（v7 唯一索引列集）先行查旧：
// 同身份且业务内容相同（指纹排除摄入元数据与代理键）→ 幂等，保留最早
// ingestedAt；同身份但内容不同 → 拒收 `observationContentConflict`（更正应
// 携带新 publishedAt 走新 vintage，静默覆盖 = 篡改历史）；无旧行 → 插入。
// 身份键不含 ObservationID——同一事实经不同 identifier alias 摄入（派生
// 不同 ID）仍按业务身份幂等归并。
//
// **错误策略**（协议方法非 throwing，读取失败不能上抛）：
// - 打不开库 / 查询抛错 / 行解码 fail-closed（枚举列被外部改坏等）：
//   该次查询返回空，错误记入 `lastQueryError`（线程安全诊断面，App 接线后
//   对齐 RemoteStagingSyncStatus 的诊断模式）。空 = 缺口语义（ADR-DATA006），
//   不伪造数据；诊断可查，不静默。
// - 写入方法保留 throws（Builder 风格调用方必须处理；FK 违例 = identity
//   未登记，正是要暴露的管道错误）。

/// Canonical Store 的八域 Repository 实现。
///
/// 线程安全：`CanonicalDatabase` 的 `DatabaseQueue` 串行化所有读写；
/// 唯一可变状态 `_lastQueryError` 经 `lock` 保护（与 InMemoryRepository
/// 同款 NSLock 约定：新增可变存储必须走 lock）。
final class GRDBRepository: @unchecked Sendable, Repository {

    /// 持有的库（internal：测试 / 诊断路径需要原生 SQL 注入模拟外部改库场景；
    /// 生产代码走 Repository API 与 commit 入口，不绕过防火墙）。
    let database: CanonicalDatabase
    private let calendarBackend: TradingCalendar
    private let lock = NSLock()
    private var _lastQueryError: String?

    init(database: CanonicalDatabase, calendarBackend: TradingCalendar) {
        self.database = database
        self.calendarBackend = calendarBackend
    }

    /// 最近一次查询失败的人类可读诊断（nil = 无失败）。
    /// 诊断面：读取失败按缺口语义返回空，这里留下可查的痕迹（不静默）。
    var lastQueryError: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastQueryError
    }

    private func recordQueryFailure(_ operation: String, _ error: Error) {
        lock.lock(); defer { lock.unlock() }
        _lastQueryError = "\(operation): \(error)"
    }

    /// 读 helper：包一层错误策略（失败 → 诊断 + nil）。
    private func read<T>(_ operation: String, _ body: (Database) throws -> T) -> T? {
        do {
            return try database.queue.read(body)
        } catch {
            recordQueryFailure(operation, error)
            return nil
        }
    }

    /// 点查 helper：body 本身可返回 nil（未命中）的版本——避免 T 绑定到
    /// Optional 产生双重 Optional。
    private func readOptional<T>(_ operation: String, _ body: (Database) throws -> T?) -> T? {
        do {
            return try database.queue.read(body)
        } catch {
            recordQueryFailure(operation, error)
            return nil
        }
    }

    // MARK: - 写入（Builder 风格，与 InMemoryRepository 对齐；Fixture loader /
    // GRDB-8 Pipeline / 测试灌数据用）

    /// 观测写入的冲突语义（审查 P1 修复：重摄入不得篡改历史可知边界）。
    ///
    /// 原 INSERT OR REPLACE 整行覆盖——同一历史记录稍后重抓时 ingestedAt 被
    /// 改写，`operationalKnowledge(asOf:)` 的历史结果漂移。新语义（按
    /// (维度, effectiveAt, vintage, provider) 身份键）：
    /// 1. **同身份同内容**（除 ingestedAt 外全列相等）：保留**最早** ingestedAt
    ///    （晚到的重摄入不推迟历史可知边界；更早的补录会前移到真实首抓时间）；
    /// 2. **同身份不同内容**：拒收（`observationContentConflict`）——同 vintage
    ///    内容变化不是幂等重摄入，静默覆盖 = 篡改历史；更正应携带新
    ///    publishedAt 走新 vintage（Pipeline 的确定性派生保证）；
    /// 3. **无既有行**：普通插入。
    private func insertObservationRow<Row: CanonicalObservationRow>(
        _ row: Row,
        table: String,
        identityWhere: String,
        identityArguments: [DatabaseValueConvertible],
        in db: Database
    ) throws {
        if let existing = try Row.fetchOne(
            db,
            sql: "SELECT * FROM \(table) WHERE \(identityWhere)",
            arguments: StatementArguments(identityArguments)
        ) {
            guard try Self.contentFingerprint(row) == Self.contentFingerprint(existing) else {
                throw GRDBRepositoryError.observationContentConflict(
                    observationID: row.id, table: table
                )
            }
            if row.envelope.ingestedAt < existing.envelope.ingestedAt {
                try db.execute(
                    sql: "UPDATE \(table) SET ingested_at = ? WHERE \(identityWhere)",
                    arguments: StatementArguments([row.envelope.ingestedAt] + identityArguments)
                )
            }
            return
        }
        try row.insert(db)
    }

    /// 内容指纹：观测**业务内容**列的确定性拼接（列名排序）。
    ///
    /// 排除三类非业务内容列：
    /// - 摄入元数据（重放必然变化）：`ingested_at`（本机首抓时间，有自己的
    ///   保留规则，见写入语义注释）、`policy_derived_at`（availableAt 推导
    ///   时刻，TemporalNormalizer 取当时 now——纳入会让幂等重放永远判冲突）；
    /// - **代理键**（二轮审查 P1）：`id`（ObservationID 由 Provider identifier
    ///   派生——同一事实经同 Provider 的另一个精确 alias 摄入会派生不同 ID，
    ///   Canonical 身份与业务内容相同，纳入指纹会误判内容冲突）、
    ///   `snapshot_id`（持仓子行指向父行的代理外键，同理）。
    private static func contentFingerprint<Row: EncodableRecord>(_ row: Row) throws -> String {
        // databaseDictionary：列名 → DatabaseValue（GRDB 公开 API）；
        // DatabaseValue.description 是 SQL 字面量渲染，确定性
        var parts: [String] = []
        for (key, value) in try row.databaseDictionary
        where key != "ingested_at" && key != "policy_derived_at"
            && key != "id" && key != "snapshot_id" {
            parts.append(key + "=" + value.description)
        }
        parts.sort()
        return parts.joined(separator: "|")
    }

    /// 观测身份键（v7 唯一索引的列集；各表维度列不同）。
    private static func observationIdentity(
        dimension: String,
        dimensionValue: String,
        envelope: ObservationEnvelopeColumns
    ) -> (whereSQL: String, arguments: [DatabaseValueConvertible]) {
        (
            whereSQL: "\(dimension) = ? AND effective_at = ? AND vintage_announcement_date = ? AND vintage_publisher_version = ? AND source_provider_id = ?",
            arguments: [
                dimensionValue,
                envelope.effectiveAt,
                envelope.vintageAnnouncementDate,
                envelope.vintagePublisherVersion,
                envelope.sourceProviderID,
            ]
        )
    }

    @discardableResult
    func upsert(_ entity: LegalEntity) throws -> Self {
        try database.queue.write { db in
            try LegalEntityRow.from(entity).insert(db, onConflict: .replace)
        }
        return self
    }

    @discardableResult
    func upsert(_ instrument: Instrument) throws -> Self {
        try database.queue.write { db in
            try InstrumentRow.from(instrument).insert(db, onConflict: .replace)
        }
        return self
    }

    @discardableResult
    func upsert(_ listing: Listing) throws -> Self {
        try database.queue.write { db in
            try ListingRow.from(listing).insert(db, onConflict: .replace)
        }
        return self
    }

    @discardableResult
    func upsert(_ product: FundProduct) throws -> Self {
        try database.queue.write { db in
            try FundProductRow.from(product).insert(db, onConflict: .replace)
        }
        return self
    }

    @discardableResult
    func upsert(_ shareClass: FundShareClass) throws -> Self {
        try database.queue.write { db in
            try FundShareClassRow.from(shareClass).insert(db, onConflict: .replace)
        }
        return self
    }

    @discardableResult
    func upsert(_ pid: ProviderIdentifier) throws -> Self {
        try database.queue.write { db in
            // 审查 P2 修复：polymorphic canonical 目标的事务内存在性验证——
            // 悬空的 authoritative 映射会通过 resolver，直到观测提交时触发 FK
            // 回滚整个合法子批次。在登记处拦截（同一事务）。
            try Self.assertCanonicalTargetExists(pid.canonical, in: db)
            try ProviderIdentifierRow.from(pid).insert(db, onConflict: .replace)
        }
        return self
    }

    /// canonical 目标实体在其对应表必须已存在（provider_identifiers 的
    /// polymorphic 引用没有 FK 可用，应用层事务内兜底）。
    private static func assertCanonicalTargetExists(_ ref: CanonicalRef, in db: Database) throws {
        let table: String
        switch ref {
        case .legalEntity: table = "legal_entities"
        case .instrument: table = "instruments"
        case .listing: table = "listings"
        case .fundProduct: table = "fund_products"
        case .fundShareClass: table = "fund_share_classes"
        }
        let exists = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE id = ?)",
            arguments: [ref.entityIDRawValue]
        ) ?? false
        guard exists else {
            throw GRDBRepositoryError.danglingCanonicalTarget(
                entityType: ref.entityType, entityID: ref.entityIDRawValue
            )
        }
    }

    @discardableResult
    func add(_ relationship: InstrumentRelationship) throws -> Self {
        try database.queue.write { db in
            try InstrumentRelationshipRow.from(relationship).insert(db, onConflict: .replace)
        }
        return self
    }

    @discardableResult
    func upsert(_ bar: DailyBar) throws -> Self {
        try database.queue.write { db in
            try insertObservation(.dailyBar(bar), in: db)
        }
        return self
    }

    @discardableResult
    func upsert(_ nav: NAVObservation) throws -> Self {
        try database.queue.write { db in
            try insertObservation(.navObservation(nav), in: db)
        }
        return self
    }

    @discardableResult
    func upsert(_ snapshot: FundHoldingSnapshot) throws -> Self {
        try database.queue.write { db in
            try insertHoldingSnapshot(snapshot, in: db)
        }
        return self
    }
    @discardableResult
    func upsert(_ macro: MacroObservation) throws -> Self {
        try database.queue.write { db in
            try insertObservation(.macroObservation(macro), in: db)
        }
        return self
    }

    @discardableResult
    func upsert(_ action: CorporateAction) throws -> Self {
        try database.queue.write { db in
            try insertObservation(.corporateAction(action), in: db)
        }
        return self
    }

    @discardableResult
    func upsert(_ fundamental: FundamentalObservation) throws -> Self {
        try database.queue.write { db in
            try insertFundamental(fundamental, in: db)
        }
        return self
    }
    // MARK: - 批量提交（GRDB-8 Pipeline 的 Canonical Commit 入口）

    /// 单事务提交一批 CanonicalObservation。
    ///
    /// Pipeline 的四防火墙（schema / identity+temporal / data validation /
    /// 本方法的 FK 约束兜底）都在写入路径上。
    ///
    /// **错误分档**（审查 P1 修复后）：
    /// - 内容冲突（同身份不同内容的重摄入）：**逐条拒收**，返回冲突清单，
    ///   批内其余照常提交（不静默覆盖历史）；
    /// - FK 违例等库级错误：抛错，**整批回滚**（Canonical Store 不留半批）。
    ///
    /// - Returns: 被拒收的内容冲突清单（已跳过、未写入）。
    @discardableResult
    func commit(_ observations: [CanonicalObservationKind]) throws -> [GRDBRepositoryError] {
        try database.queue.write { db in
            var conflicts: [GRDBRepositoryError] = []
            for kind in observations {
                do {
                    try insertObservation(kind, in: db)
                } catch let conflict as GRDBRepositoryError {
                    conflicts.append(conflict)
                }
            }
            return conflicts
        }
    }

    /// 按观测类型分派（公开 upsert 与 Pipeline commit 共用同一实现，
    /// 保证两路径的冲突语义一致）。
    private func insertObservation(_ kind: CanonicalObservationKind, in db: Database) throws {
        switch kind {
        case .dailyBar(let bar):
            let row = try DailyBarRow.from(bar)
            let identity = Self.observationIdentity(
                dimension: "listing_id", dimensionValue: row.listingID, envelope: row.envelope
            )
            try insertObservationRow(row, table: "daily_bars",
                                     identityWhere: identity.whereSQL,
                                     identityArguments: identity.arguments, in: db)
        case .navObservation(let nav):
            let row = try NAVObservationRow.from(nav)
            let identity = Self.observationIdentity(
                dimension: "share_class_id", dimensionValue: row.shareClassID, envelope: row.envelope
            )
            try insertObservationRow(row, table: "nav_observations",
                                     identityWhere: identity.whereSQL,
                                     identityArguments: identity.arguments, in: db)
        case .fundHoldingSnapshot(let snapshot):
            try insertHoldingSnapshot(snapshot, in: db)
        case .macroObservation(let macro):
            let row = try MacroObservationRow.from(macro)
            let identity = Self.observationIdentity(
                dimension: "indicator_id", dimensionValue: row.indicatorID, envelope: row.envelope
            )
            try insertObservationRow(row, table: "macro_observations",
                                     identityWhere: identity.whereSQL,
                                     identityArguments: identity.arguments, in: db)
        case .corporateAction(let action):
            let row = try CorporateActionRow.from(action)
            let identity = Self.observationIdentity(
                dimension: "listing_id", dimensionValue: row.listingID, envelope: row.envelope
            )
            try insertObservationRow(row, table: "corporate_actions",
                                     identityWhere: identity.whereSQL,
                                     identityArguments: identity.arguments, in: db)
        case .fundamentalObservation(let fundamental):
            try insertFundamental(fundamental, in: db)
        }
    }

    /// 持仓快照写入（骨架 + positions 全组的内容比对，见 upsert 语义注释）。
    private func insertHoldingSnapshot(_ snapshot: FundHoldingSnapshot, in db: Database) throws {
        let row = FundHoldingSnapshotRow.from(snapshot)
        let newPositions = snapshot.positions.enumerated().map {
            FundHoldingPositionRow.from($1, snapshotID: snapshot.id, index: $0)
        }
        let identity = Self.observationIdentity(
            dimension: "product_id", dimensionValue: row.productID, envelope: row.envelope
        )
        if let existing = try FundHoldingSnapshotRow.fetchOne(
            db,
            sql: "SELECT * FROM holding_snapshots WHERE \(identity.whereSQL)",
            arguments: StatementArguments(identity.arguments)
        ) {
            let existingPositions = try FundHoldingPositionRow.fetchAll(
                db,
                sql: "SELECT * FROM holding_positions WHERE snapshot_id = ? ORDER BY position_index",
                arguments: [existing.id]
            )
            let skeletonEqual = try Self.contentFingerprint(row) == Self.contentFingerprint(existing)
            let positionsEqual = try existingPositions.map(Self.contentFingerprint)
                == newPositions.map(Self.contentFingerprint)
            guard skeletonEqual && positionsEqual else {
                throw GRDBRepositoryError.observationContentConflict(
                    observationID: row.id, table: "holding_snapshots"
                )
            }
            if row.envelope.ingestedAt < existing.envelope.ingestedAt {
                try db.execute(
                    sql: "UPDATE holding_snapshots SET ingested_at = ? WHERE \(identity.whereSQL)",
                    arguments: StatementArguments([row.envelope.ingestedAt] + identity.arguments)
                )
            }
            return
        }
        try row.insert(db)
        for positionRow in newPositions {
            try positionRow.insert(db)
        }
    }

    /// 基本面事实写入（身份键 = REPO-1b 期间分组语义）。
    private func insertFundamental(_ fundamental: FundamentalObservation, in db: Database) throws {
        let row = FundamentalObservationRow.from(fundamental)
        // 事实身份键（period_start NULL 经 COALESCE 封口，与 v5/v7 唯一索引一致）
        let identityWhere = """
            entity_id = ? AND metric_key = ? AND unit = ?             AND COALESCE(period_start, '') = COALESCE(?, '') AND period_end = ?             AND vintage_announcement_date = ? AND vintage_publisher_version = ?             AND source_provider_id = ?
            """
        let identityArguments: [DatabaseValueConvertible] = [
            row.entityID, row.metricKey, row.unit, row.periodStart ?? "", row.periodEnd,
            row.envelope.vintageAnnouncementDate, row.envelope.vintagePublisherVersion,
            row.envelope.sourceProviderID,
        ]
        try insertObservationRow(row, table: "fundamental_observations",
                                 identityWhere: identityWhere,
                                 identityArguments: identityArguments, in: db)
    }

    // MARK: - InstrumentRepository

    func instrument(_ id: InstrumentID) -> Instrument? {
        readOptional("instrument(\(id.rawValue))") { db in
            try InstrumentRow.fetchOne(db, key: id.rawValue)?.toDomain()
        }
    }

    func listing(_ id: ListingID) -> Listing? {
        readOptional("listing(\(id.rawValue))") { db in
            try ListingRow.fetchOne(db, key: id.rawValue)?.toDomain()
        }
    }

    func listings(forInstrument id: InstrumentID) -> [Listing] {
        read("listings(forInstrument: \(id.rawValue))") { db in
            try ListingRow
                .fetchAll(db, sql: "SELECT * FROM listings WHERE instrument_id = ?", arguments: [id.rawValue])
                .map { try $0.toDomain() }
        } ?? []
    }

    func legalEntity(_ id: LegalEntityID) -> LegalEntity? {
        readOptional("legalEntity(\(id.rawValue))") { db in
            try LegalEntityRow.fetchOne(db, key: id.rawValue)?.toDomain()
        }
    }

    func allInstruments() -> [Instrument] {
        read("allInstruments") { db in
            try InstrumentRow.fetchAll(db).map { try $0.toDomain() }
        } ?? []
    }

    func allListings() -> [Listing] {
        read("allListings") { db in
            try ListingRow.fetchAll(db).map { try $0.toDomain() }
        } ?? []
    }

    func allLegalEntities() -> [LegalEntity] {
        read("allLegalEntities") { db in
            try LegalEntityRow.fetchAll(db).map { try $0.toDomain() }
        } ?? []
    }

    func fundProduct(_ id: FundProductID) -> FundProduct? {
        readOptional("fundProduct(\(id.rawValue))") { db in
            try FundProductRow.fetchOne(db, key: id.rawValue)?.toDomain()
        }
    }

    func fundShareClass(_ id: FundShareClassID) -> FundShareClass? {
        readOptional("fundShareClass(\(id.rawValue))") { db in
            try FundShareClassRow.fetchOne(db, key: id.rawValue)?.toDomain()
        }
    }

    func resolve(providerID: DataProviderID, scheme: String, value: String) -> CanonicalRef? {
        // 防火墙 1 入口：fuzzyCandidate 不能直接返回 canonical
        //（ADR-DATA001 §Decision 3，与 InMemoryRepository 同语义）
        readOptional("resolve(\(providerID.rawValue),\(scheme),\(value))") { db in
            guard let row = try ProviderIdentifierRow.fetchOne(
                db,
                sql: """
                SELECT * FROM provider_identifiers
                WHERE provider_id = ? AND identifier_scheme = ? AND identifier_value = ?
                """,
                arguments: [providerID.rawValue, scheme, value]
            ) else { return nil }
            let pid = try row.toDomain()
            return pid.resolutionMethod.isAuthoritative ? pid.canonical : nil
        }
    }

    func relationships(for instrument: InstrumentID) -> [InstrumentRelationship] {
        // 按关系的 from 端 Instrument 索引（tracksIndex.etf / issuedBy.instrument /
        // adrUnderlying.adr 的源端；shareClassOf 的源是 ShareClass，不在此列）
        read("relationships(for: \(instrument.rawValue))") { db in
            try InstrumentRelationshipRow
                .fetchAll(
                    db,
                    sql: """
                    SELECT * FROM instrument_relationships
                    WHERE source_type = 'instrument' AND source_id = ?
                    ORDER BY id
                    """,
                    arguments: [instrument.rawValue]
                )
                .map { try $0.toDomain() }
        } ?? []
    }

    /// 导出所有已登记的 ProviderIdentifier（供 IdentityResolver 构造）。
    func allProviderIdentifiers() -> [ProviderIdentifier] {
        read("allProviderIdentifiers") { db in
            try ProviderIdentifierRow
                .fetchAll(db, sql: "SELECT * FROM provider_identifiers ORDER BY provider_id, identifier_scheme, identifier_value")
                .map { try $0.toDomain() }
        } ?? []
    }

    // MARK: - MarketTimeSeriesRepository

    func dailyBars(listingID: ListingID, context: KnowledgeContext) -> [DailyBar] {
        let all: [DailyBar] = read("dailyBars(\(listingID.rawValue))") { db in
            try DailyBarRow
                .fetchAll(db, sql: "SELECT * FROM daily_bars WHERE listing_id = ? ORDER BY effective_at, id", arguments: [listingID.rawValue])
                .map { try $0.toDomain() }
        } ?? []
        return ObservationQuerySemantics.filterByContext(all, context: context)
    }

    func dailyBar(listingID: ListingID, on day: Date, context: KnowledgeContext) -> DailyBar? {
        // 审查 P1 修复：单点查询复用完整 context 择优语义（vintageFilter /
        // preferredProvider / 跨源 tie-break），与 InMemoryRepository 共用
        // selectPointObservation——不再是「mode 过滤 + 最大 vintage」的旁路。
        let all: [DailyBar] = read("dailyBars(\(listingID.rawValue))") { db in
            try DailyBarRow
                .fetchAll(db, sql: "SELECT * FROM daily_bars WHERE listing_id = ? ORDER BY effective_at, id", arguments: [listingID.rawValue])
                .map { try $0.toDomain() }
        } ?? []
        let sameDay = all.filter { bar in
            Calendar(identifier: .gregorian).isDate(bar.temporalEnvelope.effectiveAt, inSameDayAs: day)
        }
        return ObservationQuerySemantics.selectPointObservation(sameDay, context: context)
    }

    // MARK: - NAVTimeSeriesRepository

    func navObservations(shareClassID: FundShareClassID, context: KnowledgeContext) -> [NAVObservation] {
        let all: [NAVObservation] = read("navObservations(\(shareClassID.rawValue))") { db in
            try NAVObservationRow
                .fetchAll(db, sql: "SELECT * FROM nav_observations WHERE share_class_id = ? ORDER BY effective_at, id", arguments: [shareClassID.rawValue])
                .map { try $0.toDomain() }
        } ?? []
        return ObservationQuerySemantics.filterByContext(all, context: context)
    }

    func navObservation(shareClassID: FundShareClassID, on day: Date, context: KnowledgeContext) -> NAVObservation? {
        // 审查 P1 修复：见 dailyBar 注释
        let all: [NAVObservation] = read("navObservations(\(shareClassID.rawValue))") { db in
            try NAVObservationRow
                .fetchAll(db, sql: "SELECT * FROM nav_observations WHERE share_class_id = ? ORDER BY effective_at, id", arguments: [shareClassID.rawValue])
                .map { try $0.toDomain() }
        } ?? []
        let sameDay = all.filter { nav in
            Calendar(identifier: .gregorian).isDate(nav.temporalEnvelope.effectiveAt, inSameDayAs: day)
        }
        return ObservationQuerySemantics.selectPointObservation(sameDay, context: context)
    }

    // MARK: - FundHoldingRepository

    func holdingSnapshots(productID: FundProductID, context: KnowledgeContext) -> [FundHoldingSnapshot] {
        let assembled: [FundHoldingSnapshot] = read("holdingSnapshots(\(productID.rawValue))") { db in
            try FundHoldingSnapshotRow
                .fetchAll(db, sql: "SELECT * FROM holding_snapshots WHERE product_id = ? ORDER BY effective_at, id", arguments: [productID.rawValue])
                .map { row -> FundHoldingSnapshot in
                    let skeleton = try row.toDomain()
                    let positions = try FundHoldingPositionRow
                        .fetchAll(
                            db,
                            sql: "SELECT * FROM holding_positions WHERE snapshot_id = ? ORDER BY position_index",
                            arguments: [row.id]
                        )
                        .map { try $0.toDomain() }
                    return FundHoldingSnapshot(
                        id: skeleton.id,
                        productID: skeleton.productID,
                        temporalEnvelope: skeleton.temporalEnvelope,
                        availabilityProvenance: skeleton.availabilityProvenance,
                        dataQuality: skeleton.dataQuality,
                        vintage: skeleton.vintage,
                        reportPeriod: skeleton.reportPeriod,
                        positions: positions,
                        disclosedWeightTotal: skeleton.disclosedWeightTotal
                    )
                }
        } ?? []
        return ObservationQuerySemantics.filterByContext(assembled, context: context)
    }

    func latestHoldingSnapshot(productID: FundProductID, context: KnowledgeContext) -> FundHoldingSnapshot? {
        let snaps = holdingSnapshots(productID: productID, context: context)
        return snaps.max {
            if $0.temporalEnvelope.effectiveAt != $1.temporalEnvelope.effectiveAt {
                return $0.temporalEnvelope.effectiveAt < $1.temporalEnvelope.effectiveAt
            }
            return $0.vintage < $1.vintage
        }
    }

    // MARK: - FundamentalRepository

    func fundamentalObservations(
        entityID: LegalEntityID,
        metricKey: String?,
        context: KnowledgeContext
    ) -> [FundamentalObservation] {
        let all: [FundamentalObservation] = read("fundamentalObservations(\(entityID.rawValue))") { db in
            let sql = """
                SELECT * FROM fundamental_observations
                WHERE entity_id = ?\(metricKey != nil ? " AND metric_key = ?" : "")
                """
            let args: [DatabaseValueConvertible] = metricKey.map { [entityID.rawValue, $0] } ?? [entityID.rawValue]
            return try FundamentalObservationRow
                .fetchAll(db, sql: sql + " ORDER BY effective_at, id", arguments: StatementArguments(args))
                .map { try $0.toDomain() }
        } ?? []
        return ObservationQuerySemantics.filterByContext(all, context: context) { obs in
            FundamentalPeriodKey(
                metricKey: obs.metricKey,
                unit: obs.unit,
                periodStart: obs.periodStart,
                periodEnd: obs.periodEnd
            )
        }
    }

    /// 基本面事实的期间身份（economic 查询的分组键，REPO-1b；与 InMemory 同键）。
    private struct FundamentalPeriodKey: Hashable {
        let metricKey: String
        let unit: String
        let periodStart: Date?
        let periodEnd: Date
    }

    // MARK: - MacroRepository

    func macroObservations(indicatorID: InstrumentID, context: KnowledgeContext) -> [MacroObservation] {
        let all: [MacroObservation] = read("macroObservations(\(indicatorID.rawValue))") { db in
            try MacroObservationRow
                .fetchAll(db, sql: "SELECT * FROM macro_observations WHERE indicator_id = ? ORDER BY effective_at, id", arguments: [indicatorID.rawValue])
                .map { try $0.toDomain() }
        } ?? []
        return ObservationQuerySemantics.filterByContext(all, context: context)
    }

    // MARK: - CorporateActionRepository

    func corporateActions(listingID: ListingID, context: KnowledgeContext) -> [CorporateAction] {
        let all: [CorporateAction] = read("corporateActions(\(listingID.rawValue))") { db in
            try CorporateActionRow
                .fetchAll(db, sql: "SELECT * FROM corporate_actions WHERE listing_id = ? ORDER BY effective_at, id", arguments: [listingID.rawValue])
                .map { try $0.toDomain() }
        } ?? []
        return ObservationQuerySemantics.filterByContext(all, context: context)
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
}

// MARK: - 观测行协议（冲突检测需要读 id 与 envelope）

/// GRDBRepository 内部写入路径对观测行的一致视图（全部观测表 row 已满足）。
protocol CanonicalObservationRow: FetchableRecord, PersistableRecord {
    var id: String { get }
    var envelope: ObservationEnvelopeColumns { get }
}

extension DailyBarRow: CanonicalObservationRow {}
extension NAVObservationRow: CanonicalObservationRow {}
extension FundHoldingSnapshotRow: CanonicalObservationRow {}
extension MacroObservationRow: CanonicalObservationRow {}
extension CorporateActionRow: CanonicalObservationRow {}
extension FundamentalObservationRow: CanonicalObservationRow {}

// MARK: - 错误

enum GRDBRepositoryError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 同 (维度, effectiveAt, vintage, provider) 已有**不同内容**的行——
    /// 同 vintage 内容变化不是幂等重摄入，拒绝静默覆盖（审查 P1）；
    /// 更正应携带新 publishedAt 走新 vintage。
    case observationContentConflict(observationID: String, table: String)
    /// provider identifier 指向未登记的 canonical 实体（审查 P2：登记事务内验证）。
    case danglingCanonicalTarget(entityType: String, entityID: String)

    var description: String {
        switch self {
        case .observationContentConflict(let id, let table):
            return "GRDBRepository: \(table) 行 \(id) 同身份重摄入但内容不同，拒绝覆盖"
        case .danglingCanonicalTarget(let type, let id):
            return "GRDBRepository: provider identifier 指向不存在的 \(type) \(id)"
        }
    }
}
