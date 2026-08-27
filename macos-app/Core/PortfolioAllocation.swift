import Foundation

enum PortfolioAssetCategory: String, Codable, CaseIterable, Hashable, Identifiable {
    case offExchangeFund
    case onExchangeFund
    case aShareStock
    case hkStock
    case usStock
    case otherStock

    var id: Self { self }

    var displayName: String {
        switch self {
        case .offExchangeFund:
            return "场外基金"
        case .onExchangeFund:
            return "场内基金"
        case .aShareStock:
            return "A 股"
        case .hkStock:
            return "港股"
        case .usStock:
            return "美股"
        case .otherStock:
            return "其他股票"
        }
    }
}

struct PortfolioAssetDistributionItem: Hashable, Identifiable {
    let category: PortfolioAssetCategory
    let amount: Double
    /// 占当前组合有效敞口的比例，使用 0...100 百分数口径。
    let weightPct: Double
    let assetCount: Int

    var id: PortfolioAssetCategory { category }
}

struct PortfolioAssetDistributionSummary: Hashable {
    let totalExposure: Double
    let items: [PortfolioAssetDistributionItem]

    static func make(rows: [PersonalAssetAggregateRow]) -> PortfolioAssetDistributionSummary? {
        let exposedRows = rows.filter { $0.effectiveHoldingAmount > 0.001 }
        let totalExposure = exposedRows.reduce(0) { $0 + $1.effectiveHoldingAmount }
        guard totalExposure > 0 else { return nil }

        let grouped = Dictionary(grouping: exposedRows, by: category(for:))
        let items = grouped.compactMap { category, rows -> PortfolioAssetDistributionItem? in
            let amount = rows.reduce(0) { $0 + $1.effectiveHoldingAmount }
            guard amount > 0 else { return nil }
            return PortfolioAssetDistributionItem(
                category: category,
                amount: amount,
                weightPct: rounded(amount / totalExposure * 100),
                assetCount: rows.count
            )
        }
        .sorted {
            if abs($0.amount - $1.amount) > 0.001 {
                return $0.amount > $1.amount
            }
            return $0.category.rawValue < $1.category.rawValue
        }

        return PortfolioAssetDistributionSummary(
            totalExposure: totalExposure,
            items: items
        )
    }

    private static func category(for row: PersonalAssetAggregateRow) -> PortfolioAssetCategory {
        switch row.assetType {
        case .fund:
            return row.detectedFundMarket == .onExchange ? .onExchangeFund : .offExchangeFund
        case .stock:
            switch row.detectedMarket {
            case .aShare:
                return .aShareStock
            case .hk:
                return .hkStock
            case .us:
                return .usStock
            case nil:
                return .otherStock
            }
        }
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }
}

extension AppModel {
    var portfolioLookThroughRequestKey: String {
        personalAssetRows
            .filter { $0.effectiveHoldingAmount > 0.001 }
            .map {
                let cents = Int(($0.effectiveHoldingAmount * 100).rounded())
                return "\($0.key):\(cents)"
            }
            .sorted()
            .joined(separator: "|")
    }

    func refreshPortfolioLookThrough(force: Bool = false) async {
        let requestKey = portfolioLookThroughRequestKey
        let fundCodes = Array(
            Set(
                personalAssetRows.compactMap { row -> String? in
                    guard row.assetType == .fund,
                          row.effectiveHoldingAmount > 0.001,
                          let code = row.fundCode,
                          !code.isEmpty else {
                        return nil
                    }
                    return code
                }
            )
        ).sorted()

        guard !fundCodes.isEmpty else {
            portfolioLookThroughSnapshot = nil
            portfolioLookThroughSourceWarnings = []
            portfolioLookThroughLoadedRequestKey = requestKey
            isRefreshingPortfolioLookThrough = false
            refreshDecisionCases()
            return
        }
        guard force
                || portfolioLookThroughLoadedRequestKey != requestKey
                || portfolioLookThroughSnapshot == nil else {
            return
        }

        portfolioLookThroughLoadGeneration += 1
        let generation = portfolioLookThroughLoadGeneration
        isRefreshingPortfolioLookThrough = true
        defer {
            if portfolioLookThroughLoadGeneration == generation {
                isRefreshingPortfolioLookThrough = false
            }
        }

        let batch = await fundLookThroughClient.fetchDisclosures(fundCodes: fundCodes)
        guard !Task.isCancelled, portfolioLookThroughLoadGeneration == generation else {
            return
        }

        portfolioLookThroughSnapshot = PortfolioLookThroughCalculator.make(
            rows: personalAssetRows,
            disclosures: batch.disclosures,
            generatedAt: Self.timestampString()
        )
        portfolioLookThroughSourceWarnings = batch.warnings
        portfolioLookThroughLoadedRequestKey = requestKey
        // 持仓 + 穿透数据落地后评估决策事项（审计 A2/A3 接线点）
        refreshDecisionCases()
    }
}
