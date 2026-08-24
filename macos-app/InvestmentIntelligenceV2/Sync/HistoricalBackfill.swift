import Foundation

// MARK: - HistoricalBackfill（SYNC-6a：持仓 universe 历史回填 ≥252 交易日）
//
// 增量 sync（SYNC-2/3）的窗口由游标驱动；本类型负责**深度历史**：
// 1. 窗口 = 锚点往回 `requiredTradingDays`（默认 252）个**交易日**（不是
//    日历天——交易日窗口直接对应验收语义「≥252 交易日历史」）；
// 2. 抓取 + 提交与增量引擎同款（结构分桶 → spool append（ADR-DATA004）→
//    四防火墙 commit），**幂等**：已入库行不翻倍，重复回填无害；
// 3. **回填不动增量游标**：游标只 gate 增量窗口；回填补的是历史，重叠部分
//    下轮增量重抓时幂等归并；
// 4. **覆盖率验证是验收本体**：`TargetCoverage` 对比「期望交易日集合」与
//    「库内实际 effectiveAt 集合」，报告 tradingDaysCovered / 缺口样本 /
//    isSufficient——「持仓内全部标的有历史」以这个查询为准，不以
//    fetch 返回为准（Provider 可能少给）。
//
// universe 来源（用户当前持仓）是 App 侧装配（rollout B.3 时点），本类型
// 只接收显式清单。

// MARK: - 覆盖率

/// 单标的的历史覆盖率（验收口径：库内实际行 vs 期望交易日集合）。
struct TargetCoverage: Equatable, Sendable {
    /// 期望的交易日数（= requiredTradingDays 窗口）
    let required: Int
    /// 库内实际覆盖的交易日数（distinct effectiveAt ∩ 期望集合）
    let covered: Int
    /// 期望但缺失的交易日（诊断样本，最近的 5 个，升序）
    let recentGaps: [Date]

    var isSufficient: Bool { covered >= required }

    /// 摘要（诊断面）。
    var summary: String {
        "covered \(covered)/\(required) trading days"
            + (isSufficient ? "" : "，缺口样本 \(recentGaps.count) 天")
    }
}

// MARK: - 目标与结局

/// NAV 回填目标（基金净值）。
struct NAVBackfillTarget: Sendable {
    let code: ProviderCode
    let shareClassID: FundShareClassID
    let adapter: any ProviderAdapter
}

/// 行情回填目标（美股日线经降级链；A 股经 remote 通道的记录已由
/// RemoteStagingSync + MarketDailySync 提交，回填阶段只做覆盖率验证）。
struct BarBackfillTarget: Sendable {
    let code: ProviderCode
    let jurisdiction: Jurisdiction
    let listingID: ListingID
    let chain: ProviderFallbackChain
}

enum BackfillFetchOutcome: Equatable, Sendable {
    case committed(recordCount: Int)
    case noData
    case rejected(rejectionCount: Int)
    case failed(summary: String)
}

/// 一轮回填的结果。
struct HistoricalBackfillResult: Equatable, Sendable {
    var navOutcomes: [String: BackfillFetchOutcome] = [:]
    var barOutcomes: [String: BackfillFetchOutcome] = [:]
    /// key = "nav|<code>" / "bar|<code>"，验收口径的覆盖率
    var coverage: [String: TargetCoverage] = [:]

    /// 验收：全部标的 sufficient？
    var allSufficient: Bool { coverage.values.allSatisfy(\.isSufficient) }
}

// MARK: - 引擎

/// 持仓 universe 历史回填 + 覆盖率验证。
struct HistoricalBackfill: Sendable {

    let pipeline: CanonicalPipeline
    let repository: GRDBRepository
    let marketCalendar: HolidayTableTradingCalendar
    let requiredTradingDays: Int
    let now: @Sendable () -> Date

    init(
        pipeline: CanonicalPipeline,
        repository: GRDBRepository,
        marketCalendar: HolidayTableTradingCalendar = .bundled,
        requiredTradingDays: Int = 252,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.pipeline = pipeline
        self.repository = repository
        self.marketCalendar = marketCalendar
        self.requiredTradingDays = requiredTradingDays
        self.now = now
    }

