import Foundation

private struct PreparedPersonalWatchlistAlert {
    let row: PersonalWatchlistQuoteRow
    let triggers: [PersonalWatchlistAlertTrigger]
}

extension AppModel {
    func preparePersonalWatchlistCode(
        category: PersonalWatchlistCategory,
        codeText: String
    ) -> PersonalAssetCodeResolution? {
        let rawCode = normalizedManualAssetRawCode(codeText)
        guard !rawCode.isEmpty else { return nil }

        let code = normalizedManualAssetCode(assetType: category.assetType, codeText: rawCode)
        guard !code.isEmpty else { return nil }

        return PersonalAssetCodeResolution(
            assetType: category.assetType,
            code: code,
            displayName: nil,
            stockMarket: category == .stock
                ? manualStockMarket(assetType: .stock, codeText: rawCode)
                : nil,
            fundMarket: category.fundMarket
        )
    }

    func resolvePersonalWatchlistCode(
        category: PersonalWatchlistCategory,
        codeText: String
    ) async -> PersonalAssetCodeResolution? {
        guard let prepared = preparePersonalWatchlistCode(category: category, codeText: codeText) else {
            return nil
        }
        let holding = UserPortfolioHolding(
            fundCode: prepared.code,
            assetType: prepared.assetType,
            units: 1,
            costPrice: nil,
            displayName: nil,
            stockMarket: prepared.stockMarket,
            fundMarket: prepared.fundMarket
        )
        let displayName = await platformClient.resolveAssetNames(holdings: [holding])[holding.id]

        return PersonalAssetCodeResolution(
            assetType: prepared.assetType,
            code: prepared.code,
            displayName: normalizedOptionalName(displayName),
            stockMarket: prepared.stockMarket ?? holding.detectedMarket,
            fundMarket: prepared.fundMarket
        )
    }

