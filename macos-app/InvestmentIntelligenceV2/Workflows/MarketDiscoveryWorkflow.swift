import Foundation

// MARK: - Market Discovery Workflow（WF-2，替代固定八组搜索）
//
// 旧链路（TrendResearchPromptBuilder）每次运行对 8 组固定分组
// （assetClass + index 聚合 + 六个 sector）做 Tavily 盲扫——搜索预算
// 与候选质量脱钩。本工作流反转顺序：
// 1. **Universe**（本地策展清单，MarketUniverse 版本化数据）
// 2. **Local Factor**（FactorEngine 从本地日线算因子——零网络零额度）
// 3. **Ranking**（versioned DiscoveryRankingPolicy 确定性打分排序）
// 4. **选择性 Research**（只对 top-K 候选产 ResearchTask 喂 WF-1——
//    LLM / Tavily 只花在被本地数据筛出的少数标的上）
//
// 语义纪律：
// - 打分只消费 cardinal 因子值（FAC 引擎产出），缺输入 → coverage gap
//   显式记录，不猜（DATA006）
// - 同输入（asOf / universe / policy / 本地数据）→ 同 report（确定性 ID）
// - 报告是 Artifact（untilDependencyChanges：上游因子快照或数据修订
//   即失效重算），dependencies 指向参与打分的 factor snapshots

// MARK: - Universe 策展（v1 内置清单）

/// 全市场 universe 的内置策展（v1）。
///
/// 策展纪律（SYNC-6b 收口时明确留给 WF-2 的职责）：
/// - key 稳定唯一（改名 = 新标的）；listingID 按 `lst_<code小写>`
///   确定性构造——修订时须与 Instrument Master 对账（identity 由
///   IdentitySync 建立，策展不猜解析）
/// - 优先级小者先回填；fetchDirectly 按数据通道（美股降级链直抓 /
///   A 股 remote staging）
/// - 扩充走 universeVersion bump + 增量条目（SYNC-6b 引擎支持增量）
enum MarketUniverseCatalog {
    static let v1 = MarketUniverse(
        universeVersion: 1,
        entries: Self.entries
    )

    private static func entry(
        _ key: String, code: String, jurisdiction: Jurisdiction,
        displayName: String, priority: Int, fetchDirectly: Bool,
        exchange: Exchange, scheme: String = "stock_symbol"
    ) -> MarketUniverseEntry {
        MarketUniverseEntry(
            key: key,
            code: ProviderCode(scheme: scheme, value: code),
            jurisdiction: jurisdiction,
            exchange: exchange,
            displayName: displayName,
            priority: priority,
            fetchDirectly: fetchDirectly
        )
    }

