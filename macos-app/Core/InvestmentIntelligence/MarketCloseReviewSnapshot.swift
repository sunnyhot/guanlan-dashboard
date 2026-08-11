import Foundation

/// 收盘复盘的纯派生模型。
///
/// 以冻结的组合涨跌和逐只持仓归因为主；若报告恰好携带市场环境则作为可选补充。
/// 不读取 DecisionCase，避免重新引入与长期组合研判重复的决策事项列表。
struct MarketCloseReviewSnapshot: Codable, Hashable {
    enum State: String, Codable, Hashable {
        case noScan
        case scanning
        case awaitingClose
        case ready
        case stale
    }

    struct PulseItem: Codable, Identifiable, Hashable {
        let id: String
        let name: String
        let category: String
        let direction: TrendDirection
        let confidenceText: String
        let rationale: String
    }

    struct ThemeItem: Codable, Identifiable, Hashable {
        let id: String
        let name: String
        let direction: TrendDirection
        let confidenceText: String
        let rationale: String
    }

    struct HoldingImpactItem: Codable, Identifiable, Hashable {
        let id: String
        let name: String
        let code: String
        let market: StockMarket?
        let changeAmount: Double?
        let changePct: Double?
        let analysis: String?
        let watchText: String?
        let evidenceIDs: [String]
    }

    struct PortfolioReview: Codable, Hashable {
        let changeTitle: String
        let dailyChangeAmount: Double?
        let dailyChangePct: Double?
        let totalMarketValue: Double
        let holdingCount: Int
        let coveredHoldingCount: Int
        let refreshedAt: String
        let holdingImpacts: [HoldingImpactItem]
    }

    var state: State
    var subtitle: String
    var eyebrow: String
    let headline: String
    let summary: String
    let marketPulse: [PulseItem]
    let strongThemes: [ThemeItem]
    let weakThemes: [ThemeItem]
    let portfolioReview: PortfolioReview?
    let tomorrowWatch: [String]
    let evidenceText: String?
    let dataBoundary: String

    static func make(
        report: TrendAnalysisReport?,
        portfolioSnapshot: UserPortfolioSnapshot? = nil,
        recoveredPortfolioAssets: [TrendContextAsset] = [],
        generationState: TrendGenerationState,
        currentTimestamp: String,
        closeReviewGeneratedAt: String? = nil
    ) -> MarketCloseReviewSnapshot {
        let portfolioReview = makePortfolioReview(
            snapshot: portfolioSnapshot,
            report: report,
            marketDate: day(from: currentTimestamp) ?? ""
        ) ?? makeRecoveredPortfolioReview(
            assets: recoveredPortfolioAssets,
            report: report,
            refreshedAt: closeReviewGeneratedAt ?? currentTimestamp
        )

        if generationState == .generating {
            // 生成中：如果有可用的旧报告，先沿用旧结果展示，避免整片空白。
            // 仅把状态标为 .scanning、副标题点明「展示上一次结果」，视图据此叠加进度条。
            if let report {
                var snapshot = buildReadySnapshot(
                    report: report,
                    portfolioReview: portfolioReview,
                    currentTimestamp: currentTimestamp,
                    closeReviewGeneratedAt: closeReviewGeneratedAt
                )
                snapshot.state = .scanning
                let generatedText = String((closeReviewGeneratedAt ?? report.generatedAt).prefix(16))
                snapshot.subtitle = "正在更新 · 暂时展示 \(generatedText) 的结果"
                snapshot.eyebrow = "复盘中·展示旧结果"
                return snapshot
            }
            // 没有可用旧报告：保持原有的生成中占位文案。
            return baseSnapshot(
                state: .scanning,
                eyebrow: "扫描进行中",
                headline: "正在整理今天的持仓收盘数据",
                summary: portfolioReview == nil
                    ? "读取收盘行情与冻结持仓后，这里会生成组合涨跌、主要影响和次日观察。"
                    : "组合涨跌已经就绪，正在补齐逐只持仓归因与次日观察。",
                portfolioReview: portfolioReview
            )
        }

        guard let report else {
            return baseSnapshot(
                state: .noScan,
                eyebrow: "等待收盘复盘",
                headline: "今天还没有可用的收盘复盘",
                summary: portfolioReview == nil
                    ? "每日 21:00 会冻结当日持仓与收盘行情，生成组合得失和次日观察点。"
                    : "组合涨跌已经就绪，完成收盘复盘后会补齐持仓归因与次日观察。",
                portfolioReview: portfolioReview
            )
        }

        return buildReadySnapshot(
            report: report,
            portfolioReview: portfolioReview,
            currentTimestamp: currentTimestamp,
            closeReviewGeneratedAt: closeReviewGeneratedAt
        )
    }

