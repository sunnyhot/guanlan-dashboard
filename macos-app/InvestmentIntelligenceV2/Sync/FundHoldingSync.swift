import Foundation

// MARK: - FundHoldingSync（SYNC-4：基金持仓披露检测 + 新 snapshot 自动入库）
//
// 与 SYNC-3（NAV 逐交易日增量）不同，持仓快照按**报告期**驱动：
// 1. 披露检测锚点 = 「保证已公布」的最新报告期（`FundDisclosureSchedule`，
//    监管披露时限的保守下界：季报 quarter-end +15 交易日、年报 +3 个月）；
// 2. 游标 = 每基金最后入库报告期；候选 = (游标, 锚点] 升序逐期抓取
//    （EastmoneyHistoricalHoldingProviderAdapter 按报告期构造，公告 API
//    提供真实 publishedAt）；
// 3. **公告未出 ≠ 失败**：`announcementNotFound` 是数据滞后（保守时限是
//    下界不是承诺；指数/ETF 类基金 Q1/Q3 本就不披露季报），游标不动、
//    记 .notYetPublished、停止本基金后续期（升序下更晚的期更不可能已公布）；
// 4. 结构分桶 → spool append（ADR-DATA004）→ 四防火墙 commit；
//    有拒收 / commit 失败 → 游标不动（重试幂等，不跳期产生覆盖缺口）；
// 5. ProviderHealth 上报同 SYNC-3（announcementNotFound 不计失败——
//    覆盖缺失不是服务故障，对齐 PROV-8 的 notFound 语义）。

// MARK: - 报告期

/// 基金定期报告期（季度粒度，quarter ∈ 1...4）。
struct FundReportPeriod: Codable, Sendable, Equatable, Comparable, Hashable {
    let year: Int
    let quarter: Int

    init(year: Int, quarter: Int) {
        precondition((1...4).contains(quarter), "quarter 必须在 1...4")
        self.year = year
        self.quarter = quarter
    }

    private var rank: Int { year * 4 + quarter }

    static func < (lhs: FundReportPeriod, rhs: FundReportPeriod) -> Bool {
        lhs.rank < rhs.rank
    }

    /// Wire 形态 "2026Q2"（状态文件 / 诊断可读）。
    var label: String { "\(year)Q\(quarter)" }

    /// 报告期截止日（CST 日界）：Q1=03-31 / Q2=06-30 / Q3=09-30 / Q4=12-31。
    func periodEnd(in calendar: Calendar) -> Date {
        let endMonth = quarter * 3
        let firstOfEndMonth = calendar.date(from: DateComponents(year: year, month: endMonth, day: 1))!
        guard let daysInMonth = calendar.range(of: .day, in: .month, for: firstOfEndMonth)?.count else {
            preconditionFailure("日历无月末天数（\(year)-\(endMonth)）")
        }
        return calendar.startOfDay(for: calendar.date(
            byAdding: DateComponents(day: daysInMonth - 1), to: firstOfEndMonth
        )!)
    }

    /// 下一 / 上一报告期（跨年进位）。
    var next: FundReportPeriod {
        quarter == 4 ? FundReportPeriod(year: year + 1, quarter: 1)
                     : FundReportPeriod(year: year, quarter: quarter + 1)
    }

    var previous: FundReportPeriod {
        quarter == 1 ? FundReportPeriod(year: year - 1, quarter: 4)
                     : FundReportPeriod(year: year, quarter: quarter - 1)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        let parts = raw.split(separator: "Q")
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 1,
              let year = Int(parts[0]),
              let quarter = Int(parts[1]), (1...4).contains(quarter) else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "非法报告期 \(raw)（期望 2026Q2 形态）"
            )
        }
        self.init(year: year, quarter: quarter)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(label)
    }
}

// MARK: - 披露时限（保守下界）

/// 基金定期报告披露时限的保守计算（SYNC-4 披露检测锚点）。
///
/// 监管要求（《公开募集证券投资基金信息披露管理办法》）：
/// - 季度报告（Q1/Q2/Q3）：季度结束之日起 15 个**工作日**内；
/// - 年度报告（Q4 报告期）：结束之日起 3 个月内。
///
/// 保守映射：15 工作日 → 15 **交易日**（节假日使交易日历的 +15 不早于
/// 工作日 +15，宁可晚判不可早判——晚判只意味着多等一轮检测）。这是
/// **下界不是承诺**：真实公告以 Provider 公告 API 为准（adapter 的
/// announcementNotFound 路径）；指数/ETF 类基金 Q1/Q3 可能根本不披露季报。
struct FundDisclosureSchedule: Sendable {

