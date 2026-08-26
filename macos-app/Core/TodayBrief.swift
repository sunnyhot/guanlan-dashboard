import Foundation

enum TodayBriefKind: String, Hashable {
    case importPortfolio
    case pendingTrades
    case investmentPlan
    case dailyChange
    case largestMovement
    case platformAction
    case forumRecord
    case managerWatch
}

enum TodayBriefDestination: Hashable {
    case portfolio
    case platform
    case forum
    case settings
}

enum TodayBriefTone: Hashable {
    case brand
    case info
    case warning
    case danger
    case positive
    case muted
    case marketGain
    case marketLoss
}

struct TodayBriefItem: Identifiable, Hashable {
    let kind: TodayBriefKind
    let title: String
    let detail: String
    let metric: String
    let iconName: String
    let tone: TodayBriefTone
    let destination: TodayBriefDestination
    let priority: Int

    var id: TodayBriefKind { kind }
}

struct TodayBriefContext: Hashable {
    let hasPersonalPortfolio: Bool
    let pendingActionCount: Int
    let pendingCashAmount: Double
    let activePlanCount: Int
    let nextExecutionDate: String?
    let dailyChangeAmount: Double?
    let dailyChangePct: Double?
    let largestMovementName: String?
    let largestMovementAmount: Double?
    let largestMovementPct: Double?
    let latestPlatformTitle: String?
    let latestPlatformDate: String?
    let latestForumTitle: String?
    let latestForumDate: String?
    let managerWatchEnabled: Bool
    let managerWatchScopeText: String
    let managerWatchError: String?

    init(
        hasPersonalPortfolio: Bool,
        pendingActionCount: Int = 0,
        pendingCashAmount: Double = 0,
        activePlanCount: Int = 0,
        nextExecutionDate: String? = nil,
        dailyChangeAmount: Double? = nil,
        dailyChangePct: Double? = nil,
        largestMovementName: String? = nil,
        largestMovementAmount: Double? = nil,
        largestMovementPct: Double? = nil,
        latestPlatformTitle: String? = nil,
        latestPlatformDate: String? = nil,
        latestForumTitle: String? = nil,
        latestForumDate: String? = nil,
        managerWatchEnabled: Bool = false,
        managerWatchScopeText: String = "",
        managerWatchError: String? = nil,
        closeReviewAutoMissed: Bool = false
    ) {
        self.hasPersonalPortfolio = hasPersonalPortfolio
        self.pendingActionCount = pendingActionCount
        self.pendingCashAmount = pendingCashAmount
        self.activePlanCount = activePlanCount
        self.nextExecutionDate = nextExecutionDate
        self.dailyChangeAmount = dailyChangeAmount
        self.dailyChangePct = dailyChangePct
        self.largestMovementName = largestMovementName
        self.largestMovementAmount = largestMovementAmount
        self.largestMovementPct = largestMovementPct
        self.latestPlatformTitle = latestPlatformTitle
        self.latestPlatformDate = latestPlatformDate
        self.latestForumTitle = latestForumTitle
        self.latestForumDate = latestForumDate
        self.managerWatchEnabled = managerWatchEnabled
        self.managerWatchScopeText = managerWatchScopeText
        self.managerWatchError = managerWatchError
    }
}

enum TodayBriefBuilder {
    static func makeItems(context: TodayBriefContext, maxCount: Int = 4) -> [TodayBriefItem] {
        guard maxCount > 0 else { return [] }

        var items: [TodayBriefItem] = []

        if !context.hasPersonalPortfolio {
            items.append(
                TodayBriefItem(
                    kind: .importPortfolio,
                    title: "添加个人持仓",
                    detail: "录入后生成收益、交易和计划简报",
                    metric: "开始",
                    iconName: "square.and.arrow.down",
                    tone: .brand,
                    destination: .portfolio,
                    priority: 20
                )
            )
        }

        if let error = context.managerWatchError?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            items.append(
                TodayBriefItem(
                    kind: .managerWatch,
                    title: "巡检需要处理",
                    detail: error,
                    metric: "异常",
                    iconName: "bell.badge",
                    tone: .danger,
                    destination: .settings,
                    priority: 25
                )
            )
        }


        if context.pendingActionCount > 0 {
            items.append(
                TodayBriefItem(
                    kind: .pendingTrades,
                    title: "确认买入进度",
                    detail: "\(context.pendingActionCount) 笔交易进行中",
                    metric: currencyText(context.pendingCashAmount),
                    iconName: "clock.badge.exclamationmark",
                    tone: .warning,
                    destination: .portfolio,
                    priority: 30
                )
            )
        }

        if context.activePlanCount > 0 {
            let nextDate = context.nextExecutionDate?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail: String
            if let nextDate, !nextDate.isEmpty {
                detail = "\(context.activePlanCount) 个进行中计划 · 下次 \(nextDate)"
            } else {
                detail = "\(context.activePlanCount) 个进行中计划"
            }
            items.append(
                TodayBriefItem(
                    kind: .investmentPlan,
                    title: "查看下次定投",
                    detail: detail,
                    metric: "\(context.activePlanCount) 项",
                    iconName: "calendar.badge.clock",
                    tone: .info,
                    destination: .portfolio,
                    priority: 40
                )
            )
        }