    /// 跑一轮回填（fetch+commit 幂等）并出覆盖率报告。
    func backfill(
        navFunds: [NAVBackfillTarget],
        barTargets: [BarBackfillTarget],
        spoolURL: URL
    ) async -> HistoricalBackfillResult {
        var result = HistoricalBackfillResult()

        // NAV：锚点 = T+1 保证已公布（SYNC-1 语义）
        let navAnchor = FundNAVPublicationCalendar(marketCalendar: marketCalendar)
            .latestGuaranteedPublishedNAVDate(asOf: now())
        let navExpected = marketCalendar.tradingDays(
            endingAt: navAnchor, count: requiredTradingDays, jurisdiction: .chinaMainland
        )
        let navWindowStart = navExpected.first ?? navAnchor

        for fund in navFunds where fund.code.scheme == "fund_code" {
            let outcome = await fetchAndCommit(
                adapter: fund.adapter, code: fund.code,
                windowFrom: navWindowStart, through: navAnchor,
                kind: .navObservation, spoolURL: spoolURL
            )
            result.navOutcomes[fund.code.value] = outcome
            result.coverage["nav|\(fund.code.value)"] = coverage(
                expected: navExpected,
                actualDates: repository.navObservations(
                    shareClassID: fund.shareClassID,
                    context: .economicKnowledge(asOf: navAnchor.addingTimeInterval(30 * 86_400))
                ).map { $0.temporalEnvelope.effectiveAt }
            )
        }

        // 行情：锚点按法域（MarketClose T+1）
        for target in barTargets {
            let anchor = marketCalendar.previousTradingDay(
                before: marketCalendar.latestTradingDayOnOrBefore(now(), jurisdiction: target.jurisdiction),
                jurisdiction: target.jurisdiction
            )
            let expected = marketCalendar.tradingDays(
                endingAt: anchor, count: requiredTradingDays, jurisdiction: target.jurisdiction
            )
            let fallback = await target.chain.fetch(
                code: target.code, from: expected.first ?? anchor, to: anchor
            )
            let outcome: BackfillFetchOutcome
            switch fallback {
            case .succeeded(let success):
                outcome = commitFiltered(
                    records: success.records.filter { $0.kind == .dailyBar },
                    code: target.code, spoolURL: spoolURL
                )
            case .allFailed:
                outcome = .failed(summary: fallback.localFallbackSummary)
            }
            result.barOutcomes[target.code.value] = outcome
            result.coverage["bar|\(target.code.value)"] = coverage(
                expected: expected,
                actualDates: repository.dailyBars(
                    listingID: target.listingID,
                    context: .economicKnowledge(asOf: anchor.addingTimeInterval(30 * 86_400))
                ).map { $0.temporalEnvelope.effectiveAt }
            )
        }

        return result
    }

    // MARK: - 抓取 + 提交（幂等）

    private func fetchAndCommit(
        adapter: any ProviderAdapter,
        code: ProviderCode,
        windowFrom: Date,
        through: Date,
        kind: ProviderRecordKind,
        spoolURL: URL
    ) async -> BackfillFetchOutcome {
        let fetched: ProviderFetchResult
        do {
            fetched = try await adapter.fetchWithDiagnostics(code: code, from: windowFrom, to: through)
        } catch {
            return .failed(summary: "\(error)")
        }
        return commitFiltered(
            records: fetched.records.filter { $0.kind == kind },
            code: code, spoolURL: spoolURL
        )
    }

    private func commitFiltered(
        records: [ProviderRecord],
        code: ProviderCode,
        spoolURL: URL
    ) -> BackfillFetchOutcome {
        guard records.isEmpty == false else { return .noData }
        let partition = ProviderRecordSchemaValidator().partition(records)
        guard partition.valid.isEmpty == false else {
            return partition.invalid.isEmpty ? .noData : .rejected(rejectionCount: partition.invalid.count)
        }
        do {
            _ = try ProviderStagingWriter().append(partition.valid, to: spoolURL)
        } catch {
            return .failed(summary: "spool 追加失败：\(error)")
        }
        let commit = pipeline.commit(records: partition.valid)
        if let commitError = commit.commitError {
            return .failed(summary: "commit 事务失败：\(commitError)")
        }
        if !commit.rejections.isEmpty {
            return .rejected(rejectionCount: commit.rejections.count)
        }
        return .committed(recordCount: commit.committedCount)
    }

    // MARK: - 覆盖率计算（验收口径）

    private func coverage(expected: [Date], actualDates: [Date]) -> TargetCoverage {
        let expectedSet = Set(expected)
        let actualSet = Set(actualDates)
        let covered = expectedSet.intersection(actualSet).count
        let gaps = expectedSet.subtracting(actualSet).sorted().suffix(5)
        return TargetCoverage(
            required: expected.count,
            covered: covered,
            recentGaps: Array(gaps)
        )
    }
}
