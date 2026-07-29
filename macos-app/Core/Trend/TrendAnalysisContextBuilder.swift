import Foundation

struct TrendAnalysisContextBuilder {
    func build(
        rows: [PersonalAssetAggregateRow],
        summary: PersonalAssetAggregateSummary?,
        platformActions: [PlatformActionPayload],
        watchSummary: ManagerWatchTimelineSummary,
        insightSummary: PortfolioSnapshotInsightSummary,
        privacyMode: TrendPrivacyMode,
        createdAt: String
    ) -> TrendAnalysisContext {
        let totalEffectiveAmount = summary?.totalEffectiveHoldingAmount
            ?? rows.reduce(0) { $0 + $1.effectiveHoldingAmount }
        let sortedRows = rows.sorted { $0.effectiveHoldingAmount > $1.effectiveHoldingAmount }
        let assets = sortedRows.map { row in
            assetContext(row: row, totalEffectiveAmount: totalEffectiveAmount, privacyMode: privacyMode)
        }
        let sectors = sectorContexts(rows: sortedRows, totalEffectiveAmount: totalEffectiveAmount, privacyMode: privacyMode)

        return TrendAnalysisContext(
            createdAt: createdAt,
            privacyMode: privacyMode,
            portfolio: TrendContextPortfolio(
                assetCount: rows.count,
                holdingCount: summary?.holdingFundCount ?? rows.filter(\.hasHolding).count,
                activePlanCount: summary?.totalActivePlanCount ?? rows.reduce(0) { $0 + $1.activePlanCount },
                pendingAssetCount: summary?.pendingFundCount ?? rows.filter { $0.pendingTradeCount > 0 }.count,
                totalMarketValue: privacyMode == .fullDetail ? summary?.totalMarketValue : nil,
                totalPendingCashAmount: privacyMode == .fullDetail ? summary?.totalPendingCashAmount : nil,
                totalEstimatedNextPlanAmount: privacyMode == .fullDetail ? summary?.totalEstimatedNextPlanAmount : nil,
                totalEffectiveHoldingAmount: privacyMode == .fullDetail ? totalEffectiveAmount : nil
            ),
            assets: assets,
            sectors: sectors,
            platformSignals: platformActions.prefix(8).map(platformSignal),
            watchSummary: watchSummary.latestStatusText,
            insightHeadline: insightSummary.headline
        )
    }

    private func assetContext(
        row: PersonalAssetAggregateRow,
        totalEffectiveAmount: Double,
        privacyMode: TrendPrivacyMode
    ) -> TrendContextAsset {
        let includeAmounts = privacyMode == .fullDetail
        return TrendContextAsset(
            id: row.key,
            name: row.fundName,
            code: row.fundCode,
            assetType: row.assetTypeLabel,
            sector: sectorName(for: row),
            statusText: row.combinedStatusText,
            weightText: includeAmounts ? nil : percentageText(row.effectiveHoldingAmount, total: totalEffectiveAmount),
            profitPct: row.profitPct,
            estimateChangePct: row.estimateChangePct,
            pendingTradeCount: row.pendingTradeCount,
            activePlanCount: row.activePlanCount,
            pausedPlanCount: row.pausedPlanCount,
            endedPlanCount: row.endedPlanCount,
            marketValue: includeAmounts ? row.marketValue : nil,
            costValue: includeAmounts ? row.holdingRow?.costValue : nil,
            profitAmount: includeAmounts ? row.profitAmount : nil,
            pendingCashAmount: includeAmounts ? row.pendingCashAmount : nil,
            estimatedNextPlanAmount: includeAmounts ? row.estimatedNextPlanAmount : nil,
            totalCumulativePlanAmount: includeAmounts ? row.totalCumulativePlanAmount : nil
        )
    }

    private func sectorContexts(
        rows: [PersonalAssetAggregateRow],
        totalEffectiveAmount: Double,
        privacyMode: TrendPrivacyMode
    ) -> [TrendContextSector] {
        let grouped = Dictionary(grouping: rows, by: sectorName)
        return grouped.map { name, rows in
            let exposureAmount = rows.reduce(0) { $0 + $1.effectiveHoldingAmount }
            return TrendContextSector(
                name: name,
                assetCount: rows.count,
                exposureText: percentageText(exposureAmount, total: totalEffectiveAmount) ?? "0.00%",
                exposureAmount: privacyMode == .fullDetail ? exposureAmount : nil
            )
        }
        .sorted { lhs, rhs in
            if lhs.assetCount == rhs.assetCount {
                return lhs.name < rhs.name
            }
            return lhs.assetCount > rhs.assetCount
        }
    }

    private func sectorName(for row: PersonalAssetAggregateRow) -> String {
        if row.assetType == .stock {
            switch row.detectedMarket {
            case .us:
                return "美股"
            case .hk:
                return "港股"
            case .aShare:
                return "A股"
            case .none:
                return row.assetTypeLabel
            }
        }

        switch row.detectedFundMarket {
        case .onExchange:
            return "场内基金"
        case .offExchange:
            return "场外基金"
        case .none:
            return row.assetTypeLabel
        }
    }

    private func platformSignal(_ action: PlatformActionPayload) -> String {
        let target = action.fundName ?? action.fundCode ?? "未知标的"
        let side = action.side ?? action.action ?? "动作"
        let time = action.txnDate ?? action.createdAt ?? "未知时间"
        let change = action.valuationChangePct.map { String(format: "%+.2f%%", $0) } ?? "估值变化未知"
        return "\(time) · \(side) · \(target) · \(change)"
    }

    private func percentageText(_ value: Double, total: Double) -> String? {
        guard total > 0 else { return nil }
        return String(format: "%.2f%%", value / total * 100)
    }
}
