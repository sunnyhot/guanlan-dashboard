import Foundation

// MARK: - MarketCloseReview Workflow（审计 A1，V1 收盘复盘的 V2 重建）
//
// 每日收盘后的组合复盘 artifact（validity = immutableHistorical——某交易
// 日的复盘是历史事实，重跑产出新 artifact，不改写旧的）。
//
// 形态（用户拍板：计算 + LLM 增强）：
// - 纯计算部分（确定性）：组合当日表现 / 逐持仓影响 / 覆盖边界——来自
//   App 侧冻结的估值快照，与 V2 归因 artifact 同源
// - LLM 增强部分（可选）：市场脉搏 / 强弱主题——经 NarrativeProvider
//   （ModelGateway + StructuredGeneration 的结构化输出）；Provider 未配置
//   或调用失败 → 优雅降级为本地因子版（narrativeSource = localFactors），
//   不阻断冻结
//
// 「21:00 冻结」语义：调度层（批次 3）在收盘后触发一次；本 workflow 不
// 感知时刻，只按输入的 reviewDate 冻结当日数字。

// MARK: - 领域模型

/// 市场脉搏条目（方向枚举，UI 不做字符串判断）。
enum MarketPulseDirection: String, Codable, Hashable, Sendable {
    case up
    case down
    case flat
}

/// 强弱主题方向。
enum MarketThemeDirection: String, Codable, Hashable, Sendable {
    case strong
    case weak
}

/// 复盘叙述的来源（审计可见：LLM 与本地因子不互相冒充）。
enum CloseReviewNarrativeSource: String, Codable, Hashable, Sendable {
    case llm
    case localFactors
}

/// 收盘复盘 artifact。
struct MarketCloseReview: Artifact {
    let id: ArtifactID
    let producedAt: Date
    /// 历史事实永不失效（重跑 = 新 artifact）
    let validityPolicy: ValidityPolicy
    let dependencies: [ArtifactDependency]

    /// 复盘覆盖的交易日（上海时区日界）。
    let reviewDate: Date
    /// 调用方定义的组合键。
    let portfolioKey: String
    let narrativeSource: CloseReviewNarrativeSource

    // MARK: 组合当日表现（纯计算）

    struct PortfolioReview: Codable, Hashable, Sendable {
        struct HoldingImpact: Codable, Hashable, Sendable {
            let name: String
            let code: String?
            /// 当日涨跌额（nil = 未公布）。
            let changeAmount: Double?
            /// 当日涨跌幅（nil = 未公布）。
            let changePct: Double?
        }

        let totalMarketValue: Double
        let dailyChangeAmount: Double?
        let dailyChangePct: Double?
        let holdingCount: Int
        let coveredHoldingCount: Int
        /// 逐持仓影响（|changeAmount| 降序，前 N 条）。
        let topImpacts: [HoldingImpact]
    }

    let portfolioReview: PortfolioReview?

    // MARK: 市场叙述（LLM 或本地因子降级）

    struct PulseItem: Codable, Hashable, Sendable {
        let name: String
        let direction: MarketPulseDirection
        let confidenceText: String
        let rationale: String
    }

    struct ThemeItem: Codable, Hashable, Sendable {
        let name: String
        let direction: MarketThemeDirection
        let rationale: String
    }

    let marketPulse: [PulseItem]
    let strongThemes: [ThemeItem]
    let weakThemes: [ThemeItem]

    /// 明日关注（≤3 条，来自决策事项 / 目标偏差 / 盘中结论）。
    let tomorrowWatch: [String]

    /// 数据边界说明（覆盖 / 陈旧来源，人话）。
    let dataBoundary: String
    /// 关联的归因 artifact（可溯）。
    let attributionArtifactID: String?

    init(
        reviewDate: Date,
        portfolioKey: String,
        narrativeSource: CloseReviewNarrativeSource,
        portfolioReview: PortfolioReview?,
        marketPulse: [PulseItem],
        strongThemes: [ThemeItem],
        weakThemes: [ThemeItem],
        tomorrowWatch: [String],
        dataBoundary: String,
        attributionArtifactID: String?,
        producedAt: Date
    ) {
        self.reviewDate = reviewDate
        self.portfolioKey = portfolioKey
        self.narrativeSource = narrativeSource
        self.portfolioReview = portfolioReview
        self.marketPulse = marketPulse
        self.strongThemes = strongThemes
        self.weakThemes = weakThemes
        self.tomorrowWatch = Array(tomorrowWatch.prefix(3))
        self.dataBoundary = dataBoundary
        self.attributionArtifactID = attributionArtifactID
        self.producedAt = producedAt
        self.validityPolicy = .immutableHistorical

        var dependencies: [ArtifactDependency] = []
        if let attributionArtifactID {
            dependencies.append(ArtifactDependency(
                kind: .artifact, referenceID: attributionArtifactID))
        }
        self.dependencies = dependencies.sorted { $0.referenceID < $1.referenceID }

        // ID 语义完备：只排除 producedAt——重算幂等；LLM 与本地因子叙述
        // 不同 → 不同 ID（历史各自可审计，latest 生效）
        let payload = try! StableDigest.jsonPayload(IdentityPayload(
            reviewDate: reviewDate,
            portfolioKey: portfolioKey,
            narrativeSource: narrativeSource,
            portfolioReview: portfolioReview,
            marketPulse: marketPulse,
            strongThemes: strongThemes,
            weakThemes: weakThemes,
            tomorrowWatch: self.tomorrowWatch,
            dataBoundary: dataBoundary,
            attributionArtifactID: attributionArtifactID,
            dependencies: dependencies.map { "\($0.kind.rawValue)|\($0.referenceID)" }.sorted()))
        self.id = ArtifactID(rawValue: "mcr_\(StableDigest.digest(payload))")
    }