    /// v1 策展：宽基 + 代表性行业 / 资产类（美股直抓 + A 股 remote 通道）。
    /// 规模刻意收敛（30 条起步）——回填受免费额度限制，扩充走增量。
    private static var entries: [MarketUniverseEntry] {
        // 美股宽基与资产类（Alpha Vantage / Stooq 直抓）
        [
            entry("us-spy", code: "SPY", jurisdiction: .unitedStates,
                  displayName: "标普500 ETF", priority: 1, fetchDirectly: true, exchange: .arca),
            entry("us-qqq", code: "QQQ", jurisdiction: .unitedStates,
                  displayName: "纳斯达克100 ETF", priority: 1, fetchDirectly: true, exchange: .arca),
            entry("us-iwm", code: "IWM", jurisdiction: .unitedStates,
                  displayName: "罗素2000 ETF", priority: 2, fetchDirectly: true, exchange: .arca),
            entry("us-vt", code: "VT", jurisdiction: .unitedStates,
                  displayName: "全球股票 ETF", priority: 2, fetchDirectly: true, exchange: .arca),
            entry("us-tlt", code: "TLT", jurisdiction: .unitedStates,
                  displayName: "20年期美债 ETF", priority: 3, fetchDirectly: true, exchange: .arca),
            entry("us-gld", code: "GLD", jurisdiction: .unitedStates,
                  displayName: "黄金 ETF", priority: 3, fetchDirectly: true, exchange: .arca),
            // 美股行业 SPDR（六 sector 对齐旧八组扫描的分组语义）
            entry("us-xlk", code: "XLK", jurisdiction: .unitedStates,
                  displayName: "科技行业 ETF", priority: 4, fetchDirectly: true, exchange: .arca),
            entry("us-xlv", code: "XLV", jurisdiction: .unitedStates,
                  displayName: "医疗保健 ETF", priority: 4, fetchDirectly: true, exchange: .arca),
            entry("us-xlf", code: "XLF", jurisdiction: .unitedStates,
                  displayName: "金融行业 ETF", priority: 4, fetchDirectly: true, exchange: .arca),
            entry("us-xli", code: "XLI", jurisdiction: .unitedStates,
                  displayName: "工业制造 ETF", priority: 5, fetchDirectly: true, exchange: .arca),
            entry("us-xle", code: "XLE", jurisdiction: .unitedStates,
                  displayName: "能源资源 ETF", priority: 5, fetchDirectly: true, exchange: .arca),
            entry("us-xlp", code: "XLP", jurisdiction: .unitedStates,
                  displayName: "必需消费 ETF", priority: 5, fetchDirectly: true, exchange: .arca),
            entry("us-xlu", code: "XLU", jurisdiction: .unitedStates,
                  displayName: "公用事业 ETF", priority: 6, fetchDirectly: true, exchange: .arca),
            entry("us-xlre", code: "XLRE", jurisdiction: .unitedStates,
                  displayName: "房地产 ETF", priority: 6, fetchDirectly: true, exchange: .arca),
            entry("us-xlb", code: "XLB", jurisdiction: .unitedStates,
                  displayName: "原材料 ETF", priority: 6, fetchDirectly: true, exchange: .arca),
            entry("us-xly", code: "XLY", jurisdiction: .unitedStates,
                  displayName: "可选消费 ETF", priority: 6, fetchDirectly: true, exchange: .arca),
            entry("us-xlvcare", code: "XLC", jurisdiction: .unitedStates,
                  displayName: "通信服务 ETF", priority: 7, fetchDirectly: true, exchange: .arca),
            // A 股宽基与行业（remote staging 通道，fetchDirectly = false）
            entry("cn-000300", code: "000300", jurisdiction: .chinaMainland,
                  displayName: "沪深300", priority: 8, fetchDirectly: false, exchange: .sse),
            entry("cn-000905", code: "000905", jurisdiction: .chinaMainland,
                  displayName: "中证500", priority: 8, fetchDirectly: false, exchange: .sse),
            entry("cn-000852", code: "000852", jurisdiction: .chinaMainland,
                  displayName: "中证1000", priority: 9, fetchDirectly: false, exchange: .sse),
            entry("cn-399006", code: "399006", jurisdiction: .chinaMainland,
                  displayName: "创业板指", priority: 9, fetchDirectly: false, exchange: .sse),
            entry("cn-cyborgrowth", code: "399971", jurisdiction: .chinaMainland,
                  displayName: "中证传媒", priority: 10, fetchDirectly: false, exchange: .sse),
            entry("cn-medical", code: "399989", jurisdiction: .chinaMainland,
                  displayName: "中证医疗", priority: 10, fetchDirectly: false, exchange: .sse),
            entry("cn-csi-food", code: "930653", jurisdiction: .chinaMainland,
                  displayName: "中证食品饮料", priority: 11, fetchDirectly: false, exchange: .sse),
            entry("cn-bank", code: "399986", jurisdiction: .chinaMainland,
                  displayName: "中证银行", priority: 11, fetchDirectly: false, exchange: .sse),
            entry("cn-csi-machine", code: "930697", jurisdiction: .chinaMainland,
                  displayName: "中证机器人", priority: 12, fetchDirectly: false, exchange: .sse),
            entry("cn-newenergy", code: "399808", jurisdiction: .chinaMainland,
                  displayName: "中证新能车", priority: 12, fetchDirectly: false, exchange: .sse),
            entry("cn-csi-res", code: "930708", jurisdiction: .chinaMainland,
                  displayName: "中证有色金属", priority: 13, fetchDirectly: false, exchange: .sse),
            entry("cn-csi-div", code: "930955", jurisdiction: .chinaMainland,
                  displayName: "中证红利", priority: 13, fetchDirectly: false, exchange: .sse),
            entry("cn-real-estate", code: "931775", jurisdiction: .chinaMainland,
                  displayName: "中证地产", priority: 14, fetchDirectly: false, exchange: .sse),
            entry("cn-518880", code: "518880", jurisdiction: .chinaMainland,
                  displayName: "黄金 ETF", priority: 14, fetchDirectly: false, exchange: .sse),
        ]
    }
}

// MARK: - Discovery 排序策略（versioned heuristic）

