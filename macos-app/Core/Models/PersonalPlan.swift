import Foundation

struct PersonalInvestmentPlan: Codable, Hashable, Identifiable {
    let id: UUID
    let planTypeLabel: String
    let fundName: String
    let fundCode: String?
    let scheduleText: String
    let amountText: String
    let minAmount: Double?
    let maxAmount: Double?
    let investedPeriods: Int?
    let cumulativeInvestedAmount: Double?
    let paymentMethod: String?
    let nextExecutionDate: String
    let status: String
    let note: String?

    init(
        id: UUID = UUID(),
        planTypeLabel: String,
        fundName: String,
        fundCode: String? = nil,
        scheduleText: String,
        amountText: String,
        minAmount: Double? = nil,
        maxAmount: Double? = nil,
        investedPeriods: Int? = nil,
        cumulativeInvestedAmount: Double? = nil,
        paymentMethod: String? = nil,
        nextExecutionDate: String,
        status: String,
        note: String? = nil
    ) {
        self.id = id
        self.planTypeLabel = planTypeLabel
        self.fundName = fundName
        self.fundCode = fundCode
        self.scheduleText = scheduleText
        self.amountText = amountText
        self.minAmount = minAmount
        self.maxAmount = maxAmount
        self.investedPeriods = investedPeriods
        self.cumulativeInvestedAmount = cumulativeInvestedAmount
        self.paymentMethod = paymentMethod
        self.nextExecutionDate = nextExecutionDate
        self.status = status
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case id
        case planTypeLabel
        case fundName
        case fundCode
        case scheduleText
        case amountText
        case minAmount
        case maxAmount
        case investedPeriods
        case cumulativeInvestedAmount
        case paymentMethod
        case nextExecutionDate
        case status
        case note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.planTypeLabel = try container.decodeIfPresent(String.self, forKey: .planTypeLabel) ?? ""
        self.fundName = try container.decodeIfPresent(String.self, forKey: .fundName) ?? ""
        self.fundCode = try container.decodeIfPresent(String.self, forKey: .fundCode)
        self.scheduleText = try container.decodeIfPresent(String.self, forKey: .scheduleText) ?? ""
        self.amountText = try container.decodeIfPresent(String.self, forKey: .amountText) ?? ""
        self.minAmount = try container.decodeIfPresent(Double.self, forKey: .minAmount)
        self.maxAmount = try container.decodeIfPresent(Double.self, forKey: .maxAmount)
        self.investedPeriods = try container.decodeIfPresent(Int.self, forKey: .investedPeriods)
        self.cumulativeInvestedAmount = try container.decodeIfPresent(Double.self, forKey: .cumulativeInvestedAmount)
        self.paymentMethod = try container.decodeIfPresent(String.self, forKey: .paymentMethod)
        self.nextExecutionDate = try container.decodeIfPresent(String.self, forKey: .nextExecutionDate) ?? ""
        self.status = try container.decodeIfPresent(String.self, forKey: .status) ?? "进行中"
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    var isSmartPlan: Bool {
        planTypeLabel.contains("智能")
    }

    var isDrawdownMode: Bool {
        scheduleText.contains("涨跌幅")
    }

    var normalizedStatus: String {
        if status.contains("终止") {
            return "已终止"
        }
        if status.contains("暂停") {
            return "已暂停"
        }
        return "进行中"
    }

    var isActivePlan: Bool {
        normalizedStatus == "进行中"
    }

    var isPausedPlan: Bool {
        normalizedStatus == "已暂停"
    }

    var isEndedPlan: Bool {
        normalizedStatus == "已终止"
    }

    var isDailyPlan: Bool {
        scheduleText.contains("每日")
    }

    var isWeeklyPlan: Bool {
        scheduleText.contains("每周")
    }

    var amountRangeText: String {
        amountText
    }

    var normalizedAmountBounds: (min: Double?, max: Double?) {
        let parsed = Self.parsedAmountRange(from: amountText)
        let minValue = minAmount ?? parsed.min
        let maxValue = maxAmount ?? parsed.max
        switch (minValue, maxValue) {
        case let (min?, max?) where max < min:
            return (max, min)
        case let (min?, max?):
            return (min, max)
        case let (min?, nil):
            return (min, min)
        case let (nil, max?):
            return (max, max)
        default:
            return (nil, nil)
        }
    }

    var alipayBaseAmount: Double? {
        let bounds = normalizedAmountBounds
        switch (bounds.min, bounds.max) {
        case let (min?, max?) where abs(max - min) < 0.001:
            return min
        case let (min?, max?):
            let baseFromMax = max / 2
            if abs(min - baseFromMax * 0.5) <= Swift.max(0.01, baseFromMax * 0.01) {
                return baseFromMax
            }
            return (min + max) / 2
        case let (min?, nil):
            return min
        case let (nil, max?):
            return max
        default:
            return nil
        }
    }

    func estimatedExecutionAmount(costDeviationPct: Double?) -> Double {
        let bounds = normalizedAmountBounds
        guard let low = bounds.min else { return 0 }
        let high = bounds.max ?? low

        if !isDrawdownMode {
            if abs(high - low) < 0.001 {
                return low
            }
            return (low + high) / 2
        }

        guard let base = alipayBaseAmount else {
            return abs(high - low) < 0.001 ? low : (low + high) / 2
        }
        guard let costDeviationPct else {
            return clamped(base, min: low, max: high)
        }
        let multiplier = Self.alipayDrawdownMultiplier(for: costDeviationPct)
        return clamped(base * multiplier, min: low, max: high)
    }

    static func drawdownCostDeviationPct(currentPrice: Double?, costPrice: Double?) -> Double? {
        guard let currentPrice, let costPrice, costPrice > 0 else {
            return nil
        }
        return ((currentPrice - costPrice) / costPrice) * 100
    }

    static func alipayDrawdownMultiplier(for costDeviationPct: Double) -> Double {
        if costDeviationPct < 0 {
            return min(2.0, 1 + abs(costDeviationPct) * 0.08)
        }
        if costDeviationPct > 0 {
            return max(0.5, 1 - costDeviationPct * 0.04)
        }
        return 1
    }

    private func clamped(_ value: Double, min minValue: Double, max maxValue: Double) -> Double {
        Swift.min(Swift.max(value, minValue), maxValue)
    }

    private static func parsedAmountRange(from text: String) -> (min: Double?, max: Double?) {
        let cleaned = text
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: "元", with: "")
            .replacingOccurrences(of: "～", with: "~")
            .replacingOccurrences(of: "—", with: "~")
            .replacingOccurrences(of: "－", with: "~")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let numbers = cleaned
            .split { !"0123456789.".contains($0) }
            .compactMap { Double($0) }
        guard let first = numbers.first else {
            return (nil, nil)
        }
        if numbers.count >= 2, let second = numbers.dropFirst().first {
            return (first, second)
        }
        return (first, first)
    }
}

