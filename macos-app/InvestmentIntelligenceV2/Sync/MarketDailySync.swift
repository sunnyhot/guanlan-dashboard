import Foundation

// MARK: - MarketDailySync（SYNC-2：行情收盘后增量——stocks/ETF/indexes）
//
// 两条数据通道合在一轮（rollout SYNC-2）：
// 1. **直接抓取**（美股日线：Stooq primary → Alpha Vantage secondary，
//    M2 已验证的候选链）：经 `ProviderFallbackChain`（SYNC-7）抓取 →
//    结构分桶 → 直接抓取 spool → 四防火墙 commit；
// 2. **远程 staging 提交**（A 股行情经 AKShare collector → RemoteStagingProvider
//    落 remote spool——本引擎不直接抓 A 股）：`commitRecords(fromSpool:)`
//    把 remote spool 的新记录提交进 canonical（幂等，重复行不翻倍）。
//    该 spool 由 App 侧 RemoteStagingSyncLoop 维护（PROV-3b 接线），
//    本引擎只消费。
//
// 锚点语义与 SYNC-3 同构但**法域感知**：MarketClose policy 的
// availableAt = startOfDay(next(T))，故「保证已公布」的最新 bar 日期 =
// asOf 所在（或之前最近）交易日的**前一个**交易日（美股按 NYSE 日历、
// A 股按 SSE 日历——直接抓取目标只有美股；A 股走 remote 通道不需要锚点）。
//
// 游标保守推进规则同 SYNC-3（干净轮推进 / 无新数据与拒收不推进）；
// 全 Provider 失败 = local 兜底（.allProvidersFailed，游标不动，下轮重试）。

// MARK: - 状态与结果

/// MarketDailySync 的增量游标状态。
struct MarketDailySyncState: Codable, Sendable, Equatable {
    var version: Int = 1
    /// "scheme|value" → 最后入库 bar 的 effectiveAt（直接抓取通道）
    var lastIngestedEffectiveDates: [String: Date] = [:]
    var lastRunAt: Date?
}

/// 单标的（直接抓取通道）一轮的结局。
enum MarketDailySyncOutcome: Equatable, Sendable {
    case upToDate
    case committed(recordCount: Int, newCursor: Date, usedRole: ProviderFallbackCandidate.Role)
    case noNewData(windowFrom: Date, windowThrough: Date)
    case rejectedCursorHeld(committedCount: Int, rejectionCount: Int)
    /// 全候选失败——local 兜底（游标不动，读取面不受影响）
    case allProvidersFailed(summary: String)
}

/// 一轮 sync 的汇总结果。
struct MarketDailySyncRoundResult: Equatable, Sendable {
    var outcomes: [String: MarketDailySyncOutcome] = [:]
    var rejections: [CanonicalPipeline.Rejection] = []
    /// 远程 staging spool 的提交结果（nil = spool 不存在/未配置，正常形态）
    var remoteSpoolCommit: CanonicalPipeline.CommitResult?
}

/// 单个直接抓取目标。
struct MarketDailyTarget: Sendable {
    let code: ProviderCode
    let jurisdiction: Jurisdiction
    let chain: ProviderFallbackChain

    init(code: ProviderCode, jurisdiction: Jurisdiction, chain: ProviderFallbackChain) {
        self.code = code
        self.jurisdiction = jurisdiction
        self.chain = chain
    }
}

// MARK: - 引擎

/// 行情收盘后增量同步引擎。
struct MarketDailySync: Sendable {

    let pipeline: CanonicalPipeline
    let marketCalendar: HolidayTableTradingCalendar
    let now: @Sendable () -> Date
    /// 首轮（无游标）回看的日历天数（深度回填走 SYNC-6）
    var initialLookbackCalendarDays: Int

    init(
        pipeline: CanonicalPipeline,
        marketCalendar: HolidayTableTradingCalendar = .bundled,
        now: @escaping @Sendable () -> Date = { .now },
        initialLookbackCalendarDays: Int = 400
    ) {
        self.pipeline = pipeline
        self.marketCalendar = marketCalendar
        self.now = now
        self.initialLookbackCalendarDays = initialLookbackCalendarDays
    }

