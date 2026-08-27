import Foundation

// MARK: - 投资智能 Dashboard Presentation DTO（PRES 层，产品重构方案 §5.2）
//
// UI 消费 V2 产出的唯一聚合形态（macOS / iOS 共用）。纪律：
// - 只包含 UI 所需的结构化字段，不含预拼接的调试串；文案由
//   IntelligencePresentationFormatter 稳定生成，View 只做布局
// - 状态使用 enum（.ready / .missingTarget / .stale / ...），UI 不做字符串判断
// - HistoryItem 携带稳定 Artifact ID 作内部 id，但首页不直接显示 ID
// - 聚合入口在 ArtifactQueryService.dashboardSnapshot（fail-closed：查询
//   失败抛错，AppModel 捕获后映射为用户可见错误状态）

/// 投资智能主页面快照。
struct InvestmentIntelligenceDashboardSnapshot: Sendable, Equatable {
    let generatedAt: Date
    let headline: Headline
    let allocation: AllocationSummary
    let readiness: ReadinessSummary
    let intraday: IntradaySummary?
    let discovery: DiscoverySummary?
    let research: ResearchSummary?
    let closeReview: CloseReviewSummary?
    let history: [HistoryItem]
}

// MARK: - 今日结论

extension InvestmentIntelligenceDashboardSnapshot {

    struct Headline: Sendable, Equatable {
        enum Status: Sendable, Equatable {
            /// 建议再平衡（盘中报告 EXECUTE 或偏差超容忍带）
            case rebalanceSuggested
            /// 维持配置（HOLD，带内）
            case holdConfigured
            /// 暂不可判断（输入就绪但无有效结论，如报告过期）
            case undecidable
            /// 尚未准备（存在 readiness blocker）
            case notReady
        }

        let status: Status
        /// 一句话主因（Formatter 生成）。
        let reason: String
        /// 报告有效期说明（人话；nil = 不适用）。
        let validityNote: String?
        /// 数据更新时间（最新产出 / 估值时间）。
        let dataAsOf: Date?
    }
}

// MARK: - 战略配置与偏差

extension InvestmentIntelligenceDashboardSnapshot {

    struct AllocationSummary: Sendable, Equatable {
        struct Row: Sendable, Equatable {
            let assetClass: AssetClass
            /// 当前占比（分类被阻断时 nil——UI 显示「数据不足」而非 0）。
            let currentWeight: Decimal?
            /// 目标占比（五类齐备）。
            let targetWeight: Decimal
            /// 偏差（current − target；current nil 时 nil）。
            let deviation: Decimal?
        }

        let targetConfigured: Bool
        let targetRecordedAt: Date?
        /// 五类全量行（AssetClass.allCases 顺序）。
        let rows: [Row]
    }
}

// MARK: - 系统状态 / 就绪度

extension InvestmentIntelligenceDashboardSnapshot {

    struct ReadinessSummary: Sendable, Equatable {
        /// 输入就绪阻断（nil = 就绪；优先级自上而下）。
        enum Blocker: Sendable, Equatable {
            case missingTarget
            case unclassifiedHoldings([String])
            case staleValuation(latestAsOf: Date)
        }

        struct MarketCoverage: Sendable, Equatable {
            let covered: Int
            let total: Int
        }

        let blocker: Blocker?
        /// 市场数据覆盖（最新发现报告派生；nil = 尚无报告）。
        let marketCoverage: MarketCoverage?
        /// AI 模型是否已配置（研究链路可用性）。
        let providerConfigured: Bool
    }
}

// MARK: - 盘中执行建议

extension InvestmentIntelligenceDashboardSnapshot {

    struct IntradaySummary: Sendable, Equatable {
        enum Decision: Sendable, Equatable {
            case executeRebalance
            case hold
        }

        enum Validity: Sendable, Equatable {
            case current
            case expired
        }

        struct PlannedMove: Sendable, Equatable {
            enum Direction: Sendable, Equatable {
                case increase
                case decrease
            }

            let subjectKey: String
            let direction: Direction
            /// Δw（Decimal 精确）。
            let weightChange: Decimal
            /// provenance 的人话来源（Formatter 生成，不透出 enum raw value）。
            let provenanceKind: ProvenanceKind

            enum ProvenanceKind: Sendable, Equatable {
                case targetFollow
                case remediation
                case userDirective
            }
        }

        let decision: Decision
        let holdReasons: [String]
        let moves: [PlannedMove]
        let validity: Validity
        let producedAt: Date
        /// 报告 artifact id（内部 id——首页不显示，详情技术信息区用）。
        let artifactID: String
        /// 报告参照的 target id（详情技术信息区用）。
        let targetID: String?
    }
}

// MARK: - 市场机会

extension InvestmentIntelligenceDashboardSnapshot {

    struct DiscoverySummary: Sendable, Equatable {
        enum State: Sendable, Equatable {
            /// 有候选
            case hasCandidates
            /// 数据齐备但无候选过阈值（真·暂无机会）
            case noCandidates
            /// 覆盖不足（多数标的没数据）——不显示「暂无机会」误导
            case insufficientData
        }

        struct Candidate: Sendable, Equatable {
            let rank: Int
            let name: String
            /// 综合分（Decimal）。
            let score: Decimal
            /// 关键因子方向摘要（如「动量 ↑ · 回撤 ↓」）。
            let factorsSummary: String
            /// 失效条件（审计 B2：本地因子派生的自然语言条件，人工复核）。
            let invalidationNote: String
        }