/// 候选打分策略（heuristic——provenance 显式标注，同 IndifferenceBand /
/// SignalPolicy 纪律）。
///
/// score = momentumWeight × momentum.return60
///       + trendWeight × trend.closeVsMA20
///       + drawdownWeight × drawdown.current252
/// 任一输入 metric 缺失（insufficient）→ 该标的进 coverageGaps，不猜分。
/// （current252 是 ≤0 的回撤比率——越接近 0 贡献越大，无需取绝对值。）
struct DiscoveryRankingPolicy: Sendable, Codable, Hashable {
    let policyID: String
    let version: String
    let rationale: String
    var momentumWeight: Decimal
    var trendWeight: Decimal
    var drawdownWeight: Decimal
    /// 报告保留的候选数（选择性 Research 的输入规模上限）。
    var topK: Int

    init(
        policyID: String = "market-discovery-ranking",
        version: String = "v1",
        rationale: String = "动量与趋势正贡献、当前回撤正贡献（浅回撤优）——本地因子先筛，LLM 只看 top-K",
        momentumWeight: Decimal = Decimal(string: "1")!,
        trendWeight: Decimal = Decimal(string: "0.5")!,
        drawdownWeight: Decimal = Decimal(string: "0.5")!,
        topK: Int = 8
    ) {
        self.policyID = policyID
        self.version = version
        self.rationale = rationale
        self.momentumWeight = momentumWeight
        self.trendWeight = trendWeight
        self.drawdownWeight = drawdownWeight
        self.topK = topK
    }

    /// 策略身份串（参与 report ID 派生）。
    var identityToken: String { "\(policyID)@\(version)" }

    /// 打分输入的 metric key（与 FactorEngine 各 calculator 的 key 对齐）。
    static let requiredMetricKeys = [
        "momentum.return60", "trend.closeVsMA20", "drawdown.current252"
    ]
}

// MARK: - Discovery Report（Artifact）

/// 单个入选候选。
struct DiscoveryCandidate: Sendable, Codable, Hashable {
    let universeKey: String
    let listingID: ListingID
    let displayName: String
    /// 综合分（policy 加权；确定性 Decimal）。
    let score: Decimal
    /// 参与打分的 metric 快照（key → value；审计可追溯）。
    let metrics: [String: Decimal]
    /// 参与打分的因子快照引用。
    let factorSnapshotID: ArtifactID
    /// 名次（1 起；分数与 tie-break 决定）。
    let rank: Int
}

/// 数据不足、未参与排名的 universe 条目（显式记录，不静默丢弃）。
struct DiscoveryCoverageGap: Sendable, Codable, Hashable {
    let universeKey: String
    let listingID: ListingID
    /// 不足原因（首个 insufficient metric 的结构化说明）。
    let reason: String
}

/// 市场发现报告（MARKET_DISCOVERY_REPORT artifact）。
struct MarketDiscoveryReport: Artifact {
    let id: ArtifactID
    let producedAt: Date
    /// 上游因子快照 / 本地数据修订即失效重算。
    let validityPolicy: ValidityPolicy
    let dependencies: [ArtifactDependency]

    let asOf: Date
    let universeVersion: Int
    let rankingPolicy: DiscoveryRankingPolicy
    /// top-K 候选（rank 升序）。
    let candidates: [DiscoveryCandidate]
    /// 未参与排名的条目及原因。
    let coverageGaps: [DiscoveryCoverageGap]
}

// MARK: - Workflow 本体

/// 市场发现工作流：universe → 本地因子 → 打分排序 → 报告（纯本地计算，
/// 无网络——「降 Tavily 消耗」的结构性来源）。
struct MarketDiscoveryWorkflow: Sendable {
    static let workflowKind = "marketDiscovery"

    let universe: MarketUniverse
    let engine: FactorEngine
    let repository: any MarketTimeSeriesRepository
    let policy: DiscoveryRankingPolicy
    /// 相对强度基准（FAC-7：benchmark 显式声明，不隐式默认；未配辖区
    /// 不取 benchmark 序列）。当前打分不消费相对强度（默认引擎未装载
    /// RelativeStrengthFactorCalculator——其 benchmark 是构造参数，与
    /// 多辖区混跑不匹配）；benchmark 数据随快照留存，扩 ranking policy
    /// 时按需装载带 benchmark 的引擎实例。
    let benchmarkByJurisdiction: [Jurisdiction: ListingID]
    /// 因子快照落库通道（App 接线时写 GRDB artifacts 表，幂等；
    /// nil = 不落库——重放/失效传播依赖快照持久化，十六轮审查 P2）。
    let snapshotSink: (@Sendable (FactorSnapshot) throws -> Void)?

