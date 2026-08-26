import Foundation

// MARK: - MarketUniverseBackfill（SYNC-6b：全市场 universe 分批历史回填）
//
// SYNC-6a 回填「持仓 universe」一次跑完；本类型处理 Market Discovery 用的
// 全市场 universe（300+ 行业/指数/资产标的）——规模超出单轮预算，且受
// 免费 Provider 额度约束（DATA006 / FREE001）：
//
// 1. **分批**：每轮最多 `maxTargetsPerRound` 个目标（优先级序——
//    priority 小的先回填），partial completion 是一等公民；
// 2. **进度状态持久化**：sufficient 的标的记入 completedEntries，
//    后续轮次跳过（幂等 + 不重复消耗额度）；覆盖不足的自动留在队列，
//    下轮重试（含 Provider 额度尽当轮 allFailed 的标的）；
// 3. **双通道**：直接抓取标的（美股，经降级链）走 HistoricalBackfill
//    全流程；remote 通道标的（A 股，数据由 RemoteStagingSync +
//    MarketDailySync 提交）只验证覆盖率——「分阶段」语义；
// 4. **universe 增量补全**：universe 是版本化数据文件，新增条目自动
//    进入下轮批次（completed 条目按 key 幂等跳过，重命名/改 key = 新标的）。
//
// universe 内容策展（哪些指数/行业进清单）是 WF-2（Market Discovery）
// 的工作；本引擎只负责回填编排。额度感知不需要单独模型：降级链的
// isCallable 前置闸门 + ProviderHealthMonitor 的 quota 记账已覆盖
// 「AV 25/天耗尽 → 当轮 allFailed → 留队列下轮再试」。

// MARK: - Universe 数据

/// 全市场回填 universe（版本化 JSON 数据，可增量扩充）。
struct MarketUniverse: Codable, Sendable, Equatable {
    /// universe 数据版本（策展修订递增）
    var universeVersion: Int
    var entries: [MarketUniverseEntry]

    init(universeVersion: Int, entries: [MarketUniverseEntry]) {
        self.universeVersion = universeVersion
        self.entries = entries
    }
}

/// 单个 universe 条目。
struct MarketUniverseEntry: Codable, Sendable, Equatable {
    /// 稳定 key（策展侧保证唯一且不变；改名 = 新标的）
    let key: String
    let code: ProviderCode
    let jurisdiction: Jurisdiction
    /// 挂牌交易所（ListingID 的派生输入之一——与生产 IdentitySync 同源）
    let exchange: Exchange
    /// canonical listing（策展时已解析——回填不猜 identity；派生规则与
    /// IdentitySync.establish 的 exchangeSymbolExact 创建路径完全一致：
    /// lst_SHA256(exchange|code) 截断，重复建立幂等）
    let listingID: ListingID
    let displayName: String
    /// 回填优先级（小者先）
    let priority: Int
    /// true = 直接抓取（降级链）；false = remote 通道（只验证覆盖）
    let fetchDirectly: Bool

    init(
        key: String,
        code: ProviderCode,
        jurisdiction: Jurisdiction,
        exchange: Exchange,
        displayName: String,
        priority: Int,
        fetchDirectly: Bool
    ) {
        self.key = key
        self.code = code
        self.jurisdiction = jurisdiction
        self.exchange = exchange
        self.listingID = ListingID(IdentitySync.deriveID(
            "lst", "\(exchange.rawValue)|\(code.value)"))
        self.displayName = displayName
        self.priority = priority
        self.fetchDirectly = fetchDirectly
    }

    /// 旧形态兼容（已持有派生好的 listingID——测试 fixture / 持久化
    /// 数据读回用；生产策展一律走 exchange 派生形态）。
    init(
        key: String,
        code: ProviderCode,
        jurisdiction: Jurisdiction,
        listingID: ListingID,
        displayName: String,
        priority: Int,
        fetchDirectly: Bool
    ) {
        self.key = key
        self.code = code
        self.jurisdiction = jurisdiction
        self.exchange = .platform
        self.listingID = listingID
        self.displayName = displayName
        self.priority = priority
        self.fetchDirectly = fetchDirectly
    }

    /// 生产接线便捷：把条目作为 IdentitySync 建立输入（登记
    /// providerCode→canonical 映射，行情写入行的 listingID 与本条目一致）。
    var identityHint: IdentityHint {
        IdentityHint(
            providerID: DataProviderID(rawValue: "universe-catalog"),
            code: code,
            exchange: exchange,
            displayName: displayName,
            instrumentKind: .exchangeTradedFund,
            assetClass: .equity,
            jurisdiction: jurisdiction
        )
    }
}

// MARK: - 状态与结果

/// MarketUniverseBackfill 的进度状态。
struct MarketUniverseBackfillState: Codable, Sendable, Equatable {
    var version: Int = 1
    /// 覆盖已达标的条目 key（后续轮次跳过，省额度）
    var completedEntries: Set<String> = []
    /// 上轮各条目覆盖数缓存（诊断）
    var coveredDays: [String: Int] = [:]
    /// 公平轮转游标（universe 优先级序中的扫描起点；P1 修复：
    /// 防持续失败条目饿死后续目标）
    var rotationCursor: Int = 0
    var lastRunAt: Date?
}

