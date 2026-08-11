import Foundation

// MARK: - 基础枚举（Identity 层用到的市场 / 资产类别 / 货币）

/// 交易所 / 市场标识。对应 ADR-DATA001 Listing 层的「在哪挂牌」。
enum Exchange: String, Sendable, Codable, Hashable, CaseIterable {
    case sse = "SSE"        // 上海证券交易所
    case szse = "SZSE"      // 深圳证券交易所
    case hkex = "HKEX"      // 港交所
    case nyse = "NYSE"      // 纽约证券交易所
    case nasdaq = "NASDAQ"  // 纳斯达克
    case amex = "AMEX"      // 美国证券交易所
    /// OTC / 场外（如部分基金、ADR）
    case otc = "OTC"
    /// 平台内部挂牌（如且慢 prodCode 不是真交易所，是平台内部标识）
    case platform = "PLATFORM"

    /// 该交易所所在法域，用于推断货币与节假日。
    var jurisdiction: Jurisdiction {
        switch self {
        case .sse, .szse: return .chinaMainland
        case .hkex: return .hongKong
        case .nyse, .nasdaq, .amex, .otc: return .unitedStates
        case .platform: return .platform
        }
    }
}

/// 法域（用于推断货币、交易日历）。
enum Jurisdiction: String, Sendable, Codable, Hashable {
    case chinaMainland = "CN"
    case hongKong = "HK"
    case unitedStates = "US"
    case platform = "PLATFORM"
}

/// ISO 4217 货币码。所有 Canonical 价格 / 市值 / NAV 都带 currency（ADR-DATA003）。
enum Currency: String, Sendable, Codable, Hashable {
    case cny = "CNY"
    case hkd = "HKD"
    case usd = "USD"
}

/// 资产大类（用于 Exposure / Strategic Target 配置）。
enum AssetClass: String, Sendable, Codable, Hashable, CaseIterable {
    case equity = "EQUITY"
    case fixedIncome = "FIXED_INCOME"
    case commodity = "COMMODITY"
    case cash = "CASH"
    case alternative = "ALTERNATIVE"
}

/// 抽象金融工具的合约类型（ADR-DATA001 Instrument 层）。
enum InstrumentKind: String, Sendable, Codable, Hashable {
    case stock = "STOCK"
    case fund = "FUND"                 // 公募 / 私募基金（抽象产品，份额类另建）
    case exchangeTradedFund = "ETF"
    case index = "INDEX"               // 指数本身（与跟踪它的 ETF 区分）
    case bond = "BOND"
    case moneyMarketFund = "MMF"
    case alternative = "ALTERNATIVE"
}

// MARK: - 五层 Identity 实体（ADR-DATA001 §7-11）

/// 第 1 层：法律实体（基金管理人 / 上市公司发行人）。
///
/// LegalEntity 是「谁发行 / 管理」的语义锚点，跨多个 Instrument 共享。
/// 例如：易方达基金管理易方达蓝筹精选（基金）、茅台是贵州茅台股份有限公司（股票）。
struct LegalEntity: Sendable, Codable, Hashable {
    let id: LegalEntityID
    /// 显示名（可改，ID 不变；不用于业务判断）
    let displayName: String
    /// 法域（用于推断披露规则）
    let jurisdiction: Jurisdiction
    /// 实体类型
    let kind: Kind

    enum Kind: String, Sendable, Codable, Hashable {
        case fundManager = "FUND_MANAGER"
        case listedCompany = "LISTED_COMPANY"
        case indexPublisher = "INDEX_PUBLISHER"
        case other = "OTHER"
    }

    /// 监管唯一标识（可选，中国证监会基金号 / 美国 CIK / ISIN issuer 等）
    let regulatoryIDs: [RegulatoryID]

    init(
        id: LegalEntityID,
        displayName: String,
        jurisdiction: Jurisdiction,
        kind: Kind,
        regulatoryIDs: [RegulatoryID] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.jurisdiction = jurisdiction
        self.kind = kind
        self.regulatoryIDs = regulatoryIDs
    }
}

/// 监管唯一标识（LegalEntity / Instrument / Listing 都可能有）。
struct RegulatoryID: Sendable, Codable, Hashable {
    /// 标识体系（如 CIK、CSRC_FUND_CODE、ISIN_ISSUER）
    let scheme: String
    /// 实际值
    let value: String
}

/// 第 2 层：抽象金融工具（一只基金 / 一只指数 / 一只股票的「合约」）。
///
/// Instrument 与 Listing 是一对多：同一只股票可在沪深港三地挂牌，
/// 同一只指数可被多个 ETF 跟踪。业务计算（Factor / Risk）通常锚定 Instrument。
struct Instrument: Sendable, Codable, Hashable {
    let id: InstrumentID
    /// 发行 / 管理方
    let issuerID: LegalEntityID
    /// 工具类型
    let kind: InstrumentKind
    /// 显示名
    let displayName: String
    /// 主货币（用于推断价格货币、分红货币）
    let baseCurrency: Currency
    /// 资产大类（Strategic Target 配置维度）
    let assetClass: AssetClass
    /// ISIN（可选，全局唯一标识）
    let isin: String?