    private struct IdentityPayload: Encodable {
        let reviewDate: Date
        let portfolioKey: String
        let narrativeSource: CloseReviewNarrativeSource
        let portfolioReview: PortfolioReview?
        let marketPulse: [PulseItem]
        let strongThemes: [ThemeItem]
        let weakThemes: [ThemeItem]
        let tomorrowWatch: [String]
        let dataBoundary: String
        let attributionArtifactID: String?
        let dependencies: [String]
    }
}

// MARK: - LLM 叙述输出（结构化生成契约的 Codable 形状，蛇形键转换安全命名）

struct CloseReviewNarrative: Codable, Hashable, Sendable {
    let marketPulse: [MarketCloseReview.PulseItem]
    let strongThemes: [MarketCloseReview.ThemeItem]
    let weakThemes: [MarketCloseReview.ThemeItem]
}

// MARK: - Workflow

/// 收盘复盘 workflow（计算同步 + 叙述可选异步）。
struct MarketCloseReviewWorkflow: Sendable {
    static let workflowKind = "marketCloseReview"

    /// 市场摘要条目（本地因子 / 指数行情 → LLM 输入或本地降级叙述的原料）。
    struct MarketDigestItem: Codable, Hashable, Sendable {
        let name: String
        /// 指数涨跌幅（百分比；因子条目为 nil）。
        let changePct: Double?
        /// 因子评分（指数条目为 nil）。
        let factorScore: Double?
        /// 条目种类（"index" / "factor"）。
        let kind: String

        init(name: String, changePct: Double? = nil, factorScore: Double? = nil, kind: String) {
            self.name = name
            self.changePct = changePct
            self.factorScore = factorScore
            self.kind = kind
        }
    }

    struct Input: Sendable {
        let portfolioKey: String
        let reviewDate: Date
        var portfolioReview: MarketCloseReview.PortfolioReview?
        var marketDigest: [MarketDigestItem] = []
        var tomorrowWatch: [String] = []
        var dataBoundary: String = ""
        var attributionArtifactID: String? = nil
    }

    /// LLM 叙述供给（MarketCloseNarrativeSynthesizer.synthesize 的闭包形态；
    /// 抛错 = 降级本地因子，不阻断冻结）。
    typealias NarrativeProvider = @Sendable (_ digestJSON: String) async throws -> CloseReviewNarrative

    struct RunOutcome: Sendable, Codable, Hashable {
        let job: AgentJob
        let artifact: MarketCloseReview?
        /// LLM 失败降级为本地因子（提示层可告知）。
        let narrativeFallback: Bool
        let errorDetail: String?

        var succeeded: Bool { job.state == .completed }
    }

    let narrativeProvider: NarrativeProvider?

    init(narrativeProvider: NarrativeProvider? = nil) {
        self.narrativeProvider = narrativeProvider
    }

    func run(input: Input, now: Date) async -> RunOutcome {
        let fingerprint = "\(input.portfolioKey)|\(Int(input.reviewDate.timeIntervalSince1970))"
        var job = AgentJob(workflowKind: Self.workflowKind, inputFingerprint: fingerprint, createdAt: now)
        if job.state == .cancelled {
            return RunOutcome(job: job, artifact: nil, narrativeFallback: false, errorDetail: nil)
        }

        do {
            try job.transition(to: .running, at: now, detail: nil)

            // 叙述：LLM 优先，失败降级本地因子
            var narrative: CloseReviewNarrative
            var source: CloseReviewNarrativeSource = .localFactors
            var fallback = false
            if let provider = narrativeProvider {
                do {
                    let digestJSON = try Self.encodeDigest(input.marketDigest)
                    narrative = try await provider(digestJSON)
                    source = .llm
                } catch {
                    narrative = Self.localNarrative(from: input.marketDigest)
                    source = .localFactors
                    fallback = true
                }
            } else {
                narrative = Self.localNarrative(from: input.marketDigest)
            }

            let artifact = MarketCloseReview(
                reviewDate: input.reviewDate,
                portfolioKey: input.portfolioKey,
                narrativeSource: source,
                portfolioReview: input.portfolioReview,
                marketPulse: narrative.marketPulse,
                strongThemes: narrative.strongThemes,
                weakThemes: narrative.weakThemes,
                tomorrowWatch: input.tomorrowWatch,
                dataBoundary: input.dataBoundary,
                attributionArtifactID: input.attributionArtifactID,
                producedAt: now)
            try job.transition(to: .completed, at: now, detail: artifact.id.rawValue)
            return RunOutcome(job: job, artifact: artifact, narrativeFallback: fallback, errorDetail: nil)
        } catch {
            let detail = String(describing: error)
            if job.state == .running {
                try? job.transition(to: .failed, at: now, detail: detail)
            }
            return RunOutcome(job: job, artifact: nil, narrativeFallback: false, errorDetail: detail)
        }
    }

