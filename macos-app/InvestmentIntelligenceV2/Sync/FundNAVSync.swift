import Foundation

// MARK: - FundNAVSync（SYNC-3：基金净值增量同步）
//
// 每轮语义（fund 粒度隔离，单只失败不影响他者）：
// 1. 抓取锚点 = `FundNAVPublicationCalendar.latestGuaranteedPublishedNAVDate`
//    （T+1 保守语义，SYNC-1）——游标 ≥ 锚点直接跳过；
// 2. 增量窗口 [游标+1 天, 锚点]（首轮回看 initialLookbackCalendarDays，
//    覆盖 ≥252 交易日；深度回填走 SYNC-6a）；
// 3. fetch → SchemaValidator 分桶 → 合法记录 **先 append spool**（ADR-DATA004：
//    spool 是事实源）→ CanonicalPipeline.commit（四防火墙）；
// 4. 游标推进规则（保守）：
//    - 本轮干净（无拒收、commit 成功、有记录）→ 推进到本轮最大 effectiveAt；
//    - Provider 无新数据（QDII T+2 滞后 / 抓取窗口空）→ 游标不动，下轮重试；
//    - 有防火墙拒收或 commit 失败 → 游标不动（已提交行靠确定性 ID 幂等去重，
//      重试不翻倍；跳过被拒收的日期会造成静默数据洞，宁可重抓）。
// 5. ProviderHealthMonitor 上报（PROV-8）：成功 recordSuccess、失败
//    recordFailure；isCallable == false（unavailable）时本轮跳过抓取。
//
// 与 App 的集成时点遵守 rollout B.3：本引擎在 V2 内（无 UI / 无 AppModel 引用），
// App 侧调度循环在 Epic 9 集成时接线（参照 RemoteStagingSyncLoop 模式）。

// MARK: - 状态与结果

/// FundNAVSync 的增量游标状态（JSON 原子持久化）。
struct FundNAVSyncState: Codable, Sendable, Equatable {
    /// 状态格式版本（前向兼容：升版解码失败 fail-closed 抛错，不静默当空）
    var version: Int = 1
    /// fundCode → 最后成功入库的 NAV effectiveAt（游标）
    var lastIngestedEffectiveDates: [String: Date] = [:]
    var lastRunAt: Date?
}

/// 单只基金一轮 sync 的结局。
enum FundNAVSyncOutcome: Equatable, Sendable {
    /// 游标已 ≥ 锚点（本轮无需抓取）
    case upToDate
    /// 干净入库：新记录数 + 推进后的游标 + 上游丢弃的异常行数（透传诊断）
    case committed(recordCount: Int, newCursor: Date, droppedMalformed: Int)
    /// 窗口内 Provider 无数据（如 QDII T+2 滞后）——游标不动，下轮重试
    case noNewData(windowFrom: Date, windowThrough: Date)
    /// 本轮不完整（防火墙拒收 / 上游丢行）——已提交行保留（幂等），但游标
    /// 保守不动：droppedMalformed > 0 或混有 invalid 记录时，中间日期可能
    /// 缺失，推进会永久跳过它们
    case rejectedCursorHeld(committedCount: Int, rejectionCount: Int, droppedMalformed: Int)
    /// Provider 不可调用（健康监控 unavailable）——本轮跳过
    case providerNotCallable
    /// 抓取 / 持久化失败——游标不动，单只隔离
    case failed(reason: String)
}

/// 一轮 sync 的汇总结果。
struct FundNAVSyncRoundResult: Equatable, Sendable {
    /// 本轮的公布锚点（latestGuaranteedPublishedNAVDate）
    let anchor: Date
    /// fundCode → 结局
    var outcomes: [String: FundNAVSyncOutcome] = [:]
    /// 本轮全部防火墙拒收（跨基金汇总，诊断用）
    var rejections: [CanonicalPipeline.Rejection] = []
}

// MARK: - 引擎

/// 基金净值增量同步引擎（天天基金 NAV 链，REPO-7 adapter）。
struct FundNAVSync: Sendable {

    let adapter: any ProviderAdapter
    let pipeline: CanonicalPipeline
    let publicationCalendar: FundNAVPublicationCalendar
    let healthMonitor: ProviderHealthMonitor?
    let now: @Sendable () -> Date
    /// 首轮（无游标）回看的日历天数
    var initialLookbackCalendarDays: Int

    init(
        adapter: any ProviderAdapter,
        pipeline: CanonicalPipeline,
        publicationCalendar: FundNAVPublicationCalendar = FundNAVPublicationCalendar(),
        healthMonitor: ProviderHealthMonitor? = nil,
        now: @escaping @Sendable () -> Date = { .now },
        initialLookbackCalendarDays: Int = 400
    ) {
        self.adapter = adapter
        self.pipeline = pipeline
        self.publicationCalendar = publicationCalendar
        self.healthMonitor = healthMonitor
        self.now = now
        self.initialLookbackCalendarDays = initialLookbackCalendarDays
    }

