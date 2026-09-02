import Foundation

// 阶段二：趋势研究 Agent 的不可变分析快照。
//
// 运行前由 @MainActor AppModel 把当前状态冻结成这份 Sendable 快照。后续所有工具
// 只查询该快照，不直接访问 AppModel，保证多轮模型调用读到同一份数据，后台刷新
// 不会改变本次分析依据，隐私过滤在进入 Agent 前一次完成。

// MARK: - 信号与行情

/// 平台/alfa/主理人关注信号。统一容纳长赢调仓、alfa 调仓和主理人巡检命中三类异构信号，
/// 每条带全局唯一的 evidenceID。
struct TrendResearchSignal: Sendable, Codable, Hashable, Identifiable {
    /// 来源：qieman（长赢调仓）/ alfa / manager（主理人关注命中）。
    let source: String
    /// 类型：adjustment（调仓动作）/ watch-hit（主理人巡检命中）。
    let kind: String
    let evidenceID: String
    /// 发生时间（来源时间字符串，保留原始格式）。
    let occurredAt: String?
    let fundCode: String?
    let fundName: String?
    /// 动作描述（如 buy/sell/加仓/减仓，或主理人命中类型）。
    let action: String?
    let title: String
    let detail: String?
    /// 长赢调仓的估值涨跌百分比；alfa 无此字段。
    let valuationChangePct: Double?
    /// alfa 调仓前后持仓比例（0~1）。
    let beforePercent: Double?
    let afterPercent: Double?
    let groupName: String?
    let sourcePoCode: String?
    let articleURL: String?

    var id: String { evidenceID }
}

/// 大盘指数或基金估值行情条目。
struct TrendResearchQuote: Sendable, Codable, Hashable, Identifiable {
    /// 类型：index（大盘指数）/ fund-estimate（基金估值）。
    let kind: String
    let evidenceID: String
    /// 指数 rawValue 或基金代码。
    let code: String
    let name: String
    let price: Double?
    let changePct: Double?
    let changeAmount: Double?
    let quotedAt: String?
    let sourceLabel: String?
    let assessment: TrendQuoteAssessment

    var id: String { evidenceID }

    init(
        kind: String,
        evidenceID: String,
        code: String,
        name: String,
        price: Double?,
        changePct: Double?,
        changeAmount: Double?,
        quotedAt: String?,
        sourceLabel: String?,
        assessment: TrendQuoteAssessment? = nil
    ) {
        self.kind = kind
        self.evidenceID = evidenceID
        self.code = code
        self.name = name
        self.price = price
        self.changePct = changePct
        self.changeAmount = changeAmount
        self.quotedAt = quotedAt
        self.sourceLabel = sourceLabel
        self.assessment = assessment ?? TrendQuoteAssessment(
            quoteType: .unknown,
            freshnessStatus: .unknown,
            asOf: quotedAt,
            receivedAt: quotedAt ?? "",
            ageSeconds: nil,
            marketSession: .unknown
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        evidenceID = try container.decode(String.self, forKey: .evidenceID)
        code = try container.decode(String.self, forKey: .code)
        name = try container.decode(String.self, forKey: .name)
        price = try container.decodeIfPresent(Double.self, forKey: .price)
        changePct = try container.decodeIfPresent(Double.self, forKey: .changePct)
        changeAmount = try container.decodeIfPresent(Double.self, forKey: .changeAmount)
        quotedAt = try container.decodeIfPresent(String.self, forKey: .quotedAt)
        sourceLabel = try container.decodeIfPresent(String.self, forKey: .sourceLabel)
        assessment = try container.decodeIfPresent(
            TrendQuoteAssessment.self,
            forKey: .assessment
        ) ?? TrendQuoteAssessment(
            quoteType: .unknown,
            freshnessStatus: .unknown,
            asOf: quotedAt,
            receivedAt: quotedAt ?? "",
            ageSeconds: nil,
            marketSession: .unknown
        )
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case evidenceID
        case code
        case name
        case price
        case changePct
        case changeAmount
        case quotedAt
        case sourceLabel
        case assessment
    }
}

/// 基金估值条目。由 AppModel 从个人持仓/关注/平台持仓估值行预先聚合成 [code: estimate]，
/// 避免快照构造器耦合多个 snapshot 模型。
struct TrendResearchFundEstimate: Sendable, Codable, Hashable {
    let code: String
    let name: String?
    let estimateChangePct: Double?
    let price: Double?
    let quotedAt: String?
    let sourceLabel: String?
    let quoteType: TrendQuoteType

