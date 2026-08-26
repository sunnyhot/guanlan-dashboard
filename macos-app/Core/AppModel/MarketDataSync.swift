import Foundation

// MARK: - 市场数据生产接线（十八轮审查 P1-1）
//
// Market Discovery（WF-2）的 FactorEngine 只读 GRDB `daily_bars`，但
// HistoricalBackfill / MarketUniverseBackfill / MarketDailySync 此前只有
// 测试调用点——生产上没有任何入口把日线写进库，「立即扫描」必然全量
// coverage gap。本文件补生产供给闭环：
//
// 1. `MarketDataMaintenanceEngine`：一轮数据维护 = identity 建立 →
//    universe 分批回填（SYNC-6b，直抓美股 252 交易日历史）→ 收盘后
//    增量（SYNC-2，含 remote staging spool → canonical 提交，A 股通道）；
// 2. App 侧 6 小时维护循环（与 RemoteStagingSyncLoop 同节奏）；
// 3. `runMarketDiscovery` 扫描前先行维护（首轮点扫描即得真实数据）。
//
// 降级语义与既有引擎一致：单标的失败不阻断（ProviderFallbackChain local
// 兜底、游标不动下轮重试）；维护失败不阻断扫描（降级为 coverage gap，
// 报告显式记录缺口，不猜数据）。A 股条目走 remote 通道（默认关闭，
// 部署 VPS collector 或本地 AKShare collector 后自动进入 spool → 增量
// 提交）；通道未启用时 A 股条目保持 coverage gap——这是 ADR-DATA010
// 的 opt-in 设计，不是缺陷。

// MARK: - 维护引擎

/// 一轮市场数据维护（纯编排，全部复用既有同步引擎）。
struct MarketDataMaintenanceEngine: Sendable {

    let repository: GRDBRepository
    let dataDirectory: URL
    let chainFactory: @Sendable (MarketUniverseEntry) -> ProviderFallbackChain

    /// 生产降级链工厂：Stooq primary（免费无 key）→ Alpha Vantage
    /// secondary（配置了 key 才挂——quota 感知由 ProviderHealthMonitor 承担）。
    static func productionChainFactory(
        healthMonitor: ProviderHealthMonitor,
        alphaVantage: AlphaVantageSettings?
    ) -> @Sendable (MarketUniverseEntry) -> ProviderFallbackChain {
        let alphaVantage = alphaVantage?.isConfigured == true ? alphaVantage : nil
        return { _ in
            var adapters: [any ProviderAdapter] = [
                StooqProviderAdapter(fetcher: URLSessionResponseFetcher())
            ]
            if let alphaVantage {
                adapters.append(
                    AlphaVantageProviderAdapter(
                        client: AlphaVantageClient(), settings: alphaVantage
                    )
                )
            }
            return ProviderFallbackChain(adapters: adapters, healthMonitor: healthMonitor)
        }
    }

    /// App 侧 Alpha Vantage 配置（启用开关 UserDefaults + key Keychain，
    /// 与 WF-1 的 ResearchSourcesConfiguration 同源同 key）。
    static func productionAlphaVantageSettings() -> AlphaVantageSettings {
        let enabled = UserDefaults.standard.object(
            forKey: IntelligenceV2ProviderSettings.alphaVantageEnabledKey
        ) as? Bool ?? true
        let apiKey = KeychainHelper.get(
            account: KeychainHelper.Account.alphaVantageKey) ?? ""
        return AlphaVantageSettings(
            enabled: enabled,
            apiKey: apiKey,
            dailyRequestLimit: AlphaVantageSettings.freeDailyRequestLimit
        )
    }

