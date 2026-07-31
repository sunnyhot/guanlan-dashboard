import Foundation

// MARK: - Asset Aggregation & Platform Summary

extension AppModel {
    var nativeClient: QiemanNativeClient {
        if !_nativeClientInitialized {
            _nativeClient = QiemanNativeClient()
            _nativeClientInitialized = true
        }
        return _nativeClient!
    }

    var monthlyPlatformSummary: [PlatformMonthSummary] {
        if let cached = _cachedMonthlyPlatformSummary { return cached }
        let actions = platformPayload?.actions ?? []
        var buckets: [String: (buy: Int, sell: Int, days: Set<String>)] = [:]

        for action in actions {
            let rawDate = action.txnDate ?? action.createdAt ?? ""
            guard rawDate.count >= 10 else { continue }
            guard let direction = platformActionDirection(action) else { continue }
            let month = String(rawDate.prefix(7))
            guard monthIndex(month) != nil else { continue }
            let day = String(rawDate.prefix(10))
            var bucket = buckets[month] ?? (0, 0, [])
            if direction == .buy {
                bucket.buy += 1
            } else {
                bucket.sell += 1
            }
            bucket.days.insert(day)
            buckets[month] = bucket
        }

        let monthIndices = buckets.keys.compactMap(monthIndex)
        guard let firstMonthIndex = monthIndices.min(),
              let latestMonthIndex = monthIndices.max() else {
            _cachedMonthlyPlatformSummary = []
            return []
        }

        let result = (firstMonthIndex...latestMonthIndex).compactMap { index -> PlatformMonthSummary? in
            guard let month = monthKey(from: index) else { return nil }
            let bucket = buckets[month] ?? (0, 0, [])
            return PlatformMonthSummary(
                month: month,
                totalCount: bucket.buy + bucket.sell,
                buyCount: bucket.buy,
                sellCount: bucket.sell,
                activeDays: bucket.days.count
            )
        }
        _cachedMonthlyPlatformSummary = result
        return result
    }

