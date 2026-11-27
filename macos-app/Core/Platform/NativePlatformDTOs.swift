import Foundation

// MARK: - Preload orchestration

enum PreloadResult {
    case history(code: String, data: NativeFundHistory)
    case quote(code: String, data: NativeFundQuote)
}

// MARK: - Platform action intermediate DTOs

struct NativePlatformOrder {
    let adjustmentID: Int
    let side: String
    let label: String
    let fundCode: String
    let fundName: String
    let title: String
    let tradeUnit: Int
    let postPlanUnit: Int
    let strategyType: String
    let largeClass: String
    let nav: Double
    let navDate: String
    let buyDate: String
    let orderCountInAdjustment: Int
}

struct NativePlatformActionSeed {
    let actionKey: String
    let adjustmentID: Int
    let adjustmentTitle: String
    let title: String
    let actionTitle: String
    let fundName: String
    let fundCode: String
    let side: String
    let action: String
    let tradeUnit: Int
    let postPlanUnit: Int
    let createdAt: String
    let txnDate: String
    let createdTs: Int
    let txnTs: Int
    let articleURL: String
    let comment: String
    let strategyType: String
    let largeClass: String
    let buyDate: String
    let nav: Double
    let navDate: String
    let orderCountInAdjustment: Int
}

struct NativePlatformAdjustment {
    let adjustmentID: Int
    let title: String
    let createdTs: Int
    let txnTs: Int
    let orderCount: Int
}

// MARK: - Fund history / quote / estimate DTOs

struct NativeFundHistoryEntry {
    let date: String
    let dateKey: Int
    let nav: Double
    let ts: Int
    let changePct: Double?
}

struct NativeFundHistory {
    let fundCode: String
    let fundName: String
    let series: [NativeFundHistoryEntry]
}

struct NativeFundQuote {
    let fundCode: String
    let fundName: String
    let price: Double
    let priceTime: String
    let priceSource: String
    let priceSourceLabel: String
    let officialNav: Double?
    let officialNavDate: String
    let estimatePrice: Double?
    let estimateTime: String
    let estimateChangePct: Double?
    /// 估值可信度（由校准台账 RMSE 分档；未校准为 `.unknown`）。
    var estimateConfidence: FundEstimateConfidence?
    /// 估值来源标识（`FundEstimateSource.rawValue`）。
    var estimateSource: String?
    /// 误差带半宽（百分点），高/中可信时展示「±x%」。
    var estimateErrorBandPct: Double?
    /// 多源估值分歧是否显著。
    var hasEstimateDisagreement: Bool
    /// 穿透贡献明细（仅持仓穿透源）。
    var estimateContributors: [FundEstimateContribution]

    init(
        fundCode: String,
        fundName: String,
        price: Double,
        priceTime: String,
        priceSource: String,
        priceSourceLabel: String,
        officialNav: Double?,
        officialNavDate: String,
        estimatePrice: Double?,
        estimateTime: String,
        estimateChangePct: Double?,
        estimateConfidence: FundEstimateConfidence? = nil,
        estimateSource: String? = nil,
        estimateErrorBandPct: Double? = nil,
        hasEstimateDisagreement: Bool = false,
        estimateContributors: [FundEstimateContribution] = []
    ) {
        self.fundCode = fundCode
        self.fundName = fundName
        self.price = price
        self.priceTime = priceTime
        self.priceSource = priceSource
        self.priceSourceLabel = priceSourceLabel
        self.officialNav = officialNav
        self.officialNavDate = officialNavDate
        self.estimatePrice = estimatePrice
        self.estimateTime = estimateTime
        self.estimateChangePct = estimateChangePct
        self.estimateConfidence = estimateConfidence
        self.estimateSource = estimateSource
        self.estimateErrorBandPct = estimateErrorBandPct
        self.hasEstimateDisagreement = hasEstimateDisagreement
        self.estimateContributors = estimateContributors
    }

    static func empty(_ fundCode: String) -> NativeFundQuote {
        NativeFundQuote(
            fundCode: fundCode,
            fundName: "",
            price: 0,
            priceTime: "",
            priceSource: "",
            priceSourceLabel: "",
            officialNav: nil,
            officialNavDate: "",
            estimatePrice: nil,
            estimateTime: "",
            estimateChangePct: nil
        )
    }
}

struct NativeFundEstimate {
    let fundName: String
    let price: Double?
    let time: String
    let changePct: Double?
    let source: String
    let sourceLabel: String
}

struct NativeStockQuote {
    let stockCode: String
    let stockName: String
    let price: Double
    let priceTime: String
    let priceSource: String
    let priceSourceLabel: String
    let previousClose: Double?
    let changePct: Double?

    var hasUsableData: Bool {
        price > 0 || !stockName.isEmpty
    }

    static func empty(_ stockCode: String) -> NativeStockQuote {
        NativeStockQuote(
            stockCode: stockCode,
            stockName: "",
            price: 0,
            priceTime: "",
            priceSource: "",
            priceSourceLabel: "",
            previousClose: nil,
            changePct: nil
        )
    }
}

struct NativeUserPortfolioPricePayload {
    let assetName: String
    let currentPrice: Double?
    let priceTime: String
    let priceSource: String
    let officialNav: Double?
    let officialNavDate: String
    let estimatePrice: Double?
    let estimatePriceTime: String
    let estimateChangePct: Double?
    var estimateConfidence: FundEstimateConfidence?
    var estimateSource: String?
    var estimateErrorBandPct: Double?
    var hasEstimateDisagreement: Bool
    var estimateContributors: [FundEstimateContribution]

    init(
        assetName: String,
        currentPrice: Double?,
        priceTime: String,
        priceSource: String,
        officialNav: Double?,
        officialNavDate: String,
        estimatePrice: Double?,
        estimatePriceTime: String,
        estimateChangePct: Double?,
        estimateConfidence: FundEstimateConfidence? = nil,
        estimateSource: String? = nil,
        estimateErrorBandPct: Double? = nil,
        hasEstimateDisagreement: Bool = false,
        estimateContributors: [FundEstimateContribution] = []
    ) {
        self.assetName = assetName
        self.currentPrice = currentPrice
        self.priceTime = priceTime
        self.priceSource = priceSource
        self.officialNav = officialNav
        self.officialNavDate = officialNavDate
        self.estimatePrice = estimatePrice
        self.estimatePriceTime = estimatePriceTime
        self.estimateChangePct = estimateChangePct
        self.estimateConfidence = estimateConfidence
        self.estimateSource = estimateSource
        self.estimateErrorBandPct = estimateErrorBandPct
        self.hasEstimateDisagreement = hasEstimateDisagreement
        self.estimateContributors = estimateContributors
    }
}