    init(
        code: String,
        name: String?,
        estimateChangePct: Double?,
        price: Double?,
        quotedAt: String?,
        sourceLabel: String?,
        quoteType: TrendQuoteType = .unknown
    ) {
        self.code = code
        self.name = name
        self.estimateChangePct = estimateChangePct
        self.price = price
        self.quotedAt = quotedAt
        self.sourceLabel = sourceLabel
        self.quoteType = quoteType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        estimateChangePct = try container.decodeIfPresent(Double.self, forKey: .estimateChangePct)
        price = try container.decodeIfPresent(Double.self, forKey: .price)
        quotedAt = try container.decodeIfPresent(String.self, forKey: .quotedAt)
        sourceLabel = try container.decodeIfPresent(String.self, forKey: .sourceLabel)
        quoteType = try container.decodeIfPresent(TrendQuoteType.self, forKey: .quoteType) ?? .unknown
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case name
        case estimateChangePct
        case price
        case quotedAt
        case sourceLabel
        case quoteType
    }
}

// MARK: - 快照

struct TrendResearchSnapshot: Sendable, Hashable, Codable {
    let runID: UUID
    /// App 接受报告的时间。
    let createdAt: String
    /// 快照中用于分析的数据截止时间（保守取最新来源时间，无法确定时用 createdAt）。
    let dataAsOf: String
    let privacyMode: TrendPrivacyMode

    let portfolio: TrendContextPortfolio
    let assets: [TrendContextAsset]
    let sectors: [TrendContextSector]

    let platformSignals: [TrendResearchSignal]
    let managerSignals: [TrendResearchSignal]
    let marketQuotes: [TrendResearchQuote]
    /// 2026-09-02:closeReview 运行前算好的昨日判断对账（prompt 注入与冻结快照共用）。
    var closeReviewYesterdayAudit: [YesterdayJudgmentAuditEntry]? = nil
    /// 基于基金公开定期报告计算的组合穿透快照。比例字段不含金额，适用于两种隐私模式。
    let lookThrough: PortfolioLookThroughSnapshot?

    let insightHeadline: String
    let sourceWarnings: [String]
    let sourceStatuses: [TrendSourceStatus]

    init(
        runID: UUID,
        createdAt: String,
        dataAsOf: String,
        privacyMode: TrendPrivacyMode,
        portfolio: TrendContextPortfolio,
        assets: [TrendContextAsset],
        sectors: [TrendContextSector],
        platformSignals: [TrendResearchSignal],
        managerSignals: [TrendResearchSignal],
        marketQuotes: [TrendResearchQuote],
        closeReviewYesterdayAudit: [YesterdayJudgmentAuditEntry]? = nil,
        lookThrough: PortfolioLookThroughSnapshot? = nil,
        insightHeadline: String,
        sourceWarnings: [String],
        sourceStatuses: [TrendSourceStatus] = []
    ) {
        self.runID = runID
        self.createdAt = createdAt
        self.dataAsOf = dataAsOf
        self.privacyMode = privacyMode
        self.portfolio = portfolio
        self.assets = assets
        self.sectors = sectors
        self.platformSignals = platformSignals
        self.managerSignals = managerSignals
        self.marketQuotes = marketQuotes
        self.closeReviewYesterdayAudit = closeReviewYesterdayAudit
        self.lookThrough = lookThrough
        self.insightHeadline = insightHeadline
        self.sourceWarnings = sourceWarnings
        self.sourceStatuses = sourceStatuses
    }

    /// Validator 用来检查 assetTrends 覆盖率的基金代码全集：类型为基金且 code 非空。
    var expectedFundCodes: [String] {
        assets
            .filter { $0.assetType == PersonalAssetType.fund.displayName }
            .compactMap { $0.code }
    }

    /// 空占位快照，用于子 Agent 工具执行的兜底上下文（不执行真实搜索）。
    static let placeholder = TrendResearchSnapshot(
        runID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        createdAt: "",
        dataAsOf: "",
        privacyMode: .sanitized,
        portfolio: TrendContextPortfolio(
            assetCount: 0, holdingCount: 0, activePlanCount: 0, pendingAssetCount: 0,
            totalMarketValue: nil, totalPendingCashAmount: nil,
            totalEstimatedNextPlanAmount: nil, totalEffectiveHoldingAmount: nil
        ),
        assets: [], sectors: [],
        platformSignals: [], managerSignals: [],
        marketQuotes: [], lookThrough: nil,
        insightHeadline: "", sourceWarnings: [], sourceStatuses: []
    )
}

// MARK: - 构造器

/// 从 AppModel 各数据源组装不可变快照。
///
/// 设计为接受显式输入而非 AppModel 实例，便于在不启动完整 AppModel 的单元测试中直接构造。
/// portfolio/assets/sectors/insightHeadline 复用 TrendAnalysisContextBuilder（含脱敏），
/// 信号与行情在此构造为带稳定 evidenceID 的结构化数据。
struct TrendResearchSnapshotBuilder {
    /// 单个来源最多保留的信号条数，控制快照体积。
    static let maxSignalsPerSource = 20