        if let change = context.dailyChangeAmount {
            let pctText = percentOptional(context.dailyChangePct)
            items.append(
                TodayBriefItem(
                    kind: .dailyChange,
                    title: change >= 0 ? "今日收益扩大" : "今日回撤提醒",
                    detail: "组合今日涨跌 \(pctText)",
                    metric: signedCurrencyText(change),
                    iconName: "waveform.path.ecg",
                    tone: change >= 0 ? .marketGain : .marketLoss,
                    destination: .portfolio,
                    priority: 50
                )
            )
        }

        if let name = context.largestMovementName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty,
           let amount = context.largestMovementAmount {
            items.append(
                TodayBriefItem(
                    kind: .largestMovement,
                    title: "波动最大标的",
                    detail: "\(name) · \(percentOptional(context.largestMovementPct))",
                    metric: signedCurrencyText(amount),
                    iconName: "arrow.up.and.down",
                    tone: amount >= 0 ? .marketGain : .marketLoss,
                    destination: .portfolio,
                    priority: 60
                )
            )
        }

        if let title = context.latestPlatformTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            let date = context.latestPlatformDate?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail: String
            if let date, !date.isEmpty {
                detail = "\(title) · \(date)"
            } else {
                detail = title
            }
            items.append(
                TodayBriefItem(
                    kind: .platformAction,
                    title: "主理人最近调仓",
                    detail: detail,
                    metric: "调仓",
                    iconName: "arrow.left.arrow.right",
                    tone: .brand,
                    destination: .platform,
                    priority: 70
                )
            )
        }

        if let title = context.latestForumTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            let date = context.latestForumDate?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail: String
            if let date, !date.isEmpty {
                detail = "\(title) · \(date)"
            } else {
                detail = title
            }
            items.append(
                TodayBriefItem(
                    kind: .forumRecord,
                    title: "主理人最新发言",
                    detail: detail,
                    metric: "发言",
                    iconName: "text.bubble",
                    tone: .info,
                    destination: .forum,
                    priority: 80
                )
            )
        }

        if items.isEmpty, context.managerWatchEnabled {
            items.append(
                TodayBriefItem(
                    kind: .managerWatch,
                    title: "巡检运行中",
                    detail: context.managerWatchScopeText,
                    metric: "已开",
                    iconName: "bell.and.waves.left.and.right",
                    tone: .positive,
                    destination: .settings,
                    priority: 90
                )
            )
        }

        return items
            .sorted { left, right in
                if left.priority != right.priority {
                    return left.priority < right.priority
                }
                return left.title.localizedStandardCompare(right.title) == .orderedAscending
            }
            .prefix(maxCount)
            .map { $0 }
    }
}

extension AppModel {
    var todayBriefItems: [TodayBriefItem] {
        TodayBriefBuilder.makeItems(context: todayBriefContext)
    }

    private var todayBriefContext: TodayBriefContext {
        let pendingSummary = pendingTradeSummary
        let planSummary = investmentPlanSummary
        let largestMovement = personalAssetRows
            .compactMap { row -> PersonalAssetAggregateRow? in
                guard let amount = row.estimateChangeAmount, abs(amount) > 0.001 else { return nil }
                return row
            }
            .max { left, right in
                abs(left.estimateChangeAmount ?? 0) < abs(right.estimateChangeAmount ?? 0)
            }
        let latestPlatform = latestPlatformActions.first
        let latestForum = hasForumPosts ? forumRecords.first : nil

        return TodayBriefContext(
            hasPersonalPortfolio: hasPersonalPortfolio || personalAssetSummary != nil,
            pendingActionCount: pendingSummary?.actionCount ?? 0,
            pendingCashAmount: pendingSummary?.totalCashAmount ?? 0,
            activePlanCount: planSummary?.activePlanCount ?? 0,
            nextExecutionDate: planSummary?.nextExecutionDate,
            dailyChangeAmount: userPortfolioSnapshot?.dailyChangeSummary.amount,
            dailyChangePct: userPortfolioSnapshot?.dailyChangeSummary.pct,
            largestMovementName: largestMovement?.fundName,
            largestMovementAmount: largestMovement?.estimateChangeAmount,
            largestMovementPct: largestMovement?.estimateChangePct,
            latestPlatformTitle: latestPlatform?.displayTitle,
            latestPlatformDate: latestPlatform?.txnDate ?? latestPlatform?.createdAt,
            latestForumTitle: latestForum?.titleText,
            latestForumDate: latestForum?.createdAt,
            managerWatchEnabled: managerWatchSettings.isEnabled,
            managerWatchScopeText: managerWatchScopeText,
            managerWatchError: managerWatchSettings.lastErrorMessage
        )
    }
}
