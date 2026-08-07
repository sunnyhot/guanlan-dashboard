import Foundation

/// 全市场收盘复盘的纯派生模型。
///
/// 只消费全市场扫描中的大盘、大类资产和市场级板块结论；刻意不读取组合摘要、
/// 持仓板块、具体持仓或 DecisionCase，避免把“今日判断”做成另一个持仓页。
struct MarketCloseReviewSnapshot: Hashable {
    enum State: Hashable {
        case noScan
        case scanning
        case awaitingClose
        case ready
        case stale
    }

    struct PulseItem: Identifiable, Hashable {
        let id: String
        let name: String
        let category: String
        let direction: TrendDirection
        let confidenceText: String
        let rationale: String
    }

    struct ThemeItem: Identifiable, Hashable {
        let id: String
        let name: String
        let direction: TrendDirection
        let confidenceText: String
        let rationale: String
    }

    let state: State
    let subtitle: String
    let eyebrow: String
    let headline: String
    let summary: String
    let marketPulse: [PulseItem]
    let strongThemes: [ThemeItem]
    let weakThemes: [ThemeItem]
    let tomorrowWatch: [String]
    let evidenceText: String?
    let dataBoundary: String

    static func make(
        report: TrendAnalysisReport?,
        generationState: TrendGenerationState,
        currentTimestamp: String
    ) -> MarketCloseReviewSnapshot {
        if generationState == .generating {
            return baseSnapshot(
                state: .scanning,
                eyebrow: "扫描进行中",
                headline: "正在整理今天的市场收盘线索",
                summary: "行情、板块、跨资产和外部证据完成校验后，这里会生成全市场复盘。"
            )
        }

        guard let report else {
            return baseSnapshot(
                state: .noScan,
                eyebrow: "等待市场扫描",
                headline: "今天还没有可用的收盘复盘",
                summary: "完成一次全市场扫描后，这里只总结市场环境、强弱主线、风险和次日观察点。"
            )
        }

        let marketWide = report.opportunities.filter { $0.scope == .marketWide }
        guard !marketWide.isEmpty else {
            return baseSnapshot(
                state: .noScan,
                eyebrow: "需要重新扫描",
                headline: "这份旧报告没有全市场收盘结论",
                summary: "旧报告以组合为中心，不能拿来拼凑市场复盘。请重新扫描市场。"
            )
        }

        let reportDay = day(from: report.generatedAt)
        let currentDay = day(from: currentTimestamp)
        let isCurrentDay = reportDay != nil && reportDay == currentDay
        let beforeClose = isCurrentDay && time(from: currentTimestamp) < "15:00"
        let state: State = beforeClose ? .awaitingClose : (isCurrentDay ? .ready : .stale)

        let pulse = makeMarketPulse(report: report, marketWide: marketWide)
        let themes = makeThemes(marketWide)
        let strongThemes = themes.filter { $0.direction.isCloseReviewPositive }
        let weakThemes = themes.filter { $0.direction.isCloseReviewNegative }
        let watch = makeTomorrowWatch(report: report, marketWide: marketWide)
        let evidenceIDs = marketEvidenceIDs(report: report, marketWide: marketWide)
        let generatedText = String(report.generatedAt.prefix(16))

        return MarketCloseReviewSnapshot(
            state: state,
            subtitle: state == .stale ? "最近一次全市场扫描 · \(generatedText)" : "全市场扫描 · \(generatedText)",
            eyebrow: beforeClose ? "盘中观察" : (state == .stale ? "最近复盘" : "收盘复盘"),
            headline: headline(pulse: pulse, strongThemes: strongThemes, weakThemes: weakThemes),
            summary: summary(pulse: pulse, strongThemes: strongThemes, weakThemes: weakThemes),
            marketPulse: Array(pulse.prefix(4)),
            strongThemes: Array(strongThemes.prefix(3)),
            weakThemes: Array(weakThemes.prefix(3)),
            tomorrowWatch: Array(watch.prefix(3)),
            evidenceText: evidenceIDs.isEmpty
                ? "市场结论缺少可追溯证据，已降级为观察"
                : "复盘引用 \(evidenceIDs.count) 条去重证据",
            dataBoundary: beforeClose
                ? "当前仍在盘中，只展示扫描观察，不把盘中变化冒充收盘结论。"
                : "仅总结全市场扫描结果；不读取个人持仓、组合收益或决策事项。没有成交额、涨跌家数等数据时不会虚构。"
        )
    }

    private static func baseSnapshot(
        state: State,
        eyebrow: String,
        headline: String,
        summary: String
    ) -> MarketCloseReviewSnapshot {
        MarketCloseReviewSnapshot(
            state: state,
            subtitle: "市场环境、主线、风险与次日观察",
            eyebrow: eyebrow,
            headline: headline,
            summary: summary,
            marketPulse: [],
            strongThemes: [],
            weakThemes: [],
            tomorrowWatch: [],
            evidenceText: nil,
            dataBoundary: "这里不读取个人持仓、组合收益或决策事项。"
        )
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
        marketWide: [TrendOpportunity]
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
        weakThemes: [ThemeItem]
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
        return "本轮扫描没有形成清晰的市场主线"
    }

    private static func summary(
        pulse: [PulseItem],
        strongThemes: [ThemeItem],
        weakThemes: [ThemeItem]
    ) -> String {
        if let market = pulse.first {
            return clipped("\(market.name)\(market.direction.dashboardText)：\(market.rationale)")
        }
        if let strong = strongThemes.first {
            return clipped("\(strong.name)\(strong.direction.dashboardText)：\(strong.rationale)")
        }
        if let weak = weakThemes.first {
            return clipped("\(weak.name)\(weak.direction.dashboardText)：\(weak.rationale)")
        }
        return "扫描已完成，但没有达到证据门槛的市场级结论。"
    }

    private static func marketEvidenceIDs(
        report: TrendAnalysisReport,
        marketWide: [TrendOpportunity]
    ) -> [String] {
        let outlookIDs = report.marketOutlook.flatMap {
            $0.evidenceIDs + $0.claimEvidence.allEvidenceIDs
        }
        let opportunityIDs = marketWide.flatMap {
            $0.evidenceIDs + $0.claimEvidence.allEvidenceIDs
        }
        return unique(outlookIDs + opportunityIDs)
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

    private static func clipped(_ value: String, limit: Int = 180) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
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
    var marketCloseReview: MarketCloseReviewSnapshot {
        MarketCloseReviewSnapshot.make(
            report: trendReport,
            generationState: trendGenerationState,
            currentTimestamp: Self.timestampString()
        )
    }
}