    func build(
        rows: [PersonalAssetAggregateRow],
        summary: PersonalAssetAggregateSummary?,
        platformPayload: PlatformPayload?,
        alfaPayload: PlatformPayload?,
        managerWatchEvents: [ManagerWatchTimelineEvent],
        marketIndexQuotes: [MarketIndexKind: MarketIndexQuote],
        fundEstimates: [String: TrendResearchFundEstimate],
        underlyingStockQuotes: [String: NativeStockQuote] = [:],
        lookThrough: PortfolioLookThroughSnapshot? = nil,
        watchSummary: ManagerWatchTimelineSummary,
        insightSummary: PortfolioSnapshotInsightSummary,
        privacyMode: TrendPrivacyMode,
        runID: UUID,
        createdAt: String,
        dataAsOf: String,
        sourceWarnings: [String],
        sourceStatuses: [TrendSourceStatus] = [],
        closeReviewYesterdayAudit: [YesterdayJudgmentAuditEntry]? = nil
    ) -> TrendResearchSnapshot {
        // 复用现有 ContextBuilder 得到脱敏后的 portfolio/assets/sectors/insightHeadline。
        // platformActions 传空：结构化信号由快照自身持有，不再用字符串化版本。
        let context = TrendAnalysisContextBuilder().build(
            rows: rows,
            summary: summary,
            platformActions: [],
            watchSummary: watchSummary,
            insightSummary: insightSummary,
            privacyMode: privacyMode,
            createdAt: createdAt
        )

        let platformSignals = Self.signals(fromPlatform: platformPayload, source: "qieman")
            + Self.signals(fromPlatform: alfaPayload, source: "alfa")
        let managerSignals = Self.managerSignals(from: managerWatchEvents)
        let indexReceivedAt = sourceStatuses.first {
            $0.source == .marketIndex
        }?.receivedAt ?? createdAt
        let fundReceivedAt = sourceStatuses.first {
            $0.source == .fundNAV
        }?.receivedAt ?? createdAt
        let marketQuotes = Self.indexQuotes(
            from: marketIndexQuotes,
            receivedAt: indexReceivedAt
        ) + Self.fundEstimateQuotes(
            from: fundEstimates,
            receivedAt: fundReceivedAt
        ) + Self.underlyingStockQuotes(
            from: underlyingStockQuotes,
            receivedAt: fundReceivedAt
        )

        return TrendResearchSnapshot(
            runID: runID,
            createdAt: createdAt,
            dataAsOf: dataAsOf,
            privacyMode: privacyMode,
            portfolio: context.portfolio,
            assets: context.assets,
            sectors: context.sectors,
            platformSignals: platformSignals,
            managerSignals: managerSignals,
            marketQuotes: marketQuotes,
            closeReviewYesterdayAudit: closeReviewYesterdayAudit,
            lookThrough: lookThrough,
            insightHeadline: context.insightHeadline,
            sourceWarnings: sourceWarnings,
            sourceStatuses: sourceStatuses
        )
    }

    // MARK: 信号构造

    private static func signals(fromPlatform payload: PlatformPayload?, source: String) -> [TrendResearchSignal] {
        guard let actions = payload?.actions else { return [] }
        return actions.prefix(maxSignalsPerSource).compactMap { action in
            // 缺少标识的动作无法形成稳定 evidenceID，跳过。
            guard action.actionKey != nil
                || action.adjustmentId != nil
                || action.fundCode != nil else { return nil }
            return TrendResearchSignal(
                source: source,
                kind: "adjustment",
                evidenceID: "platform:\(source):\(platformActionID(action))",
                occurredAt: action.txnDate ?? action.createdAt,
                fundCode: action.fundCode,
                fundName: action.fundName,
                action: action.action ?? action.side,
                title: platformActionTitle(action),
                detail: action.comment,
                valuationChangePct: action.valuationChangePct,
                beforePercent: action.beforePercent,
                afterPercent: action.afterPercent,
                groupName: action.groupName,
                sourcePoCode: action.sourcePoCode,
                articleURL: action.articleUrl
            )
        }
    }