    /// 跑一轮维护：establish → 回填（至多 `backfillRounds` 批次，批次空即
    /// 收敛）→ 收盘增量（含 remote spool 提交）。返回人可读摘要（诊断面）。
    func runMaintenance(backfillRounds: Int) async throws -> String {
        try DirectSyncPaths.ensureDirectories(in: dataDirectory)

        try Self.establishUniverseIdentity(repository: repository)

        let pipeline = CanonicalPipeline(
            repository: repository, calendar: HolidayTableTradingCalendar.bundled
        )

        // 通道 1：universe 分批回填（部分完成是一等公民；批次空 = 全部
        // 达标或彻底无候选，提前收敛）
        let backfillSpool = DirectSyncPaths.spoolURL(
            name: "market-universe-backfill", in: dataDirectory)
        let backfillState = DirectSyncPaths.stateURL(
            name: "market-universe-backfill", in: dataDirectory)
        let universeBackfill = MarketUniverseBackfill(
            backfill: HistoricalBackfill(
                pipeline: pipeline, repository: repository
            ),
            makeChain: chainFactory
        )
        var completedCount = 0
        var totalCount = MarketUniverseCatalog.v1.entries.count
        for _ in 0 ..< max(backfillRounds, 0) {
            let round = try await universeBackfill.syncOnce(
                universe: MarketUniverseCatalog.v1,
                spoolURL: backfillSpool,
                stateURL: backfillState
            )
            completedCount = round.completedCount
            totalCount = round.totalCount
            if round.batchKeys.isEmpty { break }
        }

        // 通道 2：收盘后增量（直抓标的）+ remote staging spool 提交（A 股）。
        // 首轮回看收窄到 30 天（十九轮 P3-2）：≥252 交易日的深度历史是回填
        // 通道的职责（覆盖不足自动留队列重试），默认 400 天窗口与回填窗口
        // 重叠会让首轮对同一段历史重复抓取 + 重复过四防火墙管道（幂等但
        // 浪费带宽与 AV 降级额度）；更早的空洞仍由回填轮负责补齐
        let dailySync = MarketDailySync(
            pipeline: pipeline,
            initialLookbackCalendarDays: 30
        )
        let directTargets = MarketUniverseCatalog.v1.entries
            .filter(\.fetchDirectly)
            .map { entry in
                MarketDailyTarget(
                    code: entry.code,
                    jurisdiction: entry.jurisdiction,
                    chain: chainFactory(entry)
                )
            }
        let dailyRound = try await dailySync.syncOnce(
            targets: directTargets,
            spoolURL: DirectSyncPaths.spoolURL(name: "market-daily", in: dataDirectory),
            stateURL: DirectSyncPaths.stateURL(name: "market-daily", in: dataDirectory),
            remoteSpoolURL: RemoteStagingSyncPaths.spoolURL(in: dataDirectory)
        )
        let upToDate = dailyRound.outcomes.values.filter {
            if case .upToDate = $0 { return true }
            return false
        }.count

        return "universe 覆盖 \(completedCount)/\(totalCount)，增量通道 \(upToDate)/\(directTargets.count) 就绪"
    }

    /// universe 的 identity 建立 hints（幂等）。
    ///
    /// 关键纪律（十八轮 P1-1）：IdentityResolver 按 (provider, scheme, value)
    /// 查表——直抓标的必须按**真实数据 Provider**（stooq primary /
    /// alphaVantage secondary）登记，只登记清单自身的 universe-catalog 会让
    /// 行情行全部卡在 identity 防火墙。listingID 按 exchange|code 确定性派生
    ///（与 MarketUniverseEntry.listingID 同公式），stooq 创建模式先建实体链，
    /// alphaVantage 经 exchangeSymbolExact（路径 2）匹配到同一 Listing。
    /// remote 通道标的（A 股）的数据 Provider 随部署形态而定（collector 侧
    /// 登记），这里仅登记清单 hint。
    static func establishUniverseIdentity(repository: GRDBRepository) throws {
        var hints: [IdentityHint] = []
        for entry in MarketUniverseCatalog.v1.entries {
            if entry.fetchDirectly {
                for provider in [DataProviderID.stooq, .alphaVantage] {
                    hints.append(IdentityHint(
                        providerID: provider,
                        code: entry.code,
                        exchange: entry.exchange,
                        displayName: entry.displayName,
                        instrumentKind: .exchangeTradedFund,
                        assetClass: .equity,
                        jurisdiction: entry.jurisdiction
                    ))
                }
            } else {
                hints.append(entry.identityHint)
            }
        }
        _ = try IdentitySync(repository: repository).establish(hints: hints)
    }
}

// MARK: - 因子快照批量缓冲（原每条目一个写事务 → 整轮单事务）