    /// 跑一轮增量 sync。
    ///
    /// - state 文件不存在 → 首轮（全量回看窗口）；读不出/解不出 → 抛
    ///   `SyncStateError`（fail-closed，不把坏状态当空状态重抓）。
    /// - spool 追加 / state 写入失败 → 抛错（游标未持久化，下轮重抓，
    ///   幂等语义保证不翻倍）。
    /// - 返回逐基金结局；单只基金失败不影响他者。
    func syncOnce(
        funds: [ProviderCode],
        spoolURL: URL,
        stateURL: URL
    ) async throws -> FundNAVSyncRoundResult {
        let store = SyncStateStore<FundNAVSyncState>()
        var state = try store.load(from: stateURL) ?? FundNAVSyncState()
        let anchor = publicationCalendar.latestGuaranteedPublishedNAVDate(asOf: now())
        var result = FundNAVSyncRoundResult(anchor: anchor)

        for fund in funds {
            guard fund.scheme == "fund_code" else {
                result.outcomes[fund.value] = .failed(reason: "非 fund_code scheme：\(fund.scheme)")
                continue
            }
            let outcome = await syncFund(
                fund, anchor: anchor, state: &state, spoolURL: spoolURL, result: &result
            )
            result.outcomes[fund.value] = outcome
        }

        state.lastRunAt = now()
        try store.save(state, to: stateURL)
        return result
    }

    // MARK: - 单基金一轮

    private func syncFund(
        _ fund: ProviderCode,
        anchor: Date,
        state: inout FundNAVSyncState,
        spoolURL: URL,
        result: inout FundNAVSyncRoundResult
    ) async -> FundNAVSyncOutcome {
        let providerID = adapter.providerID

        // Provider 健康：unavailable 时不发起抓取（PROV-8 降级入口）
        if let monitor = healthMonitor, await !monitor.isCallable(providerID) {
            return .providerNotCallable
        }

        // 游标 ≥ 锚点：本轮无需抓取
        if let cursor = state.lastIngestedEffectiveDates[fund.value], cursor >= anchor {
            return .upToDate
        }

        // 增量窗口（首轮回看）
        let windowFrom: Date
        if let cursor = state.lastIngestedEffectiveDates[fund.value] {
            windowFrom = cursor.addingTimeInterval(86_400)
        } else {
            windowFrom = anchor.addingTimeInterval(
                -Double(initialLookbackCalendarDays) * 86_400
            )
        }

        // 抓取（NAV 链只关心 navObservation kind；adapter 可能附带持仓记录）
        let fetched: ProviderFetchResult
        do {
            fetched = try await adapter.fetchWithDiagnostics(code: fund, from: windowFrom, to: anchor)
        } catch let error as ProviderError {
            await healthMonitor?.recordFailure(providerID, error: error)
            return .failed(reason: "\(error)")
        } catch {
            let mapped = ProviderError.unavailable(providerID: providerID, underlying: "\(error)")
            await healthMonitor?.recordFailure(providerID, error: mapped)
            return .failed(reason: "\(mapped)")
        }
        let navRecords = fetched.records.filter { $0.kind == .navObservation }
        let droppedMalformed = fetched.diagnostics.droppedMalformedBySource.values.reduce(0, +)

        // 结构闸门分桶（与 fetchAndStage 同款语义：非法记录不污染 spool）
        let validator = ProviderRecordSchemaValidator()
        let partition = validator.partition(navRecords)
        guard partition.valid.isEmpty == false else {
            if !partition.invalid.isEmpty {
                await healthMonitor?.recordSchemaDrift(providerID)
                return .rejectedCursorHeld(
                    committedCount: 0,
                    rejectionCount: partition.invalid.count,
                    droppedMalformed: droppedMalformed
                )
            }
            return .noNewData(windowFrom: windowFrom, windowThrough: anchor)
        }

        // 先落 spool（事实源），再 commit（派生物）。commit 失败时 spool 已有
        // 这批记录——这正是 ADR-DATA004 要的形态：库可删，spool 重放可重建。
        do {
            _ = try ProviderStagingWriter().append(partition.valid, to: spoolURL)
        } catch {
            return .failed(reason: "spool 追加失败：\(error)")
        }

        let commitResult = pipeline.commit(records: partition.valid)
        if let commitError = commitResult.commitError {
            return .failed(reason: "commit 事务失败（整批回滚）：\(commitError)")
        }

        // 本基金的拒收（provider/scheme/value/kind 四元组匹配；NAV 链一轮
        // 只有 navObservation 一种 kind）
        let fundRejections = commitResult.rejections.filter {
            $0.provider == providerID.rawValue && $0.scheme == fund.scheme
                && $0.value == fund.value && $0.kind == ProviderRecordKind.navObservation.rawValue
        }
        result.rejections.append(contentsOf: commitResult.rejections)

        let committed = commitResult.committedCount
        let rejectionCount = fundRejections.count + partition.invalid.count
        // 保守推进条件（P1 修复）：窗口内本轮必须**完整**——
        // ① 管道零拒收；② 无结构非法记录；③ 上游零丢行（droppedMalformed）。
        // 任一不满足 → 游标不动：T/T+2 合法而 T+1 被丢时推进到 T+2 会永久
        // 跳过 T+1。已提交的合法行保留（确定性 ID 幂等），下轮重抓不翻倍。
        if rejectionCount > 0 || droppedMalformed > 0 {
            await healthMonitor?.recordSuccess(providerID)
            return .rejectedCursorHeld(
                committedCount: committed,
                rejectionCount: rejectionCount,
                droppedMalformed: droppedMalformed
            )
        }

        // 干净轮：推进游标到本轮最大 effectiveAt
        let newCursor = partition.valid.map(\.effectiveAt).max()!
        state.lastIngestedEffectiveDates[fund.value] = newCursor
        await healthMonitor?.recordSuccess(providerID)
        return .committed(
            recordCount: committed, newCursor: newCursor, droppedMalformed: droppedMalformed
        )
    }
}