    static func managerSignals(from events: [ManagerWatchTimelineEvent]) -> [TrendResearchSignal] {
        events
            // 调仓动作已经由 qieman/alfa 的结构化平台信号提供。
            // 巡检层只补充论坛命中，避免同一调仓被 AI 当成两份独立证据。
            .filter { $0.kind == .forumHit }
            .prefix(maxSignalsPerSource)
            .map { event in
                TrendResearchSignal(
                    source: "manager",
                    kind: "watch-hit",
                    evidenceID: "manager:\(event.kind.rawValue):\(event.targetID ?? event.id.uuidString)",
                    occurredAt: Self.isoFormatter.string(from: event.occurredAt),
                    fundCode: nil,
                    fundName: event.managerName.isEmpty ? nil : event.managerName,
                    action: event.kind.rawValue,
                    title: event.title,
                    detail: event.detail.isEmpty ? nil : event.detail,
                    valuationChangePct: nil,
                    beforePercent: nil,
                    afterPercent: nil,
                    groupName: nil,
                    sourcePoCode: event.prodCode.isEmpty ? nil : event.prodCode,
                    articleURL: nil
                )
            }
    }

    private static func platformActionID(_ action: PlatformActionPayload) -> String {
        if let key = action.actionKey, !key.isEmpty { return key }
        return "\(action.adjustmentId ?? 0)-\(action.fundCode ?? "")-\(action.txnDate ?? action.createdAt ?? "")"
    }

    private static func platformActionTitle(_ action: PlatformActionPayload) -> String {
        if let title = action.actionTitle, !title.isEmpty { return title }
        if let title = action.adjustmentTitle, !title.isEmpty { return title }
        if let title = action.title, !title.isEmpty { return title }
        return action.fundName ?? action.fundCode ?? "调仓动作"
    }

    // MARK: 行情构造

    private static func indexQuotes(
        from quotes: [MarketIndexKind: MarketIndexQuote],
        receivedAt: String
    ) -> [TrendResearchQuote] {
        quotes.values.map { quote in
            let assessment = TrendSourceFreshnessPolicy.assess(
                quoteType: .indexQuote,
                asOf: quote.quotedAt,
                receivedAt: receivedAt
            )
            return TrendResearchQuote(
                kind: "index",
                evidenceID: "market:index:\(quote.kind.rawValue):\(quote.quotedAt)",
                code: quote.kind.rawValue,
                name: quote.name,
                price: quote.price,
                changePct: quote.changePct,
                changeAmount: quote.changeAmount,
                quotedAt: quote.quotedAt,
                sourceLabel: quote.sourceLabel,
                assessment: assessment
            )
        }
    }

    private static func fundEstimateQuotes(
        from estimates: [String: TrendResearchFundEstimate],
        receivedAt: String
    ) -> [TrendResearchQuote] {
        estimates.values.map { estimate in
            let assessment = TrendSourceFreshnessPolicy.assess(
                quoteType: estimate.quoteType,
                asOf: estimate.quotedAt,
                receivedAt: receivedAt
            )
            return TrendResearchQuote(
                kind: "fund-estimate",
                evidenceID: "market:fund-estimate:\(estimate.code):\(estimate.quotedAt ?? "")",
                code: estimate.code,
                name: estimate.name ?? estimate.code,
                price: estimate.price,
                changePct: estimate.estimateChangePct,
                changeAmount: nil,
                quotedAt: estimate.quotedAt,
                sourceLabel: estimate.sourceLabel,
                assessment: assessment
            )
        }
    }

    private static func underlyingStockQuotes(
        from quotes: [String: NativeStockQuote],
        receivedAt: String
    ) -> [TrendResearchQuote] {
        quotes
            .sorted { $0.key < $1.key }
            .compactMap { requestedCode, quote in
                guard quote.hasUsableData, !quote.priceTime.isEmpty else { return nil }
                // 保留披露中的请求代码，确保能和来源基金的 contributor 稳定关联。
                let code = requestedCode
                let assessment = TrendSourceFreshnessPolicy.assess(
                    quoteType: .lastTrade,
                    asOf: quote.priceTime,
                    receivedAt: receivedAt
                )
                return TrendResearchQuote(
                    kind: "underlying-stock",
                    evidenceID: "market:stock:\(code):\(quote.priceTime)",
                    code: code,
                    name: quote.stockName.isEmpty ? code : quote.stockName,
                    price: quote.price > 0 ? quote.price : nil,
                    changePct: quote.changePct,
                    changeAmount: quote.previousClose.flatMap { previousClose in
                        quote.price > 0 ? quote.price - previousClose : nil
                    },
                    quotedAt: quote.priceTime,
                    sourceLabel: quote.priceSourceLabel.isEmpty ? "底层证券行情" : quote.priceSourceLabel,
                    assessment: assessment
                )
            }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
