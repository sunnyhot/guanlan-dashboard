import Foundation

// MARK: - Portfolio CRUD

extension AppModel {

    func clearPortfolio() {
        guard let portfolioFileURL else { return }
        do {
            try portfolioStore.delete(at: portfolioFileURL)
            userPortfolioHoldings = []
            // 清空所有估值预警
            if let portfolioValuationAlertFileURL {
                try? portfolioValuationAlertStore.save([:], to: portfolioValuationAlertFileURL)
            }
            portfolioValuationAlertProfiles = [:]
            userPortfolioSnapshot = nil
            rebuildAssetRows()
            noticeMessage = "已清空个人持仓。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deletePersonalAssetEntry(_ row: PersonalAssetAggregateRow, scope: PersonalAssetDeleteScope) {
        let holdingIDs = Set(scope.includesHolding ? [
            row.rawHolding?.id,
            row.holdingRow?.holding.id,
            row.archivedHolding?.id,
        ].compactMap { $0 } : [])
        let pendingTradeIDs = Set(scope.includesPendingTrades ? row.pendingTrades.map(\.id) : [])
        let investmentPlanIDs = Set(scope.includesInvestmentPlans ? row.plans.map(\.id) : [])

        do {
            var deletedParts: [String] = []
            var shouldRefreshPortfolio = false

            if !holdingIDs.isEmpty {
                guard let portfolioFileURL else {
                    throw LiveRefreshError(message: "应用数据目录还没准备好，暂时无法删除持仓。")
                }

                let nextHoldings = userPortfolioHoldings.filter { !holdingIDs.contains($0.id) }
                if nextHoldings.count != userPortfolioHoldings.count {
                    userPortfolioHoldings = nextHoldings
                    userPortfolioSnapshot = nil
                    if nextHoldings.isEmpty {
                        try portfolioStore.delete(at: portfolioFileURL)
                    } else {
                        try portfolioStore.save(nextHoldings, to: portfolioFileURL)
                        shouldRefreshPortfolio = !activeUserPortfolioHoldings.isEmpty
                    }
                    deletedParts.append(row.hasArchivedHolding && !row.hasHolding ? "归档持仓" : "已持有")
                    // 联动清理估值预警
                    if let fundCode = row.fundCode {
                        removePortfolioValuationAlertProfile(fundCode: fundCode)
                    }
                }
            }

            if !pendingTradeIDs.isEmpty {
                guard let pendingTradeFileURL else {
                    throw LiveRefreshError(message: "应用数据目录还没准备好，暂时无法删除买入中记录。")
                }

                let nextTrades = pendingTrades.filter { !pendingTradeIDs.contains($0.id) }
                let deletedCount = pendingTrades.count - nextTrades.count
                if deletedCount > 0 {
                    pendingTrades = nextTrades.sorted { $0.occurredAt > $1.occurredAt }
                    if pendingTrades.isEmpty {
                        try pendingTradesStore.delete(at: pendingTradeFileURL)
                    } else {
                        try pendingTradesStore.save(pendingTrades, to: pendingTradeFileURL)
                    }
                    deletedParts.append("买入中 \(deletedCount) 条")
                }
            }

            if !investmentPlanIDs.isEmpty {
                guard let investmentPlanFileURL else {
                    throw LiveRefreshError(message: "应用数据目录还没准备好，暂时无法删除定投计划。")
                }

                let nextPlans = investmentPlans.filter { !investmentPlanIDs.contains($0.id) }
                let deletedCount = investmentPlans.count - nextPlans.count
                if deletedCount > 0 {
                    investmentPlans = nextPlans.sorted(by: sortInvestmentPlans)
                    if investmentPlans.isEmpty {
                        try investmentPlansStore.delete(at: investmentPlanFileURL)
                    } else {
                        try investmentPlansStore.save(investmentPlans, to: investmentPlanFileURL)
                    }
                    deletedParts.append("计划档案 \(deletedCount) 条")
                }
            }

            guard !deletedParts.isEmpty else {
                noticeMessage = "没有找到可删除的本地记录。"
                return
            }

            rebuildAssetRows()
            let itemText = row.fundCode.map { "\(row.fundName)（\($0)）" } ?? row.fundName
            noticeMessage = "已删除 \(itemText) 的\(deletedParts.joined(separator: "、"))记录。"

            if shouldRefreshPortfolio {
                Task { try? await refreshUserPortfolio(updateNotice: false) }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func archivePersonalAssetHolding(_ row: PersonalAssetAggregateRow) {
        setPersonalAssetHoldingArchived(row, isArchived: true)
    }

    func restorePersonalAssetHolding(_ row: PersonalAssetAggregateRow) {
        setPersonalAssetHoldingArchived(row, isArchived: false)
    }

    func setPersonalAssetHoldingArchived(_ row: PersonalAssetAggregateRow, isArchived: Bool) {
        let targetHolding = isArchived
            ? (row.rawHolding ?? row.holdingRow?.holding)
            : row.archivedHolding
        guard let targetHolding else {
            errorMessage = isArchived ? "这条资产没有可归档的已持有记录。" : "这条资产没有可恢复的归档记录。"
            return
        }
        guard let existingIndex = userPortfolioHoldings.firstIndex(where: { $0.id == targetHolding.id }) else {
            errorMessage = "没有找到这条持仓的本地保存记录。"
            return
        }
        guard let portfolioFileURL else {
            errorMessage = "应用数据目录还没准备好，暂时无法调整持仓归档。"
            return
        }

        if !isArchived {
            let duplicateActiveHolding = userPortfolioHoldings.contains { holding in
                guard holding.id != targetHolding.id, !holding.isArchived else { return false }
                guard holding.assetType == targetHolding.assetType else { return false }
                if targetHolding.assetType == .stock {
                    guard holding.detectedMarket == targetHolding.detectedMarket else { return false }
                } else {
                    guard holding.detectedFundMarket == targetHolding.detectedFundMarket else { return false }
                }
                return holding.normalizedFundCode.caseInsensitiveCompare(targetHolding.normalizedFundCode) == .orderedSame
            }
            guard !duplicateActiveHolding else {
                errorMessage = "本地已经有同代码的活跃持仓，请先合并或删除重复项。"
                return
            }
        }

        do {
            var nextHoldings = userPortfolioHoldings
            nextHoldings[existingIndex] = UserPortfolioHolding(
                id: targetHolding.id,
                fundCode: targetHolding.fundCode,
                assetType: targetHolding.assetType,
                units: targetHolding.units,
                costPrice: targetHolding.costPrice,
                displayName: targetHolding.displayName,
                stockMarket: targetHolding.stockMarket,
                fundMarket: targetHolding.fundMarket,
                isArchived: isArchived,
                archivedAt: isArchived ? timestampNow() : nil
            )
            userPortfolioHoldings = nextHoldings
            userPortfolioSnapshot = nil
            rebuildAssetRows()
            try portfolioStore.save(nextHoldings, to: portfolioFileURL)

            let itemText = row.fundCode.map { "\(row.fundName)（\($0)）" } ?? row.fundName
            noticeMessage = isArchived ? "已归档 \(itemText) 的持仓记录。" : "已恢复 \(itemText) 的持仓记录。"
            if !activeUserPortfolioHoldings.isEmpty {
                Task { try? await refreshUserPortfolio(updateNotice: false) }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func updatePersonalAssetHolding(
        _ row: PersonalAssetAggregateRow,
        codeText: String,
        unitsText: String,
        costPriceText: String,
        displayNameText: String
    ) -> Bool {
        guard let existingHolding = row.rawHolding ?? row.holdingRow?.holding else {
            errorMessage = "这条资产还没有已持有记录，暂时无法编辑持仓。"
            return false
        }
        guard let existingIndex = userPortfolioHoldings.firstIndex(where: { $0.id == existingHolding.id }) else {
            errorMessage = "没有找到这条持仓的本地保存记录。"
            return false
        }

        let fundCode = normalizedManualAssetCode(assetType: existingHolding.assetType, codeText: codeText)
        guard !fundCode.isEmpty else {
            errorMessage = "请输入\(existingHolding.assetType.displayName)代码。"
            return false
        }
        guard let units = decimalInputValue(unitsText), units > 0 else {
            errorMessage = "请输入大于 0 的份额。"
            return false
        }

        let trimmedCost = costPriceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let costPrice: Double?
        if trimmedCost.isEmpty {
            costPrice = nil
        } else {
            guard let parsedCost = decimalInputValue(trimmedCost), parsedCost > 0 else {
                errorMessage = "成本价为空或大于 0。"
                return false
            }
            costPrice = parsedCost
        }

        guard let portfolioFileURL else {
            errorMessage = "应用数据目录还没准备好，暂时无法保存持仓。"
            return false
        }

        let market = manualStockMarket(assetType: existingHolding.assetType, codeText: codeText)
            ?? existingHolding.stockMarket
            ?? existingHolding.detectedMarket
        let fundMarket = manualFundMarket(assetType: existingHolding.assetType, codeText: codeText)
            ?? existingHolding.fundMarket
            ?? existingHolding.detectedFundMarket
        let hasDuplicate = userPortfolioHoldings.contains { holding in
            guard holding.id != existingHolding.id else { return false }
            guard !holding.isArchived else { return false }
            guard holding.assetType == existingHolding.assetType else { return false }
            if existingHolding.assetType == .stock {
                guard holding.detectedMarket == market else { return false }
            } else {
                guard holding.detectedFundMarket == fundMarket else { return false }
            }
            return holding.normalizedFundCode.caseInsensitiveCompare(fundCode) == .orderedSame
        }
        guard !hasDuplicate else {
            errorMessage = "本地已经有同代码的\(existingHolding.assetType.displayName)持仓，请先合并或删除重复项。"
            return false
        }

        do {
            var nextHoldings = userPortfolioHoldings
            nextHoldings[existingIndex] = UserPortfolioHolding(
                id: existingHolding.id,
                fundCode: fundCode,
                assetType: existingHolding.assetType,
                units: units,
                costPrice: costPrice.map(normalizedCostPrice),
                displayName: normalizedOptionalName(displayNameText),
                stockMarket: market,
                fundMarket: fundMarket,
                isArchived: existingHolding.isArchived,
                archivedAt: existingHolding.archivedAt
            )
            userPortfolioHoldings = nextHoldings
            userPortfolioSnapshot = nil
            rebuildAssetRows()
            try portfolioStore.save(nextHoldings, to: portfolioFileURL)

            let itemText = normalizedOptionalName(displayNameText) ?? row.fundName
            noticeMessage = "已更新 \(itemText)（\(fundCode)）的持仓明细。"
            Task { try? await refreshUserPortfolio(updateNotice: false) }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func addPersonalAssetHolding(
        assetType: PersonalAssetType,
        codeText: String,
        unitsText: String,
        costPriceText: String,
        displayName: String?,
        stockMarket: StockMarket? = nil,
        fundMarket: FundMarket? = nil
    ) -> Bool {
        let fundCode = normalizedManualAssetCode(assetType: assetType, codeText: codeText)
        guard !fundCode.isEmpty else {
            errorMessage = "请输入\(assetType.displayName)代码。"
            return false
        }
        guard let units = decimalInputValue(unitsText), units > 0 else {
            errorMessage = "请输入大于 0 的份额。"
            return false
        }
        guard let costPrice = decimalInputValue(costPriceText), costPrice > 0 else {
            errorMessage = "请输入大于 0 的成本。"
            return false
        }
        guard let portfolioFileURL else {
            errorMessage = "应用数据目录还没准备好，暂时无法添加持仓。"
            return false
        }

        do {
            let normalizedDisplayName: String? = {
                let value = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return value.isEmpty ? nil : value
            }()
            let market = manualStockMarket(assetType: assetType, codeText: codeText) ?? stockMarket
            let resolvedFundMarket = manualFundMarket(assetType: assetType, codeText: codeText)
                ?? fundMarket
                ?? (assetType == .fund ? UserPortfolioHolding.detectFundMarket(from: fundCode) : nil)
            var nextHoldings = userPortfolioHoldings
            if let existingIndex = nextHoldings.firstIndex(where: {
                guard $0.assetType == assetType else { return false }
                if assetType == .stock, $0.detectedMarket != market { return false }
                if assetType == .fund, $0.detectedFundMarket != resolvedFundMarket { return false }
                return $0.normalizedFundCode.caseInsensitiveCompare(fundCode) == .orderedSame
            }) {
                let existing = nextHoldings[existingIndex]
                let nextUnits = existing.units + units
                let existingCostPrice = existing.costPrice ?? costPrice
                let nextCostPrice = ((existing.units * existingCostPrice) + (units * costPrice)) / nextUnits
                nextHoldings[existingIndex] = UserPortfolioHolding(
                    id: existing.id,
                    fundCode: existing.normalizedFundCode,
                    assetType: existing.assetType,
                    units: nextUnits,
                    costPrice: normalizedCostPrice(nextCostPrice),
                    displayName: normalizedDisplayName ?? existing.normalizedName,
                    stockMarket: existing.stockMarket ?? market,
                    fundMarket: existing.fundMarket ?? resolvedFundMarket,
                    isArchived: false,
                    archivedAt: nil
                )
            } else {
                nextHoldings.append(
                    UserPortfolioHolding(
                        fundCode: fundCode,
                        assetType: assetType,
                        units: units,
                        costPrice: costPrice,
                        displayName: normalizedDisplayName,
                        stockMarket: market,
                        fundMarket: resolvedFundMarket
                    )
                )
            }

            userPortfolioHoldings = nextHoldings
            userPortfolioSnapshot = nil
            rebuildAssetRows()
            try portfolioStore.save(nextHoldings, to: portfolioFileURL)

            let nameText = normalizedDisplayName.map { "\($0)（\(fundCode)）" } ?? fundCode
            let typeText = assetType == .stock
                ? (market?.displayName ?? assetType.displayName)
                : (resolvedFundMarket?.displayName ?? assetType.displayName)
            noticeMessage = "已添加\(typeText) \(nameText)，\(personalAssetDecimalText(units)) 份，成本 \(personalAssetDecimalText(costPrice))。"
            Task { try? await refreshUserPortfolio(updateNotice: false) }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func resolvePersonalAssetCode(_ codeText: String) async -> PersonalAssetCodeResolution? {
        let rawCode = normalizedManualAssetRawCode(codeText)
        guard !rawCode.isEmpty else { return nil }

        let fundCode = normalizedManualAssetCode(assetType: .fund, codeText: rawCode)
        let stockCode = normalizedManualAssetCode(assetType: .stock, codeText: rawCode)
        guard !fundCode.isEmpty || !stockCode.isEmpty else { return nil }
        let detectedFundMarket = UserPortfolioHolding.detectFundMarket(from: fundCode)

        if hasExplicitFundMarket(rawCode) || detectedFundMarket == .onExchange {
            let fundName = fundCode.isEmpty ? nil : await platformClient.resolveAssetName(assetType: .fund, code: fundCode)
            let stockName = detectedFundMarket == .onExchange && !stockCode.isEmpty
                ? await platformClient.resolveAssetName(assetType: .stock, code: stockCode)
                : nil
            return PersonalAssetCodeResolution(
                assetType: .fund,
                code: fundCode,
                displayName: normalizedOptionalName(fundName) ?? normalizedOptionalName(stockName),
                fundMarket: manualFundMarket(assetType: .fund, codeText: rawCode) ?? detectedFundMarket
            )
        }

        if hasExplicitStockMarket(rawCode) {
            let stockName = stockCode.isEmpty ? nil : await platformClient.resolveAssetName(assetType: .stock, code: stockCode)
            return PersonalAssetCodeResolution(
                assetType: .stock,
                code: stockCode,
                displayName: normalizedOptionalName(stockName),
                stockMarket: manualStockMarket(assetType: .stock, codeText: rawCode)
            )
        }

        async let fundNameTask = fundCode.isEmpty ? nil : platformClient.resolveAssetName(assetType: .fund, code: fundCode)
        async let stockNameTask = stockCode.isEmpty ? nil : platformClient.resolveAssetName(assetType: .stock, code: stockCode)
        let fundName = normalizedOptionalName(await fundNameTask)
        let stockName = normalizedOptionalName(await stockNameTask)

        switch (fundName, stockName) {
        case let (fundName?, nil):
            return PersonalAssetCodeResolution(assetType: .fund, code: fundCode, displayName: fundName, fundMarket: UserPortfolioHolding.detectFundMarket(from: fundCode))
        case let (nil, stockName?):
            return PersonalAssetCodeResolution(assetType: .stock, code: stockCode, displayName: stockName, stockMarket: manualStockMarket(assetType: .stock, codeText: rawCode))
        case let (fundName?, stockName?):
            if isLikelyStockCode(stockCode) {
                return PersonalAssetCodeResolution(assetType: .stock, code: stockCode, displayName: stockName, stockMarket: manualStockMarket(assetType: .stock, codeText: rawCode))
            }
            return PersonalAssetCodeResolution(assetType: .fund, code: fundCode, displayName: fundName, fundMarket: UserPortfolioHolding.detectFundMarket(from: fundCode))
        case (nil, nil):
            if isLikelyStockCode(stockCode) {
                return PersonalAssetCodeResolution(assetType: .stock, code: stockCode, displayName: nil, stockMarket: manualStockMarket(assetType: .stock, codeText: rawCode))
            }
            return PersonalAssetCodeResolution(assetType: .fund, code: fundCode, displayName: nil, fundMarket: UserPortfolioHolding.detectFundMarket(from: fundCode))
        }
    }

    @discardableResult
    func adjustPersonalAssetHoldingUnits(
        _ row: PersonalAssetAggregateRow,
        mode: PersonalAssetUnitAdjustmentMode,
        unitsText: String,
        unitNetValueText: String
    ) -> Bool {
        guard let units = decimalInputValue(unitsText), units > 0 else {
            errorMessage = "请输入大于 0 的份额。"
            return false
        }
        guard let unitNetValue = decimalInputValue(unitNetValueText), unitNetValue > 0 else {
            errorMessage = "请输入大于 0 的单位净值。"
            return false
        }
        guard let portfolioFileURL else {
            errorMessage = "应用数据目录还没准备好，暂时无法调整持仓份额。"
            return false
        }

        do {
            let existingHolding = row.rawHolding ?? row.holdingRow?.holding ?? (mode == .add ? row.archivedHolding : nil)
            let existingIndex = existingHolding.flatMap { holding in
                userPortfolioHoldings.firstIndex { $0.id == holding.id }
            }
            var nextHoldings = userPortfolioHoldings

            switch mode {
            case .add:
                if let existingHolding {
                    let oldUnits = existingHolding.units
                    let nextUnits = oldUnits + units
                    let existingCostPrice = existingHolding.costPrice ?? unitNetValue
                    let nextCostPrice = ((oldUnits * existingCostPrice) + (units * unitNetValue)) / nextUnits
                    let nextHolding = UserPortfolioHolding(
                        id: existingHolding.id,
                        fundCode: existingHolding.normalizedFundCode,
                        assetType: existingHolding.assetType,
                        units: nextUnits,
                        costPrice: normalizedCostPrice(nextCostPrice),
                        displayName: existingHolding.normalizedName ?? row.fundName,
                        stockMarket: existingHolding.stockMarket,
                        fundMarket: existingHolding.fundMarket,
                        isArchived: false,
                        archivedAt: nil
                    )
                    if let existingIndex {
                        nextHoldings[existingIndex] = nextHolding
                    } else {
                        nextHoldings.append(nextHolding)
                    }
                } else {
                    guard let fundCode = row.fundCode, !fundCode.isEmpty else {
                        errorMessage = "这个标的缺少代码，暂时无法新增持仓份额。"
                        return false
                    }
                    nextHoldings.append(
                        UserPortfolioHolding(
                            fundCode: fundCode,
                            assetType: row.assetType,
                            units: units,
                            costPrice: unitNetValue,
                            displayName: row.fundName,
                            stockMarket: row.detectedMarket,
                            fundMarket: row.detectedFundMarket
                        )
                    )
                }

            case .remove:
                guard let existingHolding, let existingIndex else {
                    errorMessage = "这个标的还没有已持有记录，无法删除份额。"
                    return false
                }
                guard units <= existingHolding.units + 0.0000001 else {
                    errorMessage = "删除份额不能超过当前份额 \(personalAssetDecimalText(existingHolding.units))。"
                    return false
                }

                let nextUnits = existingHolding.units - units
                if nextUnits <= 0.0000001 {
                    nextHoldings.remove(at: existingIndex)
                } else {
                    let nextCostPrice: Double?
                    if let costPrice = existingHolding.costPrice {
                        let nextCostValue = (existingHolding.units * costPrice) - (units * unitNetValue)
                        nextCostPrice = normalizedCostPrice(nextCostValue / nextUnits)
                    } else {
                        nextCostPrice = nil
                    }
                    nextHoldings[existingIndex] = UserPortfolioHolding(
                        id: existingHolding.id,
                        fundCode: existingHolding.normalizedFundCode,
                        assetType: existingHolding.assetType,
                        units: nextUnits,
                        costPrice: nextCostPrice,
                        displayName: existingHolding.normalizedName ?? row.fundName,
                        stockMarket: existingHolding.stockMarket,
                        fundMarket: existingHolding.fundMarket,
                        isArchived: false,
                        archivedAt: nil
                    )
                }
            }

            userPortfolioHoldings = nextHoldings
            userPortfolioSnapshot = nil
            rebuildAssetRows()
            if nextHoldings.isEmpty {
                try portfolioStore.delete(at: portfolioFileURL)
            } else {
                try portfolioStore.save(nextHoldings, to: portfolioFileURL)
            }

            let itemText = row.fundCode.map { "\(row.fundName)（\($0)）" } ?? row.fundName
            let actionText = mode == .add ? "添加" : "删除"
            noticeMessage = "已为 \(itemText) \(actionText) \(personalAssetDecimalText(units)) 份，单位净值 \(personalAssetDecimalText(unitNetValue))。"

            if !nextHoldings.isEmpty {
                Task { try? await refreshUserPortfolio(updateNotice: false) }
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func reloadPortfolioFromDisk() {
        loadSavedPortfolio()
        if userPortfolioHoldings.isEmpty {
            userPortfolioSnapshot = nil
            noticeMessage = "已从磁盘重载持仓，目前没有已保存内容。"
            Task { await applyPersonalAssetAutomation() }
            return
        }
        noticeMessage = "已从磁盘重载 \(userPortfolioHoldings.count) 条个人持仓。"
        Task {
            try? await refreshUserPortfolio(updateNotice: false)
            await applyPersonalAssetAutomation()
        }
    }

    func loadSavedPortfolio() {
        guard let portfolioFileURL else { return }
        do {
            let holdings = try portfolioStore.load(from: portfolioFileURL)
            userPortfolioHoldings = holdings
            rebuildAssetRows()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}