    @discardableResult
    func addPersonalWatchlistItem(
        category: PersonalWatchlistCategory,
        resolution: PersonalAssetCodeResolution
    ) async -> Bool {
        guard let personalWatchlistFileURL else {
            errorMessage = "应用数据目录还没准备好，暂时无法添加关注。"
            return false
        }

        let item = PersonalWatchlistItem(
            code: resolution.code,
            displayName: resolution.displayName,
            assetType: category.assetType,
            stockMarket: category == .stock ? resolution.stockMarket : nil,
            fundMarket: category.fundMarket,
            followedAt: timestampNow()
        )
        guard !personalWatchlistRecords.contains(where: { $0.item.identityKey == item.identityKey }) else {
            errorMessage = "这个标的已经在我的关注中。"
            return false
        }

        var newRecord = PersonalWatchlistRecord(item: item)
        do {
            let snapshot = try await platformClient.fetchPersonalWatchlistSnapshot(
                records: [newRecord],
                forceQuoteRefresh: true
            )
            if let row = snapshot.rows.first {
                let baseline = row.currentPrice.flatMap { price -> PersonalWatchlistBaseline? in
                    guard price > 0 else { return nil }
                    return PersonalWatchlistBaseline(
                        price: price,
                        quotedAt: row.quotedAt,
                        capturedAt: timestampNow(),
                        sourceLabel: row.sourceLabel
                    )
                }
                newRecord = row.record.updating(
                    displayName: row.displayName,
                    baseline: baseline
                )
            }
        } catch {
            // Offline additions stay in the list. The first successful refresh
            // captures the immutable baseline instead of inventing a zero price.
        }

        do {
            let nextRecords = personalWatchlistRecords + [newRecord]
            try personalWatchlistStore.save(nextRecords, to: personalWatchlistFileURL)
            personalWatchlistRecords = nextRecords
            personalWatchlistSnapshot = .local(records: nextRecords)

            let name = newRecord.item.normalizedName ?? newRecord.item.normalizedCode
            if let baseline = newRecord.baseline {
                noticeMessage = "已关注 \(name)，起始价 \(personalAssetDecimalText(baseline.price)) 已记录。"
            } else {
                noticeMessage = "已关注 \(name)；当前行情暂不可用，首次成功刷新时会锁定起始价。"
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func removePersonalWatchlistItem(_ id: UUID) {
        guard let personalWatchlistFileURL else { return }
        guard let removed = personalWatchlistRecords.first(where: { $0.id == id }) else { return }

        do {
            let nextRecords = personalWatchlistRecords.filter { $0.id != id }
            if nextRecords.isEmpty {
                try personalWatchlistStore.delete(at: personalWatchlistFileURL)
            } else {
                try personalWatchlistStore.save(nextRecords, to: personalWatchlistFileURL)
            }
            personalWatchlistRecords = nextRecords
            personalWatchlistSnapshot = nextRecords.isEmpty ? nil : .local(records: nextRecords)
            noticeMessage = "已取消关注 \(removed.item.normalizedName ?? removed.item.normalizedCode)。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func setPersonalWatchlistAlertRules(
        _ proposedRules: PersonalWatchlistAlertRules?,
        for id: UUID
    ) async -> Bool {
        guard let personalWatchlistFileURL,
              let index = personalWatchlistRecords.firstIndex(where: { $0.id == id }) else {
            errorMessage = "没有找到对应的关注标的。"
            return false
        }

        let rules = proposedRules.flatMap { $0.isEmpty ? nil : $0 }
        if let rules,
           let priceAbove = rules.priceAbove,
           let priceBelow = rules.priceBelow,
           priceBelow >= priceAbove {
            errorMessage = "低价提醒必须小于高价提醒。"
            return false
        }
        if let loss = rules?.lossSinceFollowPct, loss >= 100 {
            errorMessage = "跌幅提醒必须小于 100%。"
            return false
        }
        if rules != nil {
            guard await notificationManager.requestAuthorizationIfNeeded() else {
                errorMessage = "系统通知权限未开启。请在系统设置中允许“且慢主理人”发送通知。"
                return false
            }
        }

        let currentRecord = personalWatchlistRecords[index]
        let nextRecord = currentRecord.alertRules == rules
            ? currentRecord
            : currentRecord.replacingAlertRules(rules)
        var nextRecords = personalWatchlistRecords
        nextRecords[index] = nextRecord

        do {
            try personalWatchlistStore.save(nextRecords, to: personalWatchlistFileURL)
            personalWatchlistRecords = nextRecords
            if let snapshot = personalWatchlistSnapshot {
                personalWatchlistSnapshot = PersonalWatchlistSnapshot(
                    rows: snapshot.rows.map { row in
                        row.id == id ? row.replacingRecord(nextRecord) : row
                    },
                    refreshedAt: snapshot.refreshedAt
                )
            } else {
                personalWatchlistSnapshot = .local(records: nextRecords)
            }

            let name = nextRecord.item.normalizedName ?? nextRecord.item.normalizedCode
            if let rules {
                noticeMessage = "已为 \(name) 保存 \(rules.ruleCount) 条价格提醒。"
                do {
                    try await refreshPersonalWatchlist(updateNotice: false)
                } catch {
                    errorMessage = "提醒已保存；当前行情刷新失败，将在下次自动刷新时继续监控。"
                }
            } else {
                noticeMessage = "已关闭 \(name) 的价格提醒。"
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func refreshPersonalWatchlist(updateNotice: Bool = true) async throws {
        guard !personalWatchlistRecords.isEmpty else {
            personalWatchlistSnapshot = nil
            return
        }
        guard !isRefreshingPersonalWatchlist else { return }

        isRefreshingPersonalWatchlist = true
        defer { isRefreshingPersonalWatchlist = false }

        let snapshot = try await platformClient.fetchPersonalWatchlistSnapshot(
            records: personalWatchlistRecords,
            forceQuoteRefresh: updateNotice
        )
        let capturedAt = timestampNow()
        let baselineUpdatedRows = snapshot.rows.map { row -> PersonalWatchlistQuoteRow in
            let proposedBaseline = row.currentPrice.flatMap { price -> PersonalWatchlistBaseline? in
                guard row.record.baseline == nil, price > 0 else { return nil }
                return PersonalWatchlistBaseline(
                    price: price,
                    quotedAt: row.quotedAt,
                    capturedAt: capturedAt,
                    sourceLabel: row.sourceLabel
                )
            }
            let record = row.record.updating(
                displayName: row.displayName,
                baseline: proposedBaseline
            )
            return PersonalWatchlistQuoteRow(
                record: record,
                assetName: row.displayName,
                currentPrice: row.currentPrice,
                quotedAt: row.quotedAt,
                sourceLabel: row.sourceLabel,
                dailyChangePct: row.dailyChangePct,
                dailyPoints: record.dailyPoints
            )
        }

        let alertResult = await preparePersonalWatchlistAlerts(
            rows: baselineUpdatedRows,
            triggeredAt: capturedAt
        )
        let updatedRows = alertResult.rows

        let refreshedByID = Dictionary(uniqueKeysWithValues: updatedRows.map { ($0.id, $0.record) })
        let nextRecords = personalWatchlistRecords.map { refreshedByID[$0.id] ?? $0 }
        if let personalWatchlistFileURL {
            try personalWatchlistStore.save(nextRecords, to: personalWatchlistFileURL)
        }

        personalWatchlistRecords = nextRecords
        personalWatchlistSnapshot = PersonalWatchlistSnapshot(
            rows: updatedRows,
            refreshedAt: snapshot.refreshedAt
        )

        for alert in alertResult.pendingAlerts {
            try? await notificationManager.send(
                title: personalWatchlistAlertTitle(for: alert),
                subtitle: alert.row.sourceLabel,
                body: personalWatchlistAlertBody(for: alert),
                deepLink: NotificationDeepLinkPayload(
                    type: .personalWatchlist,
                    targetID: alert.row.id.uuidString
                )
            )
        }
        if updateNotice {
            noticeMessage = "我的关注已刷新：\(snapshot.quotedItemCount)/\(snapshot.itemCount) 个标的取得最新行情。"
        }
    }

    func loadSavedPersonalWatchlist() {
        guard let personalWatchlistFileURL else { return }
        do {
            let records = try personalWatchlistStore.load(from: personalWatchlistFileURL)
            personalWatchlistRecords = records
            personalWatchlistSnapshot = records.isEmpty ? nil : .local(records: records)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func preparePersonalWatchlistAlerts(
        rows: [PersonalWatchlistQuoteRow],
        triggeredAt: String
    ) async -> (rows: [PersonalWatchlistQuoteRow], pendingAlerts: [PreparedPersonalWatchlistAlert]) {
        let committed = evaluatePersonalWatchlistAlerts(
            rows: rows,
            triggeredAt: triggeredAt,
            commitNewTriggers: true
        )
        guard !committed.pendingAlerts.isEmpty else { return committed }
        guard await notificationManager.requestAuthorizationIfNeeded() else {
            let uncommitted = evaluatePersonalWatchlistAlerts(
                rows: rows,
                triggeredAt: triggeredAt,
                commitNewTriggers: false
            )
            return (uncommitted.rows, [])
        }
        return committed
    }

    private func evaluatePersonalWatchlistAlerts(
        rows: [PersonalWatchlistQuoteRow],
        triggeredAt: String,
        commitNewTriggers: Bool
    ) -> (rows: [PersonalWatchlistQuoteRow], pendingAlerts: [PreparedPersonalWatchlistAlert]) {
        var pendingAlerts: [PreparedPersonalWatchlistAlert] = []
        let evaluatedRows = rows.map { row -> PersonalWatchlistQuoteRow in
            guard let rules = row.record.alertRules else { return row }
            let evaluation = PersonalWatchlistAlertEvaluator.evaluate(
                rules: rules,
                previousState: row.record.effectiveAlertState,
                currentPrice: row.currentPrice,
                baselinePrice: row.record.baseline?.price,
                triggeredAt: triggeredAt,
                commitNewTriggers: commitNewTriggers
            )
            let nextRow = row.replacingRecord(
                row.record.replacingAlertState(evaluation.nextState)
            )
            if !evaluation.triggers.isEmpty {
                pendingAlerts.append(
                    PreparedPersonalWatchlistAlert(row: nextRow, triggers: evaluation.triggers)
                )
            }
            return nextRow
        }
        return (evaluatedRows, pendingAlerts)
    }

    private func personalWatchlistAlertTitle(for alert: PreparedPersonalWatchlistAlert) -> String {
        let name = alert.row.displayName
        guard alert.triggers.count == 1, let kind = alert.triggers.first?.kind else {
            return "关注提醒：\(name)"
        }
        switch kind {
        case .priceAbove, .priceBelow:
            return "\(name)已触发价格提醒"
        case .gainSinceFollow:
            return "\(name)已触发涨幅提醒"
        case .lossSinceFollow:
            return "\(name)已触发跌幅提醒"
        }
    }

    private func personalWatchlistAlertBody(for alert: PreparedPersonalWatchlistAlert) -> String {
        let conditions = alert.triggers.map { trigger -> String in
            switch trigger.kind {
            case .priceAbove:
                return "价格达到 \(personalWatchlistAlertPriceText(trigger.threshold, item: alert.row.item)) 以上"
            case .priceBelow:
                return "价格达到 \(personalWatchlistAlertPriceText(trigger.threshold, item: alert.row.item)) 以下"
            case .gainSinceFollow:
                return "关注以来上涨达到 \(String(format: "%.2f%%", trigger.threshold))"
            case .lossSinceFollow:
                return "关注以来下跌达到 \(String(format: "%.2f%%", trigger.threshold))"
            }
        }
        return "当前 \(personalWatchlistAlertPriceText(alert.row.currentPrice, item: alert.row.item))，关注以来 \(percentOptional(alert.row.changeSinceFollowPct))；\(conditions.joined(separator: "，"))。"
    }

    private func personalWatchlistAlertPriceText(_ value: Double?, item: PersonalWatchlistItem) -> String {
        guard let value else { return "—" }
        if item.assetType == .stock {
            return currencyText(value, market: item.detectedStockMarket)
        }
        return decimalText(value)
    }
}