/// 线程安全的 FactorSnapshot 缓冲（snapshotSink 回调在 workflow 循环内
/// 逐条触发，缓冲后由调用方一次性落库——十八轮审查 P2）。
final class FactorSnapshotBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [FactorSnapshot] = []

    func append(_ snapshot: FactorSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        snapshots.append(snapshot)
    }

    func drain() -> [FactorSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        let drained = snapshots
        snapshots = []
        return drained
    }
}

// MARK: - 维护轮串行门（十九轮 P3-1）

/// 进程内维护轮串行化：6h 循环与「立即扫描」的先行维护共享同一组 sync
/// state 文件（SyncStateStore 的 load→save 是非原子 read-modify-write），
/// 并发轮会互踩游标（回退 / 重复抓取浪费额度）。入队操作按到达顺序链式
/// 执行；库写入幂等兜底语义不变，串行门消除的是进程内自扰。
actor MarketDataMaintenanceGate {
    private var tail: Task<Void, Never> = Task {}

    /// 入队并等待本轮完成（含此前排队的所有轮）。
    func run(_ operation: @escaping @Sendable () async -> Void) async {
        let previous = tail
        let chained = Task {
            await previous.value
            await operation()
        }
        tail = chained
        await chained.value
    }
}

/// 维护结果跨隔离区回传（gate 的 operation 闭包无返回值通道）。
final class MarketDataMaintenanceResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<String, Error>?

    var result: Result<String, Error>? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

// MARK: - AppModel 集成（6 小时维护循环）

extension AppModel {

    /// 维护周期：与 RemoteStagingSyncLoop 同节奏（服务端日级发布 / Stooq
    /// 日线日级更新，6 小时一轮当天内必命中新数据）。
    static let marketDataSyncInterval: TimeInterval = 6 * 60 * 60

    /// 启动市场数据维护循环（幂等；runtime 未就绪 = 短退避重试——
    /// bootstrap 异步开库中，首轮不因早启而空转到下个周期）。每轮失败只
    /// 更新诊断摘要，不弹错误、不重试硬冲。
    @MainActor
    func startMarketDataSyncLoopIfNeeded() {
        guard marketDataSyncTask == nil else { return }
        marketDataSyncTask = Task.detached(priority: .utility) { [weak self] in
            let interval = UInt64(Self.marketDataSyncInterval * 1_000_000_000)
            while !Task.isCancelled {
                let didRun = await self?.runSerializedMarketDataMaintenance(backfillRounds: 1)
                    ?? false
                do {
                    try await Task.sleep(
                        nanoseconds: didRun ? interval : 2_000_000_000
                    )
                } catch {
                    return   // 任务被取消
                }
            }
        }
    }

    /// 经串行门执行一轮维护（十九轮 P3-1：6h 循环与扫描前维护互斥，state
    /// 文件不被并发 read-modify-write）。返回 false = runtime / 数据目录未
    /// 就绪；收敛摘要（含失败文案）统一写入 latestMarketDataSyncSummary。
    @MainActor
    @discardableResult
    func runSerializedMarketDataMaintenance(backfillRounds: Int) async -> Bool {
        guard let runtime = intelligenceRuntime,
              let dataDirectory = dataDirectoryURL else { return false }
        let chainFactory = marketDataChainFactoryOverride
            ?? MarketDataMaintenanceEngine.productionChainFactory(
                healthMonitor: marketProviderHealthMonitor,
                alphaVantage: MarketDataMaintenanceEngine.productionAlphaVantageSettings()
            )
        let engine = MarketDataMaintenanceEngine(
            repository: runtime.repository,
            dataDirectory: dataDirectory,
            chainFactory: chainFactory
        )
        let box = MarketDataMaintenanceResultBox()
        await marketDataMaintenanceGate.run {
            do {
                box.result = .success(
                    try await engine.runMaintenance(backfillRounds: backfillRounds)
                )
            } catch {
                box.result = .failure(error)
            }
        }
        switch box.result {
        case .success(let summary):
            latestMarketDataSyncSummary = summary
        case .failure(let error):
            // 维护失败不阻断任何读取面（库是本地积累的派生物）——只记诊断
            latestMarketDataSyncSummary = "市场数据维护失败：\(error.localizedDescription)"
        case nil:
            break   // gate.run 已等待完成，不可达
        }
        return true
    }
}