    // MARK: - 本地因子降级叙述

    /// 本地因子版：指数涨跌 → 脉搏；因子评分首尾 → 强弱主题。无数据时
    /// 返回空叙述（artifact 仍生成，纯计算部分照常）。
    static func localNarrative(from digest: [MarketDigestItem]) -> CloseReviewNarrative {
        let pulse: [MarketCloseReview.PulseItem] = digest
            .filter { $0.kind == "index" }
            .compactMap { item in
                guard let changePct = item.changePct else { return nil }
                let direction: MarketPulseDirection = changePct > 0.05
                    ? .up : (changePct < -0.05 ? .down : .flat)
                return MarketCloseReview.PulseItem(
                    name: item.name,
                    direction: direction,
                    confidenceText: "本地行情",
                    rationale: "当日\(changePct >= 0 ? "上涨" : "下跌") \(String(format: "%.2f", abs(changePct)))%（本地数据，未消耗 AI）")
            }
        let factorItems = digest.filter { $0.kind == "factor" }
        let sorted = factorItems.sorted {
            ($0.factorScore ?? 0) > ($1.factorScore ?? 0)
        }
        var strong: [MarketCloseReview.ThemeItem] = []
        var weak: [MarketCloseReview.ThemeItem] = []
        if let top = sorted.first, let score = top.factorScore, score > 0 {
            strong.append(MarketCloseReview.ThemeItem(
                name: top.name, direction: .strong,
                rationale: "本地因子评分 \(String(format: "%.2f", score)) 领先"))
        }
        if let bottom = sorted.last, let score = bottom.factorScore, score < 0, bottom.name != sorted.first?.name {
            weak.append(MarketCloseReview.ThemeItem(
                name: bottom.name, direction: .weak,
                rationale: "本地因子评分 \(String(format: "%.2f", score)) 落后"))
        }
        return CloseReviewNarrative(marketPulse: pulse, strongThemes: strong, weakThemes: weak)
    }

    private static func encodeDigest(_ digest: [MarketDigestItem]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(digest), as: UTF8.self)
    }
}

// MARK: - 新鲜度状态机（展示层派生，不落盘）

/// 收盘复盘新鲜度（上海时区 21:00 日界判定）。
enum MarketCloseReviewFreshness: Sendable, Equatable {
    /// 今日复盘已生成。
    case todayDone
    /// 最近的复盘是往日的（今日未生成，今日 21:00 未到）。
    case awaitingTonight
    /// 今日 21:00 已过仍未生成（待补做）。
    case overdue
    /// 从未生成过。
    case neverGenerated

    /// 上海时区收盘时刻（21:00）后的当日判定。
    static func evaluate(latestReviewDate: Date?, producedAt: Date?, now: Date) -> MarketCloseReviewFreshness {
        let shanghai = TimeZone(identifier: "Asia/Shanghai") ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai
        let today = calendar.startOfDay(for: now)
        let closeTime = calendar.date(bySettingHour: 21, minute: 0, second: 0, of: now) ?? now
        let afterClose = now >= closeTime

        guard let reviewDate = latestReviewDate else { return .neverGenerated }
        let reviewDay = calendar.startOfDay(for: reviewDate)
        if calendar.isDate(reviewDay, inSameDayAs: today) {
            return .todayDone
        }
        // 复盘可能跨零点后生成（对应上一交易日）——今日收盘前视为等待今晚
        return afterClose ? .overdue : .awaitingTonight
    }
}

// MARK: - GRDB 落库便捷入口（App / CLI 接线用；对齐 MarketDiscoveryWorkflow 模式）

import GRDB

extension GRDBRepository {
    /// 收盘复盘幂等落库（ArtifactRow.write 语义，事务包裹）。
    func writeMarketCloseReview(_ review: MarketCloseReview) throws {
        try database.queue.write { db in
            try ArtifactRow.write(try ArtifactRow.from(review), into: db)
        }
    }

    /// 按 ID 读回收盘复盘（不存在 → nil；存在但损坏 → 抛错 fail-closed）。
    func marketCloseReview(id: String) throws -> MarketCloseReview? {
        try database.queue.read { db in
            do {
                return try ArtifactRow.fetchMarketCloseReview(id: id, from: db)
            } catch ArtifactReadError.notFound {
                return nil
            }
        }
    }
}