struct PersonalInvestmentPlanSummary: Hashable {
    let planCount: Int
    let activePlanCount: Int
    let pausedPlanCount: Int
    let endedPlanCount: Int
    let smartPlanCount: Int
    let dailyPlanCount: Int
    let weeklyPlanCount: Int
    let totalCumulativeInvestedAmount: Double
    let nextExecutionDate: String?
}

struct PersonalAssetAggregateRow: Identifiable, Hashable {
    let key: String
    let assetType: PersonalAssetType
    let fundName: String
    let fundCode: String?
    let holdingRow: UserPortfolioValuationRow?
    let rawHolding: UserPortfolioHolding?
    let archivedHolding: UserPortfolioHolding?
    let pendingTrades: [PersonalPendingTrade]
    let plans: [PersonalInvestmentPlan]
    let pendingCashAmount: Double
    let pendingUnitAmount: Double
    let activePlanCount: Int
    let pausedPlanCount: Int
    let endedPlanCount: Int
    let drawdownPlanCount: Int
    let totalCumulativePlanAmount: Double
    let estimatedNextPlanAmount: Double
    let nextExecutionDate: String?

    init(
        key: String,
        assetType: PersonalAssetType,
        fundName: String,
        fundCode: String?,
        holdingRow: UserPortfolioValuationRow?,
        rawHolding: UserPortfolioHolding?,
        archivedHolding: UserPortfolioHolding?,
        pendingTrades: [PersonalPendingTrade],
        plans: [PersonalInvestmentPlan]
    ) {
        self.key = key
        self.assetType = assetType
        self.fundName = fundName
        self.fundCode = fundCode
        self.holdingRow = holdingRow
        self.rawHolding = rawHolding
        self.archivedHolding = archivedHolding
        self.pendingTrades = pendingTrades
        self.plans = plans

        var pendingCashTotal = 0.0
        var pendingUnitTotal = 0.0
        for trade in pendingTrades {
            pendingCashTotal += trade.amountValue ?? 0
            pendingUnitTotal += trade.unitValue ?? 0
        }

        let drawdownDeviationPct = Self.drawdownCostDeviationPct(
            currentPrice: holdingRow?.resolvedPrice,
            costPrice: holdingRow?.holding.costPrice ?? rawHolding?.costPrice ?? archivedHolding?.costPrice
        )

        var activeCount = 0
        var pausedCount = 0
        var endedCount = 0
        var drawdownCount = 0
        var cumulativeAmount = 0.0
        var nextPlanAmount = 0.0
        var earliestExecutionDate: String?

        for plan in plans {
            switch plan.normalizedStatus {
            case "进行中":
                activeCount += 1
                nextPlanAmount += plan.estimatedExecutionAmount(costDeviationPct: drawdownDeviationPct)
                let executionDate = plan.nextExecutionDate.trimmingCharacters(in: .whitespacesAndNewlines)
                if !executionDate.isEmpty,
                   earliestExecutionDate == nil || executionDate < earliestExecutionDate! {
                    earliestExecutionDate = executionDate
                }
            case "已暂停":
                pausedCount += 1
            case "已终止":
                endedCount += 1
            default:
                endedCount += 1
            }
            if plan.isDrawdownMode {
                drawdownCount += 1
            }
            cumulativeAmount += plan.cumulativeInvestedAmount ?? 0
        }

        pendingCashAmount = pendingCashTotal
        pendingUnitAmount = pendingUnitTotal
        activePlanCount = activeCount
        pausedPlanCount = pausedCount
        endedPlanCount = endedCount
        drawdownPlanCount = drawdownCount
        totalCumulativePlanAmount = cumulativeAmount
        estimatedNextPlanAmount = nextPlanAmount
        nextExecutionDate = earliestExecutionDate
    }