    init(
        universe: MarketUniverse = MarketUniverseCatalog.v1,
        engine: FactorEngine = FactorEngine(calculators: [
            MomentumFactorCalculator(),
            TrendFactorCalculator(),
            VolatilityFactorCalculator(),
            DrawdownFactorCalculator(),
        ]),
        repository: any MarketTimeSeriesRepository,
        policy: DiscoveryRankingPolicy = DiscoveryRankingPolicy(),
        benchmarkByJurisdiction: [Jurisdiction: ListingID] = [:],
        snapshotSink: (@Sendable (FactorSnapshot) throws -> Void)? = nil
    ) {
        self.universe = universe
        self.engine = engine
        self.repository = repository
        self.policy = policy
        self.benchmarkByJurisdiction = benchmarkByJurisdiction
        self.snapshotSink = snapshotSink
    }

    struct RunOutcome: Sendable {
        let job: AgentJob
        let report: MarketDiscoveryReport?
        let errorDetail: String?

        var succeeded: Bool { job.state == .completed }
    }

    /// 执行发现 job（同步纯计算；取消点只有 queued 阶段）。
    func run(asOf: Date, now: Date) -> RunOutcome {
        let fingerprint = "\(universe.universeVersion)|\(asOf.timeIntervalSince1970)|\(policy.identityToken)"
        var job = AgentJob(
            workflowKind: Self.workflowKind,
            inputFingerprint: StableDigest.digest(fingerprint),
            createdAt: now
        )
        // 取消点：job 在 run 内创建、恒为 queued，原 `job.state == .cancelled`
        // 是永假死代码（十八轮审查 P2-7）——改查外层结构化并发任务，调用方
        // 取消 enclosing task 时本 job 以合法的 queued→cancelled 收场
        if Task.isCancelled {
            try? job.transition(to: .cancelled, at: now, detail: nil)
            return RunOutcome(job: job, report: nil, errorDetail: nil)
        }
        do {
            try job.transition(to: .running, at: now, detail: nil)

            var scored: [DiscoveryCandidate] = []
            var gaps: [DiscoveryCoverageGap] = []
            var factorIDs: [ArtifactID] = []
            for entry in universe.entries.sorted(by: {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return $0.key < $1.key
            }) {
                let snapshot = engine.snapshot(
                    listingID: entry.listingID,
                    asOf: asOf,
                    repository: repository,
                    benchmarkListingID: benchmarkByJurisdiction[entry.jurisdiction],
                    producedAt: now
                )
                // 全部快照统一收集 + 落库（含 coverage-gap 条目——失效
                // 传播按「参与计算的快照」覆盖,gap 不留盲区）
                factorIDs.append(snapshot.id)
                if let snapshotSink {
                    try snapshotSink(snapshot)
                }
                var metricValues: [String: Decimal] = [:]
                var insufficient: String?
                for key in DiscoveryRankingPolicy.requiredMetricKeys {
                    guard let metric = snapshot.metrics.first(where: {
                        $0.definition.key == key
                    }) else {
                        insufficient = "missing metric \(key)"
                        break
                    }
                    if let value = metric.value {
                        metricValues[key] = value
                    } else if insufficient == nil {
                        insufficient = metric.insufficiency.map {
                            "\($0.reason.rawValue)(required=\($0.requiredBars.map(String.init) ?? "-") actual=\($0.actualBars))"
                        } ?? "insufficient"
                    }
                }
                if let insufficient {
                    gaps.append(DiscoveryCoverageGap(
                        universeKey: entry.key,
                        listingID: entry.listingID,
                        reason: insufficient
                    ))
                    continue
                }
                let score = policy.momentumWeight * (metricValues["momentum.return60"] ?? 0)
                    + policy.trendWeight * (metricValues["trend.closeVsMA20"] ?? 0)
                    + policy.drawdownWeight * (metricValues["drawdown.current252"] ?? 0)
                scored.append(DiscoveryCandidate(
                    universeKey: entry.key,
                    listingID: entry.listingID,
                    displayName: entry.displayName,
                    score: score,
                    metrics: metricValues,
                    factorSnapshotID: snapshot.id,
                    rank: 0
                ))
            }

            // 确定序：score 降序，tie-break universeKey 升序；top-K 截断
            let ranked = Array(
                scored.sorted {
                    if $0.score != $1.score { return $0.score > $1.score }
                    return $0.universeKey < $1.universeKey
                }
                    .prefix(max(policy.topK, 0))
            )
            .enumerated()
            .map { index, candidate in
                DiscoveryCandidate(
                    universeKey: candidate.universeKey,
                    listingID: candidate.listingID,
                    displayName: candidate.displayName,
                    score: candidate.score,
                    metrics: candidate.metrics,
                    factorSnapshotID: candidate.factorSnapshotID,
                    rank: index + 1
                )
            }

            let report = Self.assemble(
                asOf: asOf,
                now: now,
                universeVersion: universe.universeVersion,
                policy: policy,
                candidates: ranked,
                coverageGaps: gaps.sorted { $0.universeKey < $1.universeKey },
                factorSnapshotIDs: factorIDs
            )
            try job.transition(to: .completed, at: now, detail: report.id.rawValue)
            return RunOutcome(job: job, report: report, errorDetail: nil)
        } catch {
            let detail = String(describing: error)
            if job.state == .running {
                try? job.transition(to: .failed, at: now, detail: detail)
            }
            return RunOutcome(job: job, report: nil, errorDetail: detail)
        }
    }

