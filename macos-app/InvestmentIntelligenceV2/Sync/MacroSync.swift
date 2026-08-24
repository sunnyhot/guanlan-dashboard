import Foundation

// MARK: - MacroSync（SYNC-5：FRED 宏观指标同步，daily/weekly 节奏）
//
// 与 SYNC-3/4 的关键差异——**宏观序列会修订**（FRED real-time vintage：
// 同一 effectiveAt 的值随再发布更新，ADR-DATA008）：
// 1. 抓取窗口不做 effectiveAt 截断（full history）：修订可能落在任何历史期，
//    按「新 effectiveAt」截窗口会漏修订。FRED 端点本就返回全序列；
// 2. 幂等与修订的分工（确定性派生保证）：同 ObservationID 同内容 →
//    幂等归并不翻倍；再发布（realtime_start/publishedAt 变）→ 新 vintage
//    行，economic 查询取最新修订、exactSnapshot 保留历史版本；
// 3. 游标（lastIngestedEffectiveAt）只用于**结果报告**（新观测计数）与
//    upToDate 判断，不约束抓取窗口；
// 4. 节奏 gate（daily/weekly）：per-series `refreshInterval`，未到期跳过
//    （.skippedCadence，零网络）；季频序列配周检、日频序列配日检由
//    调用方在 target 里声明。
//
// 失败语义同 SYNC-3/4：series 粒度隔离、ProviderHealth 上报、
// isCallable == false 跳过。

// MARK: - 状态与结果

/// MacroSync 的增量状态。
struct MacroSyncState: Codable, Sendable, Equatable {
    var version: Int = 1
    /// seriesID → 上轮 sync 完成时刻（节奏 gate）
    var lastSyncedAt: [String: Date] = [:]
    /// seriesID → 已见最大 effectiveAt（结果报告用，不约束抓取窗口）
    var lastIngestedEffectiveAt: [String: Date] = [:]
    var lastRunAt: Date?
}

/// 单序列一轮 sync 的结局。
enum MacroSyncOutcome: Equatable, Sendable {
    /// 距上轮未满 refreshInterval——本轮跳过（零网络）
    case skippedCadence
    /// 满节奏但无新观测（全序列与上轮一致——幂等重放零新行）
    case upToDate
    /// 有新观测：本轮提交记录数 + 新 effectiveAt 计数 + 新游标
    /// （修订行不含在 newEffectiveDates 里，见 exactSnapshot / vintage）
    case committed(recordCount: Int, newEffectiveDates: Int, newCursor: Date)
    /// Provider 不可调用
    case providerNotCallable
    /// 抓取 / 持久化失败
    case failed(reason: String)
}

/// 一轮 sync 的汇总结果。
struct MacroSyncRoundResult: Equatable, Sendable {
    var outcomes: [String: MacroSyncOutcome] = [:]
    var rejections: [CanonicalPipeline.Rejection] = []
}

/// 单个同步目标（一个 FRED 序列 + 它的节奏与 adapter）。
struct MacroSyncTarget: Sendable {
    /// 序列代码（fred_series scheme）
    let code: ProviderCode
    /// 该序列的 FRED adapter（config 驱动，一个序列一个实例）
    let adapter: any ProviderAdapter
    /// 刷新节奏（秒）：日频序列配 86_400、季频配 604_800 量级，
    /// 未到期跳过
    let refreshInterval: TimeInterval

    init(
        code: ProviderCode,
        adapter: any ProviderAdapter,
        refreshInterval: TimeInterval
    ) {
        self.code = code
        self.adapter = adapter
        self.refreshInterval = refreshInterval
    }
}

// MARK: - 引擎

/// FRED 宏观指标同步引擎。
struct MacroSync: Sendable {

    let pipeline: CanonicalPipeline
    let healthMonitor: ProviderHealthMonitor?
    let now: @Sendable () -> Date