    /// 跑一轮收盘后增量。
    ///
    /// - Parameter remoteSpoolURL: 远程 staging spool（RemoteStagingSyncPaths
    ///   产出）。文件不存在 = 远程通道未启用，正常跳过（nil 结果）。
    func syncOnce(
        targets: [MarketDailyTarget],
        spoolURL: URL,
        stateURL: URL,
        remoteSpoolURL: URL?
    ) async throws -> MarketDailySyncRoundResult {
        // 通道 2：remote spool → canonical（幂等；文件级读取失败上抛——
        // spool 存在但读不出是数据质量事件，不静默跳过）
        var remoteCommit: CanonicalPipeline.CommitResult?
        if let remoteSpoolURL, FileManager.default.fileExists(atPath: remoteSpoolURL.path) {
            remoteCommit = try pipeline.commitRecords(fromSpool: remoteSpoolURL)
        }

        // 通道 1：直接抓取（美股候选链）
        let store = SyncStateStore<MarketDailySyncState>()
        var state = try store.load(from: stateURL) ?? MarketDailySyncState()
        var result = MarketDailySyncRoundResult(remoteSpoolCommit: remoteCommit)

        for target in targets {
            let key = "\(target.code.scheme)|\(target.code.value)"
            let outcome = await syncTarget(
                target, key: key, state: &state, spoolURL: spoolURL, result: &result
            )
            result.outcomes[key] = outcome
        }

        // remote 拒收也进汇总（诊断单一出口）
        if let remoteCommit {
            result.rejections.append(contentsOf: remoteCommit.rejections)
        }

        state.lastRunAt = now()
        try store.save(state, to: stateURL)
        return result
    }

    // MARK: - 单目标一轮

    private func syncTarget(
        _ target: MarketDailyTarget,
        key: String,
        state: inout MarketDailySyncState,
        spoolURL: URL,
        result: inout MarketDailySyncRoundResult
    ) async -> MarketDailySyncOutcome {
        // 「保证已公布」的最新 bar 日期（MarketClose T+1 语义，法域感知）
        let anchor = marketCalendar.previousTradingDay(
            before: marketCalendar.latestTradingDayOnOrBefore(now(), jurisdiction: target.jurisdiction),
            jurisdiction: target.jurisdiction
        )

        if let cursor = state.lastIngestedEffectiveDates[key], cursor >= anchor {
            return .upToDate
        }

        let windowFrom: Date
        if let cursor = state.lastIngestedEffectiveDates[key] {
            windowFrom = cursor.addingTimeInterval(86_400)
        } else {
            windowFrom = anchor.addingTimeInterval(-Double(initialLookbackCalendarDays) * 86_400)
        }

        let fallback = await target.chain.fetch(code: target.code, from: windowFrom, to: anchor)
        guard case .succeeded(let success) = fallback else {
            guard case .allFailed = fallback else {
                return .allProvidersFailed(summary: "未知降级结局")
            }
            // local 兜底：游标不动，下轮重试；读取面继续本地 canonical
            return .allProvidersFailed(summary: fallback.localFallbackSummary)
        }

        let barRecords = success.records.filter { $0.kind == .dailyBar }
        guard barRecords.isEmpty == false else {
            return .noNewData(windowFrom: windowFrom, windowThrough: anchor)
        }

        let partition = ProviderRecordSchemaValidator().partition(barRecords)
        guard partition.valid.isEmpty == false else {
            if !partition.invalid.isEmpty {
                return .rejectedCursorHeld(committedCount: 0, rejectionCount: partition.invalid.count)
            }
            return .noNewData(windowFrom: windowFrom, windowThrough: anchor)
        }

        do {
            _ = try ProviderStagingWriter().append(partition.valid, to: spoolURL)
        } catch {
            return .allProvidersFailed(summary: "spool 追加失败：\(error)")
        }

        let commitResult = pipeline.commit(records: partition.valid)
        if let commitError = commitResult.commitError {
            return .allProvidersFailed(summary: "commit 事务失败（整批回滚）：\(commitError)")
        }

        let targetRejections = commitResult.rejections.filter {
            $0.scheme == target.code.scheme && $0.value == target.code.value
        }
        result.rejections.append(contentsOf: commitResult.rejections)
        if !targetRejections.isEmpty {
            return .rejectedCursorHeld(
                committedCount: commitResult.committedCount, rejectionCount: targetRejections.count
            )
        }

        let newCursor = partition.valid.map(\.effectiveAt).max()!
        state.lastIngestedEffectiveDates[key] = newCursor
        return .committed(
            recordCount: commitResult.committedCount,
            newCursor: newCursor,
            usedRole: success.usedRole
        )
    }
}
