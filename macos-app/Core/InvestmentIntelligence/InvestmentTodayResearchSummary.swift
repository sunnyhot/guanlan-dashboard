import Foundation

/// 「今日研判」摘要卡的行派生:四条 AI 链路各压缩成一行。
/// 纯函数,View 不做业务计算;iOS 端可复用同一规则。
struct InvestmentTodayResearchRow: Hashable, Sendable, Identifiable {
    enum Kind: String, Hashable, Sendable {
        case closeReview
        case intraday
        case marketRadar
        case longTerm
    }

    let kind: Kind
    let title: String
    let headline: String
    let footnote: String

    var id: String { kind.rawValue }
}

struct InvestmentTodayResearchSummary: Hashable, Sendable {
    let rows: [InvestmentTodayResearchRow]

    var hasAnyContent: Bool { !rows.isEmpty }

    static func make(
        closeReview: MarketCloseReviewSnapshot,
        closeReviewTitle: String,
        intraday: NextHourGuidanceReport?,
        marketAnalysis: MarketOpportunityAnalysis?,
        trendReport: TrendAnalysisReport?,
        currentTimestamp: String
    ) -> InvestmentTodayResearchSummary {
        var rows: [InvestmentTodayResearchRow] = []

        // 复盘:占位态不算内容——noScan/scanning 的 headline 是提示文案而非结论。
        if closeReview.state != .noScan && closeReview.state != .scanning {
            let footnote = closeReview.tomorrowWatch.first
                ?? closeReview.portfolioReview.map { "持仓 \($0.holdingImpacts.count) 项" }
                ?? ""
            rows.append(
                InvestmentTodayResearchRow(
                    kind: .closeReview,
                    title: closeReviewTitle,
                    headline: closeReview.headline,
                    footnote: footnote
                )
            )
        }

        if let intraday {
            let headline: String
            if let first = intraday.actions.first {
                headline = "\(intraday.posture.displayName) · \(first.targetName) \(first.action.displayName)"
            } else {
                headline = "\(intraday.posture.displayName) · \(intraday.headline)"
            }
            rows.append(
                InvestmentTodayResearchRow(
                    kind: .intraday,
                    title: "盘中指引",
                    headline: headline,
                    footnote: Self.isIntradayExpired(
                        validUntil: intraday.validUntil,
                        currentTimestamp: currentTimestamp
                    )
                        ? "已过期"
                        : "有效至 \(Self.shortTimeText(intraday.validUntil))"
                )
            )
        }

        if let marketAnalysis,
           marketAnalysis.marketSignalCount > 0,
           let top = Self.topSignal(marketAnalysis) {
            rows.append(
                InvestmentTodayResearchRow(
                    kind: .marketRadar,
                    title: "全市场机会",
                    headline: "\(top.name) · \(top.recommendation.displayName)",
                    footnote: "共 \(marketAnalysis.marketSignalCount) 个方向 · 更新 \(Self.shortTimeText(marketAnalysis.generatedAt))"
                )
            )
        }

        if let trendReport,
           let medium = trendReport.horizons.first(where: { $0.horizon == .medium }) {
            rows.append(
                InvestmentTodayResearchRow(
                    kind: .longTerm,
                    title: "组合中期",
                    headline: "\(medium.direction.assetTagText) · \(medium.rationale)",
                    footnote: "生成于 \(String(trendReport.generatedAt.prefix(10)))"
                )
            )
        }

        return InvestmentTodayResearchSummary(rows: rows)
    }

    /// 最强方向:建议优先级升序,同级按把握分降序。
    static func topSignal(_ analysis: MarketOpportunityAnalysis) -> InvestmentDirectionSignal? {
        (analysis.assetClasses + analysis.markets + analysis.marketSectorOpportunities)
            .min { lhs, rhs in
                if lhs.recommendation.priority != rhs.recommendation.priority {
                    return lhs.recommendation.priority < rhs.recommendation.priority
                }
                return lhs.confidence.normalizedScore > rhs.confidence.normalizedScore
            }
    }