/// 一轮分批回填的结果。
struct MarketUniverseBackfillRoundResult: Equatable, Sendable {
    /// 本轮批次（entry key 列表，优先级序）
    let batchKeys: [String]
    /// 本轮达标的条目
    var newlyCompleted: [String] = []
    /// 本轮未达标的条目（覆盖不足 / 抓取失败——留队列下轮重试）
    var stillInsufficient: [String] = []
    /// 全 universe 进度（含历史轮次累计）
    var completedCount: Int = 0
    var totalCount: Int = 0
    var coverage: [String: TargetCoverage] = [:]

    var progressSummary: String {
        "universe backfill \(completedCount)/\(totalCount)，本轮批次 \(batchKeys.count)"
    }
}

// MARK: - 引擎

/// 全市场 universe 分批回填引擎。
struct MarketUniverseBackfill: Sendable {

    let backfill: HistoricalBackfill
    let makeChain: @Sendable (MarketUniverseEntry) -> ProviderFallbackChain
    /// 单轮最大目标数（免费额度约束的分批预算）
    var maxTargetsPerRound: Int
    let now: @Sendable () -> Date

    init(
        backfill: HistoricalBackfill,
        makeChain: @escaping @Sendable (MarketUniverseEntry) -> ProviderFallbackChain,
        maxTargetsPerRound: Int = 20,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.backfill = backfill
        self.makeChain = makeChain
        self.maxTargetsPerRound = maxTargetsPerRound
        self.now = now
    }

    /// 跑一轮分批回填（progress state 原子持久化）。
    func syncOnce(
        universe: MarketUniverse,
        spoolURL: URL,
        stateURL: URL
    ) async throws -> MarketUniverseBackfillRoundResult {
        let store = SyncStateStore<MarketUniverseBackfillState>()
        var state = try store.load(from: stateURL) ?? MarketUniverseBackfillState()

        // 批次选择（P1 修复：公平轮转）：沿 universe 优先级序从持久化轮转游标
        // 处起扫，跳过已完成条目、取满预算为止。固定取前 N 会让持续失败的
        // 高优先级条目永久占据批次、饿死后续目标；轮转保证每个未完成条目
        // 在 ceil(pending/budget)+1 轮内必被尝试一次。
        let universeOrdered = universe.entries
            .sorted { lhs, rhs in
                lhs.priority != rhs.priority
                    ? lhs.priority < rhs.priority
                    : lhs.key < rhs.key
            }
        let batch: [MarketUniverseEntry]
        if universeOrdered.isEmpty {
            batch = []
        } else {
            let start = state.rotationCursor % universeOrdered.count
            var picked: [MarketUniverseEntry] = []
            var scanned = 0
            // 单圈扫描：每个条目一轮至多入选一次（两圈会把同一未完成条目
            // 重复塞进批次）；pending 稀疏时批次可短于预算——这是正确行为
            let scanLimit = universeOrdered.count
            while picked.count < maxTargetsPerRound && scanned < scanLimit {
                let entry = universeOrdered[(start + scanned) % universeOrdered.count]
                if !state.completedEntries.contains(entry.key) {
                    picked.append(entry)
                }
                scanned += 1
            }
            batch = picked
            state.rotationCursor = (start + scanned) % universeOrdered.count
        }

        var result = MarketUniverseBackfillRoundResult(batchKeys: batch.map(\.key))

        // 通道分组
        let directTargets = batch.filter(\.fetchDirectly).map { entry in
            BarBackfillTarget(
                code: entry.code, jurisdiction: entry.jurisdiction,
                listingID: entry.listingID, chain: makeChain(entry)
            )
        }
        let remoteTargets = batch.filter { !$0.fetchDirectly }.map { entry in
            BarBackfillTarget(
                code: entry.code, jurisdiction: entry.jurisdiction,
                listingID: entry.listingID,
                chain: ProviderFallbackChain(adapters: [])   // 不抓取，仅占位
            )
        }

        // 直接抓取通道：完整回填（fetch + commit + coverage）
        if !directTargets.isEmpty {
            let direct = await backfill.backfill(
                navFunds: [], barTargets: directTargets, spoolURL: spoolURL
            )
            result.coverage.merge(direct.coverage) { _, new in new }
        }
        // remote 通道：只验证覆盖率（数据由 RemoteStagingSync 链路提交）
        let remoteCoverage = backfill.coverageReport(barTargets: remoteTargets)
        result.coverage.merge(remoteCoverage) { _, new in new }

        // 进度更新
        for entry in batch {
            // P1 修复：coverage key 与 HistoricalBackfill 一致使用 listingID
            let key = "bar|\(entry.listingID.rawValue)"
            guard let coverage = result.coverage[key] else { continue }
            state.coveredDays[entry.key] = coverage.covered
            if coverage.isSufficient {
                state.completedEntries.insert(entry.key)
                result.newlyCompleted.append(entry.key)
            } else {
                result.stillInsufficient.append(entry.key)
            }
        }

        // 全 universe 进度（completed 集合对 universe 求交——universe 收缩时
        // 陈旧完成项不计入）
        let universeKeys = Set(universe.entries.map(\.key))
        result.completedCount = state.completedEntries.intersection(universeKeys).count
        result.totalCount = universe.entries.count

        state.lastRunAt = now()
        try store.save(state, to: stateURL)
        return result
    }
}