        let state: State
        let topCandidates: [Candidate]
        let coverage: ReadinessSummary.MarketCoverage
        let producedAt: Date
    }
}

// MARK: - 组合研究

extension InvestmentIntelligenceDashboardSnapshot {

    struct ResearchSummary: Sendable, Equatable {
        /// ResearchNarrator headline（组合论点概要）。
        let narrativeHeadline: String
        /// 组合论点全文。
        let portfolioStatement: String
        /// 主要风险 / 信号摘要（前 3 条）。
        let topSignals: [String]
        /// 信号明细（审计 A6：每条信号可点开看证据）。
        let signalDetails: [SignalDigest]
        /// 行动候选（审计 B3：来自最新决策 artifact 的胜者计划动作，
        /// 可「加入跟踪」直通决策事项）。
        let actionCandidates: [ActionCandidate]
        let evidenceCount: Int
        let signalCount: Int
        let producedAt: Date?
    }

    /// 单条信号的展示摘要（含证据引用，供证据明细 Sheet）。
    struct SignalDigest: Sendable, Equatable, Identifiable {
        let id: String
        /// 人话信号描述（维度 · 方向 · 强度 + 理由）。
        let text: String
        /// 引用的 EvidenceID（原始值——查询证据明细用）。
        let evidenceIDs: [String]
    }

    /// 研究行动候选（「加入跟踪」建案素材）。
    struct ActionCandidate: Sendable, Equatable, Identifiable {
        var id: String { "\(artifactID)|\(subjectKey)|\(directionText)" }
        let subjectKey: String
        /// 方向人话（增持 / 减持）。
        let directionText: String
        /// 建案理由（Δw + provenance 人话）。
        let rationaleText: String
        let artifactID: String
    }
}

// MARK: - 研究证据摘要（审计 A6：证据明细读面 DTO）

/// 单条证据的用户可见摘要（来源 / 数据截至 / 内容节选）。
struct ResearchEvidenceDigest: Sendable, Equatable, Identifiable {
    /// 行主键 ObservationID（最新 vintage 的那一行）。
    let id: String
    let evidenceID: String
    /// 来源人话（SEC 文件 / 网络检索 / Provider 公告…）。
    let sourceName: String
    /// 关联主体（如招商银行 / portfolio_live）。
    let subjectText: String
    /// 内容节选（前 240 字）。
    let contentExcerpt: String
    /// 数据发布时间（nil = 未知）。
    let publishedAt: Date?
    /// 可用时间（抓取/入库参考）。
    let availableAt: Date?
}

// MARK: - 收盘复盘（审计 A1）

extension InvestmentIntelligenceDashboardSnapshot {

    struct CloseReviewSummary: Sendable, Equatable {
        enum State: Sendable, Equatable {
            /// 今日复盘已生成
            case todayDone
            /// 今日 21:00 未到（最近复盘是往日的）
            case awaitingTonight
            /// 今日 21:00 已过仍未生成（待补做）
            case overdue
            /// 从未生成
            case neverGenerated
        }

        let state: State
        let producedAt: Date
        /// 复盘覆盖的交易日。
        let reviewDate: Date
        let dailyChangeAmount: Double?
        let dailyChangePct: Double?
        let holdingCount: Int
        let coveredHoldingCount: Int
        /// 逐持仓影响（|changeAmount| 降序）。
        let topImpacts: [MarketCloseReview.PortfolioReview.HoldingImpact]
        let tomorrowWatch: [String]
        let narrativeSource: CloseReviewNarrativeSource
        /// 报告 artifact id（详情入口用）。
        let artifactID: String
    }
}

// MARK: - 最近记录

extension InvestmentIntelligenceDashboardSnapshot {

    struct HistoryItem: Sendable, Equatable, Identifiable {
        enum Kind: String, Sendable {
            case intraday
            case decision
            case discovery
            case closeReview
        }

        /// 稳定内部 id（artifact id——首页不显示，详情/复制诊断用）。
        var id: String { artifactID }

        let kind: Kind
        /// 结论人话（Formatter 生成）。
        let conclusionText: String
        let producedAt: Date
        let isValid: Bool
        let artifactID: String
        /// 报告参照的 target 是否能在用户意图历史中解析（旧自复制 Target
        /// 产物为 false——审计可见但不冒充有效用户结论）。
        let targetResolvable: Bool
    }
}

// MARK: - 聚合输入（App 侧装配，DB 外的用户意图材料）

/// Dashboard 聚合的用户意图输入（Target Store / 分类解析在 App 侧完成；
/// Query Service 只做 DB 读取 + Narrator 解释，不重算决策）。
struct IntelligenceDashboardUserMaterials: Sendable {
    /// 当前生效用户目标（nil = 未设定）。
    let currentTarget: AllocationTarget?
    /// 合法 target 历史ID（有效性过滤：artifact 内嵌 target 不可解析 → 不进有效结论）。
    let resolvableTargetIDs: Set<String>
    /// 当前资产类聚合权重（已解析分类；分类被阻断时 nil）。
    let currentClassWeights: [AssetClass: Decimal]?
    /// unresolved 正权重 subject（非空 = 分类阻断）。
    let unresolvedSubjects: [String]
    /// 估值陈旧信号（App 侧判定；非 nil = 陈旧阻断，值为最新估值日期）。
    let valuationStaleAsOf: Date?
    /// AI 模型已配置（研究链路可用性提示）。
    let providerConfigured: Bool
}