    /// 构建以组合为主的复盘快照；市场结论存在时才作为补充展示。
    private static func buildReadySnapshot(
        report: TrendAnalysisReport,
        portfolioReview: PortfolioReview?,
        currentTimestamp: String,
        closeReviewGeneratedAt: String?
    ) -> MarketCloseReviewSnapshot {
        let marketWide = report.opportunities.filter { $0.scope == .marketWide }

        let effectiveGeneratedAt = closeReviewGeneratedAt ?? report.generatedAt
        let reportDay = day(from: effectiveGeneratedAt)
        let currentDay = day(from: currentTimestamp)
        let isCurrentDay = reportDay != nil && reportDay == currentDay
        let beforeClose = isCurrentDay && time(from: currentTimestamp) < "15:00"
        let state: State = beforeClose ? .awaitingClose : (isCurrentDay ? .ready : .stale)

        let pulse = makeMarketPulse(report: report, marketWide: marketWide)
        let themes = makeThemes(marketWide)
        let strongThemes = themes.filter { $0.direction.isCloseReviewPositive }
        let weakThemes = themes.filter { $0.direction.isCloseReviewNegative }
        let watch = makeTomorrowWatch(
            report: report,
            marketWide: marketWide,
            portfolioReview: portfolioReview
        )
        let evidenceIDs = reviewEvidenceIDs(
            report: report,
            marketWide: marketWide,
            portfolioReview: portfolioReview
        )
        let generatedText = String(effectiveGeneratedAt.prefix(16))
        let marketSummary = summary(
            pulse: pulse,
            strongThemes: strongThemes,
            weakThemes: weakThemes,
            portfolioReview: portfolioReview
        )
        let hasMarketContext = !pulse.isEmpty || !strongThemes.isEmpty || !weakThemes.isEmpty

        return MarketCloseReviewSnapshot(
            state: state,
            subtitle: state == .stale
                ? (hasMarketContext ? "最近一次市场与组合复盘 · \(generatedText)" : "最近一次组合收盘复盘 · \(generatedText)")
                : (hasMarketContext ? "收盘环境 × 我的组合 · \(generatedText)" : "我的组合收盘复盘 · \(generatedText)"),
            eyebrow: beforeClose ? "盘中观察" : (state == .stale ? "最近复盘" : "收盘复盘"),
            headline: headline(
                pulse: pulse,
                strongThemes: strongThemes,
                weakThemes: weakThemes,
                portfolioReview: portfolioReview
            ),
            summary: marketSummary,
            marketPulse: Array(pulse.prefix(4)),
            strongThemes: Array(strongThemes.prefix(3)),
            weakThemes: Array(weakThemes.prefix(3)),
            portfolioReview: portfolioReview,
            tomorrowWatch: Array(watch.prefix(3)),
            evidenceText: evidenceIDs.isEmpty
                ? "复盘结论缺少可追溯证据，已降级为观察"
                : "复盘引用 \(evidenceIDs.count) 条去重证据",
            dataBoundary: beforeClose
                ? "当前仍在盘中，组合按最新估值展示，不把盘中变化冒充收盘结论。"
                : (hasMarketContext
                    ? "基于收盘时冻结的个人持仓涨跌与当时已有的市场环境；缺失净值不补零。"
                    : "基于收盘时冻结的个人持仓涨跌与持仓归因；未使用次日盘中数据，也不依赖全市场机会雷达。")
        )
    }

    private static func baseSnapshot(
        state: State,
        eyebrow: String,
        headline: String,
        summary: String,
        portfolioReview: PortfolioReview?
    ) -> MarketCloseReviewSnapshot {
        MarketCloseReviewSnapshot(
            state: state,
            subtitle: "组合得失、持仓归因与次日观察",
            eyebrow: eyebrow,
            headline: headline,
            summary: summary,
            marketPulse: [],
            strongThemes: [],
            weakThemes: [],
            portfolioReview: portfolioReview,
            tomorrowWatch: [],
            evidenceText: nil,
            dataBoundary: portfolioReview == nil
                ? "等待下一次收盘复盘冻结个人持仓数据。"
                : "组合涨跌按收盘时冻结的持仓数据计算；缺失净值不会按零处理。"
        )
    }