    var id: String { key }

    var assetTypeLabel: String {
        assetType.displayName
    }

    var detectedMarket: StockMarket? {
        rawHolding?.detectedMarket ?? holdingRow?.holding.detectedMarket ?? archivedHolding?.detectedMarket
    }

    var detectedFundMarket: FundMarket? {
        rawHolding?.detectedFundMarket
            ?? holdingRow?.holding.detectedFundMarket
            ?? archivedHolding?.detectedFundMarket
            ?? fundCode.map(UserPortfolioHolding.detectFundMarket)
    }

    var isOnExchangeFund: Bool {
        assetType == .fund && detectedFundMarket == .onExchange
    }

    var usesMarketTradeColumns: Bool {
        assetType == .stock || isOnExchangeFund
    }

    var marketValue: Double? {
        holdingRow?.marketValue
    }

    var holdingUnits: Double? {
        holdingRow?.holding.units ?? rawHolding?.units
    }

    var archivedUnits: Double? {
        archivedHolding?.units
    }

    var currentPrice: Double? {
        holdingRow?.resolvedPrice
    }

    var currentEstimatePrice: Double? {
        holdingRow?.estimatePrice
    }

    var currentEstimateMarketValue: Double? {
        holdingRow?.estimatedMarketValue
    }

    var costPrice: Double? {
        holdingRow?.holding.costPrice ?? rawHolding?.costPrice ?? archivedHolding?.costPrice
    }

    var profitAmount: Double? {
        holdingRow?.profitAmount
    }

    var profitPct: Double? {
        holdingRow?.profitPct
    }

    var estimateChangePct: Double? {
        holdingRow?.estimateChangePct
    }

    var estimateChangeAmount: Double? {
        holdingRow?.estimatedDailyChangeAmount
    }

    var changePeriodTitle: String {
        holdingRow?.changePeriodTitle ?? "今日涨跌"
    }

    var pendingTradeCount: Int {
        pendingTrades.count
    }

    var totalPlanCount: Int {
        plans.count
    }

    var hasDrawdownPlan: Bool {
        drawdownPlanCount > 0
    }

    var effectiveHoldingAmount: Double {
        (marketValue ?? 0) + pendingCashAmount + estimatedNextPlanAmount
    }

    var hasHolding: Bool {
        marketValue != nil || holdingUnits != nil
    }

    var hasArchivedHolding: Bool {
        archivedHolding != nil
    }

    var hasPending: Bool {
        pendingTradeCount > 0
    }

    var hasPlans: Bool {
        totalPlanCount > 0
    }

    var combinedStatusText: String {
        var parts: [String] = []
        if hasHolding {
            parts.append("已持有")
        } else if hasArchivedHolding {
            parts.append("已归档")
        }
        if hasPending {
            parts.append("待确认")
        }
        if hasPlans {
            parts.append("计划中")
        }
        return parts.isEmpty ? "未归类" : parts.joined(separator: " + ")
    }

    private static func drawdownCostDeviationPct(currentPrice: Double?, costPrice: Double?) -> Double? {
        PersonalInvestmentPlan.drawdownCostDeviationPct(currentPrice: currentPrice, costPrice: costPrice)
    }
}

struct PersonalAssetAggregateSummary: Hashable {
    let fundCount: Int
    let holdingFundCount: Int
    let pendingFundCount: Int
    let activePlanFundCount: Int
    let totalMarketValue: Double
    let totalPendingCashAmount: Double
    let totalActivePlanCount: Int
    let totalPausedPlanCount: Int
    let totalEndedPlanCount: Int
    let totalCumulativePlanAmount: Double
    let totalEstimatedNextPlanAmount: Double
    let totalEffectiveHoldingAmount: Double
}