    init(
        pipeline: CanonicalPipeline,
        healthMonitor: ProviderHealthMonitor? = nil,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.pipeline = pipeline
        self.healthMonitor = healthMonitor
        self.now = now
    }

    /// 跑一轮宏观 sync（series 粒度隔离）。
    func syncOnce(
        targets: [MacroSyncTarget],
        spoolURL: URL,
        stateURL: URL
    ) async throws -> MacroSyncRoundResult {
        let store = SyncStateStore<MacroSyncState>()
        var state = try store.load(from: stateURL) ?? MacroSyncState()
        var result = MacroSyncRoundResult()

        for target in targets {
            let outcome = await syncTarget(
                target, state: &state, spoolURL: spoolURL, result: &result
            )
            result.outcomes[target.code.value] = outcome
        }

        state.lastRunAt = now()
        try store.save(state, to: stateURL)
        return result
    }

    private func syncTarget(
        _ target: MacroSyncTarget,
        state: inout MacroSyncState,
        spoolURL: URL,
        result: inout MacroSyncRoundResult
    ) async -> MacroSyncOutcome {
        let providerID = target.adapter.providerID

        // 节奏 gate：未到期零网络
        if let last = state.lastSyncedAt[target.code.value],
           now().timeIntervalSince(last) < target.refreshInterval {
            return .skippedCadence
        }

        if let monitor = healthMonitor, await !monitor.isCallable(providerID) {
            return .providerNotCallable
        }

        // 全窗口抓取（修订可能落在任何历史期，见文件头）
        let fetched: ProviderFetchResult
        do {
            fetched = try await target.adapter.fetchWithDiagnostics(
                code: target.code, from: .distantPast, to: now()
            )
        } catch let error as ProviderError {
            await healthMonitor?.recordFailure(providerID, error: error)
            return .failed(reason: "\(error)")
        } catch {
            let mapped = ProviderError.unavailable(providerID: providerID, underlying: "\(error)")
            await healthMonitor?.recordFailure(providerID, error: mapped)
            return .failed(reason: "\(mapped)")
        }
        let records = fetched.records.filter { $0.kind == .macroObservation }

        let partition = ProviderRecordSchemaValidator().partition(records)
        guard partition.valid.isEmpty == false else {
            if !partition.invalid.isEmpty {
                await healthMonitor?.recordSchemaDrift(providerID)
                return .failed(reason: "结构分桶全部非法（\(partition.invalid.count) 条）")
            }
            return .upToDate
        }

        do {
            _ = try ProviderStagingWriter().append(partition.valid, to: spoolURL)
        } catch {
            return .failed(reason: "spool 追加失败：\(error)")
        }

        let commitResult = pipeline.commit(records: partition.valid)
        if let commitError = commitResult.commitError {
            return .failed(reason: "commit 事务失败（整批回滚）：\(commitError)")
        }
        result.rejections.append(contentsOf: commitResult.rejections)
        if !commitResult.rejections.isEmpty {
            // 拒收不算失败（数据质量事件），但本轮节奏时间戳不推进，
            // 下轮重新全量（幂等），拒收明细在 round 级报告
            await healthMonitor?.recordSuccess(providerID)
            return .failed(reason: "有 \(commitResult.rejections.count) 条拒收（见 rejections）")
        }

        let cursor = state.lastIngestedEffectiveAt[target.code.value]
        let newDates = partition.valid.filter { record in
            guard let cursor else { return true }
            return record.effectiveAt > cursor
        }.count
        await healthMonitor?.recordSuccess(providerID)

        // 节奏时间戳与报告游标在干净轮推进
        state.lastSyncedAt[target.code.value] = now()
        if let maxEffective = partition.valid.map(\.effectiveAt).max() {
            state.lastIngestedEffectiveAt[target.code.value] = maxEffective
            if newDates > 0 {
                return .committed(
                    recordCount: commitResult.committedCount,
                    newEffectiveDates: newDates,
                    newCursor: maxEffective
                )
            }
        }
        return .upToDate
    }
}