    let marketCalendar: HolidayTableTradingCalendar

    init(marketCalendar: HolidayTableTradingCalendar = .bundled) {
        self.marketCalendar = marketCalendar
    }

    private var cst: Calendar { marketCalendar.localCalendar(for: .chinaMainland) }

    /// 报告期的保证已公布时限（保守下界）。
    func deadline(for period: FundReportPeriod) -> Date {
        let end = period.periodEnd(in: cst)
        if period.quarter == 4 {
            // 年度报告：结束之日起 3 个月内（日历月加法，CST 日界）
            let deadline = cst.date(byAdding: DateComponents(month: 3), to: end)!
            return cst.startOfDay(for: deadline)
        }
        // 季度报告：+15 交易日（工作日的保守上界）
        return marketCalendar.tradingDay(after: end, offset: 15, jurisdiction: .chinaMainland)
    }

    /// asOf 时刻「保证已公布」的最新报告期（nil = 连最早的候选都未到期，
    /// 例如 asOf 早于 8 个季度前报告的时限——正常生产不会出现）。
    func latestGuaranteedPublishedPeriod(asOf: Date) -> FundReportPeriod? {
        // 从 asOf 所在季度的前一季起回找（当季永远未到期）
        let comps = cst.dateComponents([.year, .quarter], from: asOf)
        var current = FundReportPeriod(
            year: comps.year!, quarter: max(1, (comps.quarter ?? 1) - 1)
        )
        for _ in 0..<8 {
            if deadline(for: current) <= cst.startOfDay(for: asOf) {
                return current
            }
            current = current.previous
        }
        return nil
    }

    /// (from, through] 的报告期升序序列。
    func periods(after from: FundReportPeriod, through last: FundReportPeriod) -> [FundReportPeriod] {
        guard from < last else { return [] }
        var result: [FundReportPeriod] = []
        var cursor = from.next
        while cursor <= last {
            result.append(cursor)
            cursor = cursor.next
        }
        return result
    }
}

// MARK: - 状态与结果

/// FundHoldingSync 的增量游标状态。
struct FundHoldingSyncState: Codable, Sendable, Equatable {
    var version: Int = 1
    /// fundCode → 最后入库报告期（游标）
    var lastIngestedPeriods: [String: FundReportPeriod] = [:]
    var lastRunAt: Date?
}

/// 单只基金一轮 sync 的结局。
enum FundHoldingSyncOutcome: Equatable, Sendable {
    /// 游标已 ≥ 锚点（本轮无需检测）
    case upToDate
    /// 干净入库：入库期数 + 新增记录数 + 推进后的游标
    case committed(periodCount: Int, recordCount: Int, newCursor: FundReportPeriod)
    /// 锚点内的期都未公告（或到某期为止未公告）——游标停在最后成功期
    case notYetPublished(heldAt: FundReportPeriod?, nextCandidate: FundReportPeriod?)
    /// 有防火墙拒收——游标保守不动（detail 见 round 级拒收清单）
    case rejectedCursorHeld(committedPeriods: Int, rejectionCount: Int)
    /// Provider 不可调用（健康监控 unavailable）
    case providerNotCallable
    /// 抓取 / 持久化失败
    case failed(reason: String)
}

/// 一轮 sync 的汇总结果。
struct FundHoldingSyncRoundResult: Equatable, Sendable {
    /// 本轮披露检测锚点（保证已公布的最新报告期）
    let anchorPeriod: FundReportPeriod?
    var outcomes: [String: FundHoldingSyncOutcome] = [:]
    var rejections: [CanonicalPipeline.Rejection] = []
}

// MARK: - 引擎

/// 基金持仓披露检测同步引擎（天天基金历史归档链）。
struct FundHoldingSync: Sendable {

    /// 按报告期构造 adapter（EastmoneyHistoricalHoldingProviderAdapter
    /// 以 reportDate 为构造参数，非 fetch 参数）。
    let makeAdapter: @Sendable (_ reportDate: Date) -> any ProviderAdapter
    let pipeline: CanonicalPipeline
    let schedule: FundDisclosureSchedule
    let healthMonitor: ProviderHealthMonitor?
    let now: @Sendable () -> Date
    /// 单基金单轮最多回补的报告期数（首轮回补两年 = 8 期，深度回填走 SYNC-6a）
    var maxPeriodsPerRound: Int