    private static func makePortfolioReview(
        snapshot: UserPortfolioSnapshot?,
        report: TrendAnalysisReport?,
        marketDate: String
    ) -> PortfolioReview? {
        guard let snapshot, !snapshot.rows.isEmpty else { return nil }

        let reportAssets = report.map { $0.assetTrends + $0.keyAssets } ?? []
        let impacts = snapshot.rows.map { row -> HoldingImpactItem in
            let changeAmount = row.estimatedDailyChangeAmount
            let changePct = row.estimateChangePct

            let asset = matchingAsset(for: row, in: reportAssets)
            return HoldingImpactItem(
                id: row.id.uuidString,
                name: row.fundName,
                code: row.holding.normalizedFundCode,
                market: row.holding.detectedMarket,
                changeAmount: changeAmount,
                changePct: changePct,
                analysis: TrendAssetDailyAttributionPolicy.displayText(
                    from: asset?.impactText,
                    hasDailyChange: changeAmount != nil || changePct != nil
                ),
                watchText: asset?.counterSignals.compactMap(\.nonEmpty).first,
                evidenceIDs: asset.map {
                    unique($0.claimEvidence.allEvidenceIDs)
                } ?? []
            )
        }
        .sorted(by: holdingImpactSort)

        return PortfolioReview(
            changeTitle: snapshot.dailyChangeTitle(marketDate: marketDate),
            dailyChangeAmount: snapshot.dailyChangeSummary.amount,
            dailyChangePct: snapshot.dailyChangeSummary.pct,
            totalMarketValue: snapshot.totalMarketValue,
            holdingCount: snapshot.holdingCount,
            coveredHoldingCount: snapshot.dailyChangeCoverageCount,
            refreshedAt: snapshot.refreshedAt,
            holdingImpacts: Array(impacts.prefix(5))
        )
    }

    /// 旧版本没有独立归档组合快照，但运行日志中保留了 Agent 当时读到的
    /// `get_portfolio_assets` 结果。这里仅从该冻结数据重建当日涨跌，不读取当前盘中持仓。
    private static func makeRecoveredPortfolioReview(
        assets: [TrendContextAsset],
        report: TrendAnalysisReport?,
        refreshedAt: String
    ) -> PortfolioReview? {
        let heldAssets = assets.filter {
            $0.marketValue != nil || $0.costValue != nil || $0.profitAmount != nil
        }
        guard !heldAssets.isEmpty else { return nil }

        let reportAssets = report.map { $0.assetTrends + $0.keyAssets } ?? []
        let impacts = heldAssets.map { asset -> HoldingImpactItem in
            let reportAsset = matchingAsset(for: asset, in: reportAssets)
            let changeAmount = recoveredDailyChangeAmount(asset)
            return HoldingImpactItem(
                id: asset.id,
                name: asset.name,
                code: asset.code ?? "",
                market: nil,
                changeAmount: changeAmount,
                changePct: asset.estimateChangePct,
                analysis: TrendAssetDailyAttributionPolicy.displayText(
                    from: reportAsset?.impactText,
                    hasDailyChange: changeAmount != nil || asset.estimateChangePct != nil
                ),
                watchText: reportAsset?.counterSignals.compactMap(\.nonEmpty).first,
                evidenceIDs: unique(
                    ["portfolio:asset:\(asset.id)"]
                        + (reportAsset?.claimEvidence.allEvidenceIDs ?? [])
                )
            )
        }
        .sorted(by: holdingImpactSort)

        let covered = heldAssets.compactMap { asset -> (change: Double, previous: Double)? in
            guard let change = recoveredDailyChangeAmount(asset),
                  let marketValue = asset.marketValue else { return nil }
            let previous = marketValue - change
            guard previous > 0 else { return nil }
            return (change, previous)
        }
        let dailyChangeAmount = covered.isEmpty
            ? nil
            : covered.reduce(0) { $0 + $1.change }
        let previousTotal = covered.reduce(0) { $0 + $1.previous }
        let dailyChangePct = previousTotal > 0
            ? covered.reduce(0) { $0 + $1.change } / previousTotal * 100
            : nil

        return PortfolioReview(
            changeTitle: "当日涨跌",
            dailyChangeAmount: dailyChangeAmount,
            dailyChangePct: dailyChangePct,
            totalMarketValue: heldAssets.compactMap(\.marketValue).reduce(0, +),
            holdingCount: heldAssets.count,
            coveredHoldingCount: heldAssets.filter {
                $0.estimateChangePct != nil && $0.marketValue != nil
            }.count,
            refreshedAt: refreshedAt,
            holdingImpacts: Array(impacts.prefix(5))
        )
    }

