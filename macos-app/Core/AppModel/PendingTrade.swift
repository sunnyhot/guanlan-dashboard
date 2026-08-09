import Foundation

// MARK: - Pending Trade CRUD

extension AppModel {

    @discardableResult
    func addPendingTrade(
        occurredAt: String,
        actionLabel: String,
        fundName: String,
        fundCode: String,
        targetFundName: String,
        targetFundCode: String,
        amountText: String,
        status: String,
        note: String
    ) -> Bool {
        guard let pendingTradeFileURL else {
            errorMessage = "应用数据目录还没准备好，暂时无法添加买入中记录。"
            return false
        }
        guard let trade = validatedPendingTrade(
            id: UUID(),
            occurredAt: occurredAt,
            actionLabel: actionLabel,
            fundName: fundName,
            fundCode: fundCode,
            targetFundName: targetFundName,
            targetFundCode: targetFundCode,
            amountText: amountText,
            status: status,
            note: note
        ) else {
            return false
        }

        do {
            pendingTrades.append(trade)
            pendingTrades.sort { $0.occurredAt > $1.occurredAt }
            clearPendingTradeCaches()
            rebuildAssetRows()
            try pendingTradesStore.save(pendingTrades, to: pendingTradeFileURL)
            noticeMessage = "已添加 \(trade.displayTitle) 的买入中记录。"
            Task { await applyPersonalAssetAutomation() }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func updatePendingTrade(
        _ tradeID: UUID,
        occurredAt: String,
        actionLabel: String,
        fundName: String,
        fundCode: String,
        targetFundName: String,
        targetFundCode: String,
        amountText: String,
        status: String,
        note: String
    ) -> Bool {
        guard let existingIndex = pendingTrades.firstIndex(where: { $0.id == tradeID }) else {
            errorMessage = "没有找到这条买入中记录。"
            return false
        }
        guard let pendingTradeFileURL else {
            errorMessage = "应用数据目录还没准备好，暂时无法保存买入中记录。"
            return false
        }
        guard let trade = validatedPendingTrade(
            id: tradeID,
            occurredAt: occurredAt,
            actionLabel: actionLabel,
            fundName: fundName,
            fundCode: fundCode,
            targetFundName: targetFundName,
            targetFundCode: targetFundCode,
            amountText: amountText,
            status: status,
            note: note
        ) else {
            return false
        }

        do {
            pendingTrades[existingIndex] = trade
            pendingTrades.sort { $0.occurredAt > $1.occurredAt }
            clearPendingTradeCaches()
            rebuildAssetRows()
            try pendingTradesStore.save(pendingTrades, to: pendingTradeFileURL)
            noticeMessage = "已更新 \(trade.displayTitle) 的买入中记录。"
            Task { await applyPersonalAssetAutomation() }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deletePendingTrade(_ tradeID: UUID) {
        guard let pendingTradeFileURL else {
            errorMessage = "应用数据目录还没准备好，暂时无法删除买入中记录。"
            return
        }
        guard let existingTrade = pendingTrades.first(where: { $0.id == tradeID }) else {
            errorMessage = "没有找到这条买入中记录。"
            return
        }

        do {
            pendingTrades = pendingTrades.filter { $0.id != tradeID }
            clearPendingTradeCaches()
            rebuildAssetRows()
            if pendingTrades.isEmpty {
                try pendingTradesStore.delete(at: pendingTradeFileURL)
            } else {
                try pendingTradesStore.save(pendingTrades, to: pendingTradeFileURL)
            }
            noticeMessage = "已删除 \(existingTrade.displayTitle) 的买入中记录。"
            Task { await applyPersonalAssetAutomation() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadPendingTrades() {
        guard let pendingTradeFileURL else { return }
        do {
            pendingTrades = try pendingTradesStore.load(from: pendingTradeFileURL)
                .sorted { $0.occurredAt > $1.occurredAt }
            clearPendingTradeCaches()
            rebuildAssetRows()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}