    func monthIndex(_ month: String) -> Int? {
        let parts = month.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]),
              let monthNumber = Int(parts[1]),
              (1...12).contains(monthNumber) else {
            return nil
        }
        return year * 12 + (monthNumber - 1)
    }

    func monthKey(from index: Int) -> String? {
        guard index >= 0 else { return nil }
        let year = index / 12
        let month = index % 12 + 1
        return String(format: "%04d-%02d", year, month)
    }

    enum PlatformActionDirection {
        case buy
        case sell
    }

    func platformActionDirection(_ action: PlatformActionPayload) -> PlatformActionDirection? {
        let candidates = [
            action.side,
            action.action,
            action.actionTitle,
            action.title,
        ]
        for candidate in candidates {
            let value = candidate?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            guard !value.isEmpty else { continue }
            if value == "buy" || value.contains("买") || value.contains("申购") {
                return .buy
            }
            if value == "sell" || value.contains("卖") || value.contains("赎回") {
                return .sell
            }
        }
        return nil
    }

    var pendingTradeSummary: PersonalPendingTradeSummary? {
        if let cached = _cachedPendingTradeSummary { return cached }
        guard !pendingTrades.isEmpty else { _cachedPendingTradeSummary = nil; return nil }
        var totalCashAmount = 0.0
        var cashTradeCount = 0
        var unitTradeCount = 0

        for trade in pendingTrades {
            totalCashAmount += trade.amountValue ?? 0
            if trade.isCashTrade {
                cashTradeCount += 1
            } else {
                unitTradeCount += 1
            }
        }

        let result = PersonalPendingTradeSummary(
            totalCashAmount: totalCashAmount,
            cashTradeCount: cashTradeCount,
            unitTradeCount: unitTradeCount,
            latestTime: pendingTrades.first?.occurredAt,
            actionCount: pendingTrades.count
        )
        _cachedPendingTradeSummary = result
        return result
    }

    var activeInvestmentPlans: [PersonalInvestmentPlan] {
        if let cached = _cachedActiveInvestmentPlans { return cached }
        let result = investmentPlans
            .filter(\.isActivePlan)
            .sorted(by: sortInvestmentPlans)
        _cachedActiveInvestmentPlans = result
        return result
    }

    var pausedInvestmentPlans: [PersonalInvestmentPlan] {
        if let cached = _cachedPausedInvestmentPlans { return cached }
        let result = investmentPlans
            .filter(\.isPausedPlan)
            .sorted(by: sortInvestmentPlans)
        _cachedPausedInvestmentPlans = result
        return result
    }

    var endedInvestmentPlans: [PersonalInvestmentPlan] {
        if let cached = _cachedEndedInvestmentPlans { return cached }
        let result = investmentPlans
            .filter(\.isEndedPlan)
            .sorted(by: sortInvestmentPlans)
        _cachedEndedInvestmentPlans = result
        return result
    }

    var investmentPlanSummary: PersonalInvestmentPlanSummary? {
        if let cached = _cachedInvestmentPlanSummary { return cached }
        guard !investmentPlans.isEmpty else { _cachedInvestmentPlanSummary = nil; return nil }
        let activePlans = activeInvestmentPlans
        let pausedPlans = pausedInvestmentPlans
        let endedPlans = endedInvestmentPlans
        var totalCumulativeInvestedAmount = 0.0
        for plan in investmentPlans {
            totalCumulativeInvestedAmount += plan.cumulativeInvestedAmount ?? 0
        }

        var smartPlanCount = 0
        var dailyPlanCount = 0
        var weeklyPlanCount = 0
        var nextExecutionDate: String?
        for plan in activePlans {
            if plan.isSmartPlan { smartPlanCount += 1 }
            if plan.isDailyPlan { dailyPlanCount += 1 }
            if plan.isWeeklyPlan { weeklyPlanCount += 1 }
            let candidate = plan.nextExecutionDate
            if !candidate.isEmpty, nextExecutionDate.map({ candidate < $0 }) ?? true {
                nextExecutionDate = candidate
            }
        }

        let result = PersonalInvestmentPlanSummary(
            planCount: investmentPlans.count,
            activePlanCount: activePlans.count,
            pausedPlanCount: pausedPlans.count,
            endedPlanCount: endedPlans.count,
            smartPlanCount: smartPlanCount,
            dailyPlanCount: dailyPlanCount,
            weeklyPlanCount: weeklyPlanCount,
            totalCumulativeInvestedAmount: totalCumulativeInvestedAmount,
            nextExecutionDate: nextExecutionDate
        )
        _cachedInvestmentPlanSummary = result
        return result
    }

    /// Explicitly rebuilds personalAssetRows and personalAssetSummary from current data.
    /// Call this after any change to holdings, snapshot, pendingTrades, or investmentPlans.
    func rebuildAssetRows() {
        var keys = Set<String>()
        var valuationRowsByKey: [String: UserPortfolioValuationRow] = [:]
        for row in userPortfolioSnapshot?.rows ?? [] {
            let key = personalAssetKey(assetType: row.holding.assetType, code: row.holding.normalizedFundCode, name: row.fundName, market: row.holding.detectedMarket, fundMarket: row.holding.detectedFundMarket)
            valuationRowsByKey[key] = row
            keys.insert(key)
        }

        var rawHoldingsByKey: [String: UserPortfolioHolding] = [:]
        var archivedHoldingsByKey: [String: UserPortfolioHolding] = [:]
        for holding in userPortfolioHoldings {
            let key = personalAssetKey(assetType: holding.assetType, code: holding.normalizedFundCode, name: holding.normalizedName, market: holding.detectedMarket, fundMarket: holding.detectedFundMarket)
            if holding.isArchived {
                archivedHoldingsByKey[key] = archivedHoldingsByKey[key] ?? holding
            } else {
                rawHoldingsByKey[key] = rawHoldingsByKey[key] ?? holding
            }
            keys.insert(key)
        }

        var pendingByKey: [String: [PersonalPendingTrade]] = [:]
        for trade in pendingTrades {
            let key = personalFundKey(code: trade.fundCode, name: trade.fundName)
            pendingByKey[key, default: []].append(trade)
            keys.insert(key)
        }

        var plansByKey: [String: [PersonalInvestmentPlan]] = [:]
        for plan in investmentPlans {
            let key = personalFundKey(code: plan.fundCode, name: plan.fundName)
            plansByKey[key, default: []].append(plan)
            keys.insert(key)
        }

        let rows = keys
            .map { key in
                let holdingRow = valuationRowsByKey[key]
                let rawHolding = rawHoldingsByKey[key]
                let archivedHolding = archivedHoldingsByKey[key]
                let pending = (pendingByKey[key] ?? []).sorted { $0.occurredAt > $1.occurredAt }
                let plans = (plansByKey[key] ?? []).sorted(by: sortInvestmentPlans)
                let assetType = holdingRow?.holding.assetType
                    ?? rawHolding?.assetType
                    ?? archivedHolding?.assetType
                    ?? .fund
                let fundName = holdingRow?.fundName
                    ?? rawHolding?.normalizedName
                    ?? archivedHolding?.normalizedName
                    ?? pending.first?.fundName
                    ?? plans.first?.fundName
                    ?? "未命名标的"
                let fundCode = holdingRow?.holding.normalizedFundCode
                    ?? rawHolding?.normalizedFundCode
                    ?? archivedHolding?.normalizedFundCode
                    ?? pending.first?.fundCode
                    ?? plans.first?.fundCode

                return PersonalAssetAggregateRow(
                    key: key,
                    assetType: assetType,
                    fundName: fundName,
                    fundCode: normalizedCode(fundCode),
                    holdingRow: holdingRow,
                    rawHolding: rawHolding,
                    archivedHolding: archivedHolding,
                    pendingTrades: pending,
                    plans: plans
                )
            }
            .sorted { left, right in
                let leftExposure = left.effectiveHoldingAmount
                let rightExposure = right.effectiveHoldingAmount
                if abs(leftExposure - rightExposure) > 0.001 {
                    return leftExposure > rightExposure
                }
                if left.pendingTradeCount != right.pendingTradeCount {
                    return left.pendingTradeCount > right.pendingTradeCount
                }
                if left.totalPlanCount != right.totalPlanCount {
                    return left.totalPlanCount > right.totalPlanCount
                }
                return left.fundName.localizedStandardCompare(right.fundName) == .orderedAscending
            }
        personalAssetRows = rows

        // Rebuild summary from the new rows
        guard !rows.isEmpty else {
            personalAssetSummary = nil
            return
        }
        var holdingFundCount = 0
        var pendingFundCount = 0
        var activePlanFundCount = 0
        var totalMarketValue = 0.0
        var totalPendingCashAmount = 0.0
        var totalActivePlanCount = 0
        var totalPausedPlanCount = 0
        var totalEndedPlanCount = 0
        var totalCumulativePlanAmount = 0.0
        var totalEstimatedNextPlanAmount = 0.0
        var totalEffectiveHoldingAmount = 0.0
        for row in rows {
            if row.hasHolding {
                holdingFundCount += 1
            }
            if row.hasPending {
                pendingFundCount += 1
            }
            if row.activePlanCount > 0 {
                activePlanFundCount += 1
            }
            totalMarketValue += row.marketValue ?? 0
            totalPendingCashAmount += row.pendingCashAmount
            totalActivePlanCount += row.activePlanCount
            totalPausedPlanCount += row.pausedPlanCount
            totalEndedPlanCount += row.endedPlanCount
            totalCumulativePlanAmount += row.totalCumulativePlanAmount
            totalEstimatedNextPlanAmount += row.estimatedNextPlanAmount
            totalEffectiveHoldingAmount += row.effectiveHoldingAmount
        }

        personalAssetSummary = PersonalAssetAggregateSummary(
            fundCount: rows.count,
            holdingFundCount: holdingFundCount,
            pendingFundCount: pendingFundCount,
            activePlanFundCount: activePlanFundCount,
            totalMarketValue: totalMarketValue,
            totalPendingCashAmount: totalPendingCashAmount,
            totalActivePlanCount: totalActivePlanCount,
            totalPausedPlanCount: totalPausedPlanCount,
            totalEndedPlanCount: totalEndedPlanCount,
            totalCumulativePlanAmount: totalCumulativePlanAmount,
            totalEstimatedNextPlanAmount: totalEstimatedNextPlanAmount,
            totalEffectiveHoldingAmount: totalEffectiveHoldingAmount
        )
    }

    var activeUserPortfolioHoldings: [UserPortfolioHolding] {
        userPortfolioHoldings.filter { !$0.isArchived }
    }
}