    private static func recoveredDailyChangeAmount(_ asset: TrendContextAsset) -> Double? {
        guard let marketValue = asset.marketValue,
              let changePct = asset.estimateChangePct else { return nil }
        let factor = 1 + changePct / 100
        guard factor > 0 else { return nil }
        return marketValue - marketValue / factor
    }

    private static func matchingAsset(
        for row: UserPortfolioValuationRow,
        in assets: [TrendAssetView]
    ) -> TrendAssetView? {
        let code = normalizedAssetCode(row.holding.normalizedFundCode)
        if let byCode = assets.first(where: {
            guard let assetCode = $0.code else { return false }
            return normalizedAssetCode(assetCode) == code
        }) {
            return byCode
        }

        let name = normalized(row.fundName)
        return assets.first { normalized($0.name) == name }
    }

    private static func matchingAsset(
        for recovered: TrendContextAsset,
        in assets: [TrendAssetView]
    ) -> TrendAssetView? {
        if let recoveredCode = recovered.code {
            let code = normalizedAssetCode(recoveredCode)
            if let byCode = assets.first(where: {
                guard let assetCode = $0.code else { return false }
                return normalizedAssetCode(assetCode) == code
            }) {
                return byCode
            }
        }
        let name = normalized(recovered.name)
        return assets.first { normalized($0.name) == name }
    }

    private static func normalizedAssetCode(_ value: String) -> String {
        normalized(UserPortfolioHolding.normalizedFundCode(from: value))
    }