    init(
        makeAdapter: @escaping @Sendable (_ reportDate: Date) -> any ProviderAdapter,
        pipeline: CanonicalPipeline,
        schedule: FundDisclosureSchedule = FundDisclosureSchedule(),
        healthMonitor: ProviderHealthMonitor? = nil,
        now: @escaping @Sendable () -> Date = { .now },
        maxPeriodsPerRound: Int = 8
    ) {
        self.makeAdapter = makeAdapter
        self.pipeline = pipeline
        self.schedule = schedule
        self.healthMonitor = healthMonitor
        self.now = now
        self.maxPeriodsPerRound = maxPeriodsPerRound
    }

    /// 跑一轮披露检测 sync（fund 粒度隔离）。
    func syncOnce(
        funds: [ProviderCode],
        spoolURL: URL,
        stateURL: URL
    ) async throws -> FundHoldingSyncRoundResult {
        let store = SyncStateStore<FundHoldingSyncState>()
        var state = try store.load(from: stateURL) ?? FundHoldingSyncState()
        let anchor = schedule.latestGuaranteedPublishedPeriod(asOf: now())
        var result = FundHoldingSyncRoundResult(anchorPeriod: anchor)

        for fund in funds {
            guard fund.scheme == "fund_code" || fund.scheme == "fund_product_code" else {
                result.outcomes[fund.value] = .failed(reason: "非基金 scheme：\(fund.scheme)")
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
        anchor: FundReportPeriod?,
        state: inout FundHoldingSyncState,
        spoolURL: URL,
        result: inout FundHoldingSyncRoundResult
    ) async -> FundHoldingSyncOutcome {
        guard let anchor else { return .upToDate }

        if let monitor = healthMonitor, await !monitor.isCallable(.eastmoney) {
            return .providerNotCallable
        }

        let cursor = state.lastIngestedPeriods[fund.value]
        if let cursor, cursor >= anchor {
            return .upToDate
        }

        // 候选期（升序）：首轮从锚点往回 maxPeriodsPerRound 期起补
        let fromPeriod = cursor ?? {
            var back = anchor
            for _ in 1..<maxPeriodsPerRound { back = back.previous }
            return back
        }()
        let candidates = schedule.periods(after: fromPeriod, through: anchor)
            .suffix(maxPeriodsPerRound)

        var committedPeriods = 0
        var committedRecords = 0
        var newCursor = cursor

        for period in candidates {
            let reportDate = period.periodEnd(in: schedule.marketCalendar.localCalendar(for: .chinaMainland))
            let adapter = makeAdapter(reportDate)

            let fetched: ProviderFetchResult
            do {
                fetched = try await adapter.fetchWithDiagnostics(
                    code: fund, from: reportDate, to: reportDate
                )
            } catch EastmoneyHistoricalHoldingError.announcementNotFound {
                // 公告未出：数据滞后（或该基金此类期不披露），游标停在已成功期
                await healthMonitor?.recordSuccess(.eastmoney)
                return .notYetPublished(heldAt: newCursor, nextCandidate: period)
            } catch let error as ProviderError {
                await healthMonitor?.recordFailure(.eastmoney, error: error)
                return .failed(reason: "\(error)")
            } catch {
                let mapped = ProviderError.unavailable(providerID: .eastmoney, underlying: "\(error)")
                await healthMonitor?.recordFailure(.eastmoney, error: mapped)
                return .failed(reason: "\(mapped)")
            }

            let holdingRecords = fetched.records.filter { $0.kind == .fundHoldingSnapshot }
            guard holdingRecords.isEmpty == false else {
                // 窗口命中但无记录：视同该期无数据，不推进游标（保守，
                // 与 NAV 的 noNewData 同语义）——升序继续会把洞留在身后
                continue
            }

            let partition = ProviderRecordSchemaValidator().partition(holdingRecords)
            guard partition.valid.isEmpty == false else {
                if !partition.invalid.isEmpty {
                    await healthMonitor?.recordSchemaDrift(.eastmoney)
                    return .rejectedCursorHeld(
                        committedPeriods: committedPeriods, rejectionCount: partition.invalid.count
                    )
                }
                continue
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
                await healthMonitor?.recordSuccess(.eastmoney)
                return .rejectedCursorHeld(
                    committedPeriods: committedPeriods, rejectionCount: commitResult.rejections.count
                )
            }

            committedPeriods += 1
            committedRecords += commitResult.committedCount
            newCursor = period
            state.lastIngestedPeriods[fund.value] = period
        }

        await healthMonitor?.recordSuccess(.eastmoney)
        if committedPeriods > 0 {
            return .committed(
                periodCount: committedPeriods, recordCount: committedRecords,
                newCursor: newCursor!
            )
        }
        // 候选全为空窗口（理论上锚点已保证到期，实际无数据）——游标不动
        return .notYetPublished(heldAt: cursor, nextCandidate: candidates.first)
    }
}