    init(
        id: InstrumentID,
        issuerID: LegalEntityID,
        kind: InstrumentKind,
        displayName: String,
        baseCurrency: Currency,
        assetClass: AssetClass,
        isin: String? = nil
    ) {
        self.id = id
        self.issuerID = issuerID
        self.kind = kind
        self.displayName = displayName
        self.baseCurrency = baseCurrency
        self.assetClass = assetClass
        self.isin = isin
    }
}

/// 第 3 层：挂牌（某交易所 / 平台的具体挂牌）。
///
/// Listing 是「在哪交易 / 在哪查代码」的语义。Provider 原始代码通过
/// IdentityResolver 映射到 Listing（ADR-DATA001 §13）。
struct Listing: Sendable, Codable, Hashable {
    let id: ListingID
    /// 所属 Instrument（多挂牌共享同一 Instrument）
    let instrumentID: InstrumentID
    /// 交易所 / 市场
    let exchange: Exchange
    /// 该交易所内的代码（如 600519、AAPL）
    let symbol: String
    /// 该 listing 的交易货币（跨市场挂牌可能不同货币，如 ADR 用 USD）
    let tradingCurrency: Currency
    /// 是否仍活跃挂牌（退市 / 合并后变 false，但 Listing ID 不删除）
    let isActive: Bool

    init(
        id: ListingID,
        instrumentID: InstrumentID,
        exchange: Exchange,
        symbol: String,
        tradingCurrency: Currency,
        isActive: Bool = true
    ) {
        self.id = id
        self.instrumentID = instrumentID
        self.exchange = exchange
        self.symbol = symbol
        self.tradingCurrency = tradingCurrency
        self.isActive = isActive
    }
}

/// 第 4 层：基金产品（含 A/C 类聚合）。
///
/// FundProduct 是「这只基金产品」的抽象，FundShareClass 是「这只基金的 A/C 类」。
/// 业务计算通常锚定 FundShareClass（不同份额费用结构、收益不同）。
struct FundProduct: Sendable, Codable, Hashable {
    let id: FundProductID
    /// 对应的 Instrument（kind = fund / ETF / MMF）
    let instrumentID: InstrumentID
    /// 基金类型
    let fundType: FundType
    /// 显示名（产品级）
    let displayName: String
    /// 主代销代码（仅用于显示，业务用 ID）
    let primaryCode: String?

    enum FundType: String, Sendable, Codable, Hashable {
        case openEnd = "OPEN_END"          // 开放式
        case closedEnd = "CLOSED_END"       // 封闭式
        case etf = "ETF"
        case lof = "LOF"
        case qdii = "QDII"
        case moneyMarket = "MMF"
    }

    init(
        id: FundProductID,
        instrumentID: InstrumentID,
        fundType: FundType,
        displayName: String,
        primaryCode: String? = nil
    ) {
        self.id = id
        self.instrumentID = instrumentID
        self.fundType = fundType
        self.displayName = displayName
        self.primaryCode = primaryCode
    }
}

/// 基金份额类别（A 类、C 类独立）。
///
/// 同一 FundProduct 的不同份额类别有不同费率结构（前端收费 / 后端收费 / 销售服务费），
/// 长期收益不同。业务计算（NAV、归因、风险）必须锚定 FundShareClass。
struct FundShareClass: Sendable, Codable, Hashable {
    let id: FundShareClassID
    /// 所属基金产品
    let productID: FundProductID
    /// 对应的 Instrument（份额类别本身也是一个可交易 instrument）
    let instrumentID: InstrumentID
    /// 份额类别标识（A / C / I / R 等）
    let shareClassCode: String
    /// 显示名（含份额后缀，如「易方达蓝筹精选 A」）
    let displayName: String
    /// 费率结构
    let feeStructure: FeeStructure
    /// 该份额类别的官方代码（如天天基金 6 位码、且慢 prodCode）
    let officialCodes: [OfficialCode]

    /// 费率结构（区分 A/C 类的核心）。
    struct FeeStructure: Sendable, Codable, Hashable {
        /// 前端申购费（A 类常见，C 类通常 0）
        let frontEndLoad: Decimal?
        /// 后端赎回费（持有期递减）
        let backEndLoad: Decimal?
        /// 年销售服务费（C 类常见，A 类通常 0）
        let annualSalesFee: Decimal?
        /// 年管理费
        let managementFee: Decimal?
        /// 年托管费
        let custodyFee: Decimal?
    }

    /// 官方代码（集中声明，用于 IdentityResolver 映射）。
    struct OfficialCode: Sendable, Codable, Hashable {
        /// 代码体系（如 "eastmoney_6digit"、"qieman_prodCode"、"csrc_fund_code"）
        let scheme: String
        let value: String
    }

    init(
        id: FundShareClassID,
        productID: FundProductID,
        instrumentID: InstrumentID,
        shareClassCode: String,
        displayName: String,
        feeStructure: FeeStructure,
        officialCodes: [OfficialCode]
    ) {
        self.id = id
        self.productID = productID
        self.instrumentID = instrumentID
        self.shareClassCode = shareClassCode
        self.displayName = displayName
        self.feeStructure = feeStructure
        self.officialCodes = officialCodes
    }
}