    private static func holdingImpactSort(
        _ lhs: HoldingImpactItem,
        _ rhs: HoldingImpactItem
    ) -> Bool {
        let lhsHasChange = lhs.changeAmount != nil || lhs.changePct != nil
        let rhsHasChange = rhs.changeAmount != nil || rhs.changePct != nil
        if lhsHasChange != rhsHasChange { return lhsHasChange }

        let lhsMagnitude = abs(lhs.changeAmount ?? lhs.changePct ?? 0)
        let rhsMagnitude = abs(rhs.changeAmount ?? rhs.changePct ?? 0)
        if lhsMagnitude != rhsMagnitude { return lhsMagnitude > rhsMagnitude }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func makeMarketPulse(
        report: TrendAnalysisReport,
        marketWide: [TrendOpportunity]
    ) -> [PulseItem] {
        var items = report.marketOutlook.map {
            PulseItem(
                id: "outlook:\($0.id)",
                name: $0.name,
                category: $0.categoryDisplayName,
                direction: $0.direction,
                confidenceText: $0.confidence.appText,
                rationale: $0.rationale
            )
        }
        items.append(contentsOf: marketWide.compactMap { opportunity in
            guard let category = closeReviewCategory(opportunity.category), category != .sector else {
                return nil
            }
            return PulseItem(
                id: "opportunity:\(opportunity.id)",
                name: opportunity.name,
                category: category.displayName,
                direction: opportunity.direction,
                confidenceText: opportunity.confidence.appText,
                rationale: opportunity.rationale
            )
        })
        return deduplicate(items) { "\($0.category):\(normalized($0.name))" }
            .sorted(by: pulseSort)
    }

    private static func makeThemes(_ marketWide: [TrendOpportunity]) -> [ThemeItem] {
        let themes = marketWide.compactMap { opportunity -> ThemeItem? in
            guard closeReviewCategory(opportunity.category) == .sector else { return nil }
            return ThemeItem(
                id: opportunity.id,
                name: opportunity.name,
                direction: opportunity.direction,
                confidenceText: opportunity.confidence.appText,
                rationale: opportunity.rationale
            )
        }
        return deduplicate(themes) { normalized($0.name) }
            .sorted { lhs, rhs in
                if lhs.confidenceText != rhs.confidenceText {
                    return confidenceScore(lhs.confidenceText) > confidenceScore(rhs.confidenceText)
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private static func makeTomorrowWatch(
        report: TrendAnalysisReport,
        marketWide: [TrendOpportunity],
        portfolioReview: PortfolioReview?
    ) -> [String] {
        var items: [String] = []
        let ranked = marketWide.sorted {
            $0.confidence.normalizedScore > $1.confidence.normalizedScore
        }
        if let positive = ranked.first(where: { $0.direction.isCloseReviewPositive }),
           let trigger = positive.triggerConditions.first?.nonEmpty {
            items.append("确认主线 · \(positive.name)：\(trigger)")
        }
        if let negative = ranked.first(where: { $0.direction.isCloseReviewNegative }) {
            let risk = negative.counterSignals.first?.nonEmpty
                ?? negative.invalidatingConditions.first?.nonEmpty
            if let risk {
                items.append("风险观察 · \(negative.name)：\(risk)")
            }
        }
        if let impact = portfolioReview?.holdingImpacts.first(where: { $0.watchText != nil }),
           let watchText = impact.watchText {
            items.append("持仓验证 · \(impact.name)：\(watchText)")
        }
        if let marketRisk = report.marketOutlook
            .flatMap(\.counterSignals)
            .compactMap(\.nonEmpty)
            .first {
            items.append("市场验证：\(marketRisk)")
        }
        return unique(items)
    }

    private static func headline(
        pulse: [PulseItem],
        strongThemes: [ThemeItem],
        weakThemes: [ThemeItem],
        portfolioReview: PortfolioReview?
    ) -> String {
        let positivePulse = pulse.filter { $0.direction.isCloseReviewPositive }.count
        let negativePulse = pulse.filter { $0.direction.isCloseReviewNegative }.count
        if let strong = strongThemes.first, let weak = weakThemes.first {
            return "收盘结构分化：\(strong.name)偏强，\(weak.name)承压"
        }
        if positivePulse > negativePulse, let strong = strongThemes.first {
            return "市场环境偏强，\(strong.name)是主要线索"
        }
        if negativePulse > positivePulse {
            return weakThemes.first.map { "市场环境偏弱，\($0.name)风险更突出" }
                ?? "市场环境偏弱，先看风险是否收敛"
        }
        if let strong = strongThemes.first {
            return "市场结构分化，\(strong.name)相对占优"
        }
        if let portfolioReview {
            let positive = portfolioReview.holdingImpacts.first {
                ($0.changeAmount ?? $0.changePct ?? 0) > 0
            }
            let negative = portfolioReview.holdingImpacts.first {
                ($0.changeAmount ?? $0.changePct ?? 0) < 0
            }
            if let pct = portfolioReview.dailyChangePct, pct > 0.01 {
                return positive.map { "组合收涨，\($0.name)是主要贡献" }
                    ?? "组合收涨，持仓表现总体偏强"
            }
            if let pct = portfolioReview.dailyChangePct, pct < -0.01 {
                return negative.map { "组合收跌，\($0.name)是主要拖累" }
                    ?? "组合收跌，需关注回撤来源"
            }
            return "组合当日涨跌有限，继续观察持仓分化"
        }
        return "收盘复盘已完成，暂无可用的组合涨跌"
    }

    private static func summary(
        pulse: [PulseItem],
        strongThemes: [ThemeItem],
        weakThemes: [ThemeItem],
        portfolioReview: PortfolioReview?
    ) -> String {
        if let market = pulse.first {
            return "\(market.name)\(market.direction.dashboardText)：\(market.rationale)"
        }
        if let strong = strongThemes.first {
            return "\(strong.name)\(strong.direction.dashboardText)：\(strong.rationale)"
        }
        if let weak = weakThemes.first {
            return "\(weak.name)\(weak.direction.dashboardText)：\(weak.rationale)"
        }
        if let impact = portfolioReview?.holdingImpacts.first,
           let analysis = impact.analysis?.nonEmpty {
            return "\(impact.name)：\(analysis)"
        }
        if let portfolioReview {
            return "已冻结 \(portfolioReview.holdingCount) 项持仓的收盘数据；归因信息不足的部分保留为待确认。"
        }
        return "收盘复盘已完成，但当时没有可用的组合持仓数据。"
    }

    private static func reviewEvidenceIDs(
        report: TrendAnalysisReport,
        marketWide: [TrendOpportunity],
        portfolioReview: PortfolioReview?
    ) -> [String] {
        let outlookIDs = report.marketOutlook.flatMap {
            $0.evidenceIDs + $0.claimEvidence.allEvidenceIDs
        }
        let opportunityIDs = marketWide.flatMap {
            $0.evidenceIDs + $0.claimEvidence.allEvidenceIDs
        }
        let portfolioIDs = portfolioReview?.holdingImpacts.flatMap(\.evidenceIDs) ?? []
        return unique(outlookIDs + opportunityIDs + portfolioIDs)
    }

    private enum CloseReviewCategory {
        case market
        case assetClass
        case sector

        var displayName: String {
            switch self {
            case .market: "大盘"
            case .assetClass: "大类资产"
            case .sector: "板块"
            }
        }
    }

    private static func closeReviewCategory(_ value: String) -> CloseReviewCategory? {
        switch normalized(value) {
        case "index", "market", "broadmarket", "大盘", "指数", "市场": .market
        case "assetclass", "资产大类", "大类资产": .assetClass
        case "sector", "industry", "theme", "板块", "行业", "主题": .sector
        default: nil
        }
    }

    private static func pulseSort(_ lhs: PulseItem, _ rhs: PulseItem) -> Bool {
        let lhsRank = lhs.category == "大盘" ? 0 : 1
        let rhsRank = rhs.category == "大盘" ? 0 : 1
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return confidenceScore(lhs.confidenceText) > confidenceScore(rhs.confidenceText)
    }

    private static func confidenceScore(_ text: String) -> Int {
        Int(text.filter(\.isNumber)) ?? 0
    }

    private static func deduplicate<T>(
        _ values: [T],
        key: (T) -> String
    ) -> [T] {
        var seen = Set<String>()
        return values.filter { seen.insert(key($0)).inserted }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            guard let trimmed = value.nonEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func day(from timestamp: String) -> String? {
        let trimmed = timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return nil }
        return String(trimmed.prefix(10))
    }

    private static func time(from timestamp: String) -> String {
        let trimmed = timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16 else { return "00:00" }
        return String(trimmed.dropFirst(11).prefix(5))
    }

}

private extension TrendDirection {
    var isCloseReviewPositive: Bool {
        self == .bullish || self == .neutralPositive
    }

    var isCloseReviewNegative: Bool {
        self == .bearish || self == .neutralNegative
    }
}

private extension TrendConfidence {
    var appText: String {
        "\(appNormalized.normalizedScore)%"
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension AppModel {
    var marketCloseReviewTitle: String {
        MarketCloseReviewArchive.displayTitle(
            generatedAt: marketCloseReviewArchive?.generatedAt
                ?? trendSettings.moduleGeneratedAt(.closeReview),
            currentTimestamp: Self.timestampString()
        )
    }

    var marketCloseReview: MarketCloseReviewSnapshot {
        let isUpdatingCloseReview = trendGenerationState == .generating
            && trendResearchRequestedScope == .closeReview
        if let marketCloseReviewArchive {
            return marketCloseReviewArchive.displaySnapshot(
                at: Self.timestampString(),
                isUpdating: isUpdatingCloseReview
            )
        }

        let closeReviewGeneratedAt = trendSettings.moduleGeneratedAt(.closeReview)
        let closeReviewDay = closeReviewGeneratedAt.map { String($0.prefix(10)) }
        let reportDay = trendReport.map { String($0.generatedAt.prefix(10)) }
        let portfolioSnapshotDay = userPortfolioSnapshot.map {
            String($0.refreshedAt.prefix(10))
        }
        // 兼容旧版本尚未生成独立复盘快照的情况：只有组合快照与收盘复盘属于
        // 同一天时才能合并。次日启动刷出的盘中数据不能冒充昨晚的收盘数据。
        let matchingPortfolioSnapshot = closeReviewDay == portfolioSnapshotDay
            ? userPortfolioSnapshot
            : nil
        // 共享趋势报告可能已经被次日市场雷达更新；没有独立归档时，也不能把
        // 今天的市场模块配上昨天的复盘时间。只有同日旧报告才允许兼容展示。
        let matchingReport = closeReviewDay != nil && closeReviewDay == reportDay
            ? trendReport
            : nil
        let closeReviewGenerationState: TrendGenerationState = if trendGenerationState == .generating,
                                                                  trendResearchRequestedScope == .closeReview {
            .generating
        } else {
            matchingReport == nil ? .idle : .succeeded
        }
        return MarketCloseReviewSnapshot.make(
            report: matchingReport,
            portfolioSnapshot: matchingPortfolioSnapshot,
            generationState: closeReviewGenerationState,
            currentTimestamp: Self.timestampString(),
            closeReviewGeneratedAt: closeReviewGeneratedAt
        )
    }
}