    /// validUntil 有两种格式:固定时段槽为 "HH:mm",手动槽为 "yyyy-MM-dd HH:mm"。
    /// 统一折算成当日分钟数比较;到达有效时刻即视为过期。
    static func isIntradayExpired(validUntil: String, currentTimestamp: String) -> Bool {
        let trimmed = validUntil.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentMinute = minuteOfDay(fromTimestamp: currentTimestamp) ?? 0
        if trimmed.contains("-") {
            let day = String(trimmed.prefix(10))
            let currentDay = String(currentTimestamp.prefix(10))
            if day != currentDay {
                return day < currentDay
            }
            return (minuteOfDay(fromText: String(trimmed.dropFirst(11).prefix(5))) ?? 0) <= currentMinute
        }
        return (minuteOfDay(fromText: String(trimmed.suffix(5))) ?? 0) <= currentMinute
    }

    private static func minuteOfDay(fromTimestamp timestamp: String) -> Int? {
        let trimmed = timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16 else { return nil }
        return minuteOfDay(fromText: String(trimmed.dropFirst(11).prefix(5)))
    }

    /// "yyyy-MM-dd HH:mm[:ss]" 取 "HH:mm";"HH:mm" 原样返回。
    private static func shortTimeText(_ timestamp: String) -> String {
        let trimmed = timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16 else { return trimmed }
        return String(trimmed.dropFirst(11).prefix(5))
    }

    private static func minuteOfDay(fromText text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return nil
        }
        return hour * 60 + minute
    }
}

extension AppModel {
    /// 「今日研判」摘要卡数据:四链路各一行的纯派生,不缓存,输入全为已发布状态。
    var investmentTodayResearchSummary: InvestmentTodayResearchSummary {
        InvestmentTodayResearchSummary.make(
            closeReview: marketCloseReview,
            closeReviewTitle: marketCloseReviewTitle,
            intraday: nextHourGuidanceReport,
            marketAnalysis: marketOpportunities,
            trendReport: trendReport,
            currentTimestamp: Self.timestampString()
        )
    }

    /// 「全市场机会」分析的唯一入口(带 memo,原 P4.9 并入 P1):
    /// 面板与摘要卡共用,输入(report id/generatedAt + 雷达模块时间)未变时复用上次结果。
    var marketOpportunities: MarketOpportunityAnalysis? {
        let generatedAt = trendSettings.moduleGeneratedAt(.marketRadar)
        let key = [
            trendReport?.id.uuidString ?? "-",
            trendReport?.generatedAt ?? "-",
            generatedAt ?? "-"
        ].joined(separator: "|")
        // key 与 value 总是成对写入:key 命中即返回缓存值(含 nil——
        // 无报告/无机会的结果同样要缓存,否则每次渲染都重算)。
        if key == enhancementState.marketOpportunityMemoKey {
            enhancementState.marketOpportunityMemoHitCount += 1
            return enhancementState.marketOpportunityMemoValue
        }
        let value = MarketOpportunityEngine.analyze(report: trendReport, generatedAt: generatedAt)
        enhancementState.marketOpportunityMemoKey = key
        enhancementState.marketOpportunityMemoValue = value
        return value
    }

    var marketOpportunityMemoHitCount: Int {
        enhancementState.marketOpportunityMemoHitCount
    }
}


// MARK: - AI 研判 Tab ↔ 研判区段锚点联动（2026-09-02）

extension AIResearchTab {
    /// 通知深链锚点 → Tab 联动：目标区段在未选中的 Tab 里时先切换再滚动。
    static func tab(for anchor: InvestmentTodayResearchRow.Kind) -> AIResearchTab? {
        switch anchor {
        case .intraday: return .intraday
        case .closeReview: return .closeReview
        case .longTerm: return .longTerm
        case .marketRadar: return nil
        }
    }
}
