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
            // 现价/估值二选一：优先显示现价，没有才显示估值
            currentPriceMetric(row: row),
            PersonalAssetDetailMetric(
                title: "持仓成本",
                value: decimalOptional(row.costPrice),
                tone: .neutral
            ),
            // 待确认：仅在有买入中交易时才显示
            pendingMetric(row: row, market: market),
            // 下次计划：仅在有计划金额时才显示
            nextPlanMetric(row: row, market: market)
        ].compactMap { $0 }

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

    // MARK: - 条件性指标（现价/估值、待确认、下次计划）

    /// 现价/估值二选一：优先显示现价；现价为空才显示估值；都没有返回 nil。
    private static func currentPriceMetric(row: PersonalAssetAggregateRow) -> PersonalAssetDetailMetric? {
        let title = row.usesMarketTradeColumns ? "现价" : "单位净值"
        // 取日期+时分（yyyy-MM-dd HH:mm），去掉秒，避免过长撑爆卡片
        let updateTime = row.holdingRow?.resolvedPriceTime?.shortDateTimePart
        if let price = row.currentPrice, price > 0 {
            return PersonalAssetDetailMetric(
                title: title,
                value: decimalOptional(price),
                detail: updateTime.map { "更新 \($0)" },
                tone: .neutral
            )
        }
        if let estimate = row.currentEstimatePrice, estimate > 0 {
            let estimateTitle = row.usesMarketTradeColumns ? "估值" : "盘中估值"
            return PersonalAssetDetailMetric(
                title: estimateTitle,
                value: decimalOptional(estimate),
                detail: updateTime.map { "更新 \($0)" },
                tone: .neutral
            )
        }
        return nil
    }

    /// 待确认：仅在有买入中交易（金额或份数 > 0）时显示，否则返回 nil。
    private static func pendingMetric(row: PersonalAssetAggregateRow, market: StockMarket?) -> PersonalAssetDetailMetric? {
        guard row.pendingCashAmount > 0 || row.pendingUnitAmount > 0 else { return nil }
        let value = row.pendingCashAmount > 0
            ? currencyText(row.pendingCashAmount, market: market)
            : "\(unitsText(row.pendingUnitAmount)) 份"
        return PersonalAssetDetailMetric(
            title: "待确认",
            value: value,
            detail: row.pendingTradeCount > 0 ? "\(row.pendingTradeCount) 笔" : nil,
            tone: .warning
        )
    }

    /// 下次计划：仅在有计划金额时显示，否则返回 nil。
    private static func nextPlanMetric(row: PersonalAssetAggregateRow, market: StockMarket?) -> PersonalAssetDetailMetric? {
        guard row.estimatedNextPlanAmount > 0 else { return nil }
        return PersonalAssetDetailMetric(
            title: "下次计划",
            value: currencyText(row.estimatedNextPlanAmount, market: market),
            detail: row.nextExecutionDate,
            tone: .info
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

// MARK: - String 日期截断辅助

extension String {
    /// 取 yyyy-MM-dd 部分（前 10 字符）。用于在窄卡片里精简显示时间。
    var shortDatePart: String {
        guard count >= 10 else { return self }
        return String(prefix(10))
    }

    /// 取 MM-dd HH:mm 部分（去掉年份和秒）。格式如「03-15 15:00」。
    var shortDateTimePart: String {
        // 期望格式 yyyy-MM-dd HH:mm:ss，取 MM-dd + 空格 + HH:mm
        guard count >= 16 else { return shortDatePart }
        let monthDay = String(self[index(startIndex, offsetBy: 5)..<index(startIndex, offsetBy: 10)])
        let hourMin = String(self[index(startIndex, offsetBy: 11)..<index(startIndex, offsetBy: 16)])
        return "\(monthDay) \(hourMin)"
    }
}
