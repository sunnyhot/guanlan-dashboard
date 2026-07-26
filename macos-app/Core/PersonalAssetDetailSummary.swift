import Foundation

enum PersonalAssetDetailAttentionKind: Hashable {
    case pendingTrade
    case investmentPlan
    case archivedHolding
}

enum PersonalAssetDetailTone: Hashable {
    case brand
    case info
    case warning
    case neutral
    case muted
    case marketGain
    case marketLoss
}

struct PersonalAssetDetailMetric: Identifiable, Hashable {
    let id: String
    let title: String
    let value: String
    let detail: String?
    let tone: PersonalAssetDetailTone

    init(title: String, value: String, detail: String? = nil, tone: PersonalAssetDetailTone) {
        self.id = title
        self.title = title
        self.value = value
        self.detail = detail
        self.tone = tone
    }
}

struct PersonalAssetDetailAttentionItem: Identifiable, Hashable {
    let kind: PersonalAssetDetailAttentionKind
    let title: String
    let detail: String
    let metric: String
    let tone: PersonalAssetDetailTone

    var id: String {
        "\(kind)-\(title)-\(detail)-\(metric)"
    }
}

struct PersonalAssetDetailSummary: Hashable {
    let title: String
    let codeText: String?
    let statusText: String
    let marketText: String?
    let effectiveAmountText: String
    let metrics: [PersonalAssetDetailMetric]
    let attentionItems: [PersonalAssetDetailAttentionItem]

    static func make(row: PersonalAssetAggregateRow) -> PersonalAssetDetailSummary {
        let market = row.detectedMarket
        let effectiveAmountText = currencyText(row.effectiveHoldingAmount, market: market)
        let statusText = row.combinedStatusText
        let marketText = row.rawHolding?.marketLabel ?? row.holdingRow?.holding.marketLabel ?? row.archivedHolding?.marketLabel

        let metrics = [
            PersonalAssetDetailMetric(
                title: "总收益",
                value: signedCurrencyText(row.profitAmount, market: market),
                detail: percentOptional(row.profitPct),
                tone: marketTone(for: row.profitAmount)
            ),
            PersonalAssetDetailMetric(
                title: row.changePeriodTitle,
                value: dailyChangeCurrencyText(row.estimateChangeAmount, market: market),
                detail: dailyChangePercentText(row.estimateChangePct),
                tone: marketTone(for: row.estimateChangeAmount)
            ),
            PersonalAssetDetailMetric(
                title: row.usesMarketTradeColumns ? "现价 / 估值" : "净值 / 估值",
                value: "\(decimalOptional(row.currentPrice)) / \(decimalOptional(row.currentEstimatePrice))",
                detail: row.holdingRow?.resolvedPriceTime.map { "更新于 \($0)" },
                tone: .neutral
            ),
            PersonalAssetDetailMetric(
                title: "持仓成本",
                value: decimalOptional(row.costPrice),
                tone: .neutral
            ),
            PersonalAssetDetailMetric(
                title: "待确认",
                value: row.pendingCashAmount > 0
                    ? currencyText(row.pendingCashAmount, market: market)
                    : (row.pendingUnitAmount > 0 ? "\(unitsText(row.pendingUnitAmount)) 份" : "—"),
                detail: row.pendingTradeCount > 0 ? "\(row.pendingTradeCount) 笔" : nil,
                tone: .warning
            ),
            PersonalAssetDetailMetric(
                title: "下次计划",
                value: row.estimatedNextPlanAmount > 0 ? currencyText(row.estimatedNextPlanAmount, market: market) : "—",
                detail: row.nextExecutionDate,
                tone: .info
            )
        ]

        return PersonalAssetDetailSummary(
            title: row.fundName,
            codeText: row.fundCode,
            statusText: statusText,
            marketText: marketText,
            effectiveAmountText: effectiveAmountText,
            metrics: metrics,
            attentionItems: makeAttentionItems(row: row)
        )
    }

    private static func makeAttentionItems(row: PersonalAssetAggregateRow) -> [PersonalAssetDetailAttentionItem] {
        let market = row.detectedMarket
        var items: [PersonalAssetDetailAttentionItem] = []

        for trade in row.pendingTrades.prefix(3) {
            let metric: String
            if let amount = trade.amountValue {
                metric = currencyText(amount, market: market)
            } else if let units = trade.unitValue {
                metric = "\(unitsText(units)) 份"
            } else {
                metric = trade.amountText.isEmpty ? "待确认" : trade.amountText
            }
            items.append(
                PersonalAssetDetailAttentionItem(
                    kind: .pendingTrade,
                    title: trade.actionLabel.isEmpty ? "买入中" : trade.actionLabel,
                    detail: compactParts([trade.occurredAt, trade.status, trade.note]).joined(separator: " · "),
                    metric: metric,
                    tone: .warning
                )
            )
        }

        let costDeviationPct = PersonalInvestmentPlan.drawdownCostDeviationPct(
            currentPrice: row.currentPrice,
            costPrice: row.costPrice
        )
        for plan in row.plans.filter(\.isActivePlan).prefix(3) {
            let estimatedAmount = plan.estimatedExecutionAmount(costDeviationPct: costDeviationPct)
            items.append(
                PersonalAssetDetailAttentionItem(
                    kind: .investmentPlan,
                    title: plan.planTypeLabel.isEmpty ? "定投计划" : plan.planTypeLabel,
                    detail: compactParts([plan.scheduleText, plan.nextExecutionDate, plan.paymentMethod]).joined(separator: " · "),
                    metric: currencyText(estimatedAmount, market: market),
                    tone: plan.isDrawdownMode ? .info : .brand
                )
            )
        }

        if row.hasArchivedHolding, !row.hasHolding {
            let archivedDate = row.archivedHolding?.archivedAt.map { String($0.prefix(10)) } ?? "未知时间"
            items.append(
                PersonalAssetDetailAttentionItem(
                    kind: .archivedHolding,
                    title: "归档持仓",
                    detail: "归档于 \(archivedDate)",
                    metric: row.archivedUnits.map { "\(unitsText($0)) 份" } ?? "—",
                    tone: .muted
                )
            )
        }

        return items
    }

    private static func marketTone(for value: Double?) -> PersonalAssetDetailTone {
        guard let value else { return .muted }
        if value > 0 { return .marketGain }
        if value < 0 { return .marketLoss }
        return .muted
    }

    private static func compactParts(_ values: [String?]) -> [String] {
        values.compactMap { value in
            let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }
    }
}