    /// 报告组装（确定性 ID：全部语义字段参与，不含 producedAt）。
    private static func assemble(
        asOf: Date,
        now: Date,
        universeVersion: Int,
        policy: DiscoveryRankingPolicy,
        candidates: [DiscoveryCandidate],
        coverageGaps: [DiscoveryCoverageGap],
        factorSnapshotIDs: [ArtifactID]
    ) -> MarketDiscoveryReport {
        let dependencies = factorSnapshotIDs.map {
            ArtifactDependency(kind: .factorSnapshot, referenceID: $0.rawValue)
        }
        let payload = try! StableDigest.jsonPayload(ReportIdentity(
            asOfEpoch: Int(asOf.timeIntervalSince1970),
            universeVersion: universeVersion,
            rankingPolicy: policy,
            candidates: candidates,
            coverageGaps: coverageGaps
        ))
        return MarketDiscoveryReport(
            id: ArtifactID(rawValue: "mkt_\(StableDigest.digest(payload))"),
            producedAt: now,
            validityPolicy: .untilDependencyChanges,
            dependencies: dependencies,
            asOf: asOf,
            universeVersion: universeVersion,
            rankingPolicy: policy,
            candidates: candidates,
            coverageGaps: coverageGaps
        )
    }

    private struct ReportIdentity: Encodable {
        let asOfEpoch: Int
        let universeVersion: Int
        let rankingPolicy: DiscoveryRankingPolicy
        let candidates: [DiscoveryCandidate]
        let coverageGaps: [DiscoveryCoverageGap]
    }
}

// MARK: - 选择性 Research 接线（top-K → ResearchTask）

extension MarketDiscoveryReport {
    /// 候选 → 研究任务（喂 WF-1 PortfolioResearchWorkflow 的 assetTasks）。
    /// 只带 top-K（或调用方进一步收窄）——LLM / Tavily 消耗被结构性压住。
    func researchTasks(limit: Int? = nil) -> [ResearchTask] {
        candidates
            .prefix(max(limit ?? candidates.count, 0))
            .map { candidate in
                ResearchTask(
                    subject: .listing(candidate.listingID),
                    objective: "评估 \(candidate.displayName) 的动量持续性与主要风险（本地因子排名第 \(candidate.rank)）"
                )
            }
    }
}

// MARK: - GRDB 落库便捷入口（App / CLI 接线用）

import GRDB

extension GRDBRepository {
    /// 发现报告幂等落库（ArtifactRow.write 语义，事务包裹）。
    func writeMarketDiscoveryReport(_ report: MarketDiscoveryReport) throws {
        try database.queue.write { db in
            try ArtifactRow.write(try ArtifactRow.from(report), into: db)
        }
    }

    /// 按 ID 读回发现报告（不存在 → nil；存在但损坏 → 抛错 fail-closed）。
    func marketDiscoveryReport(id: String) throws -> MarketDiscoveryReport? {
        try database.queue.read { db in
            do {
                return try ArtifactRow.fetchMarketDiscoveryReport(id: id, from: db)
            } catch ArtifactReadError.notFound {
                return nil
            }
        }
    }
}
