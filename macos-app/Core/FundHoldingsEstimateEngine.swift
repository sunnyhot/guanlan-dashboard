import Foundation

// MARK: - 基金穿透估值（持仓 × 实时行情）

/// 持仓/行业权重到可交易代理标的的映射。
///
/// 基金定期报告披露的行业配置是双轨的：A 股部分按证监会门类（「制造业」「金融业」…），
/// 港美股部分按 GICS（「非必需消费品」「电信服务」…）。本表把两类名称映射到
/// 有实时行情、且成分相近的指数或 ETF，用于估算未披露部分的日内涨跌。
enum FundEstimateProxyMap {
    /// 代理标的：`symbol` 为腾讯行情代码（sh/sz 前缀），`label` 供 UI 展示。
    struct Proxy: Hashable, Sendable {
        let symbol: String
        let label: String
    }

    /// 证监会门类 → A 股行业/宽基指数。门类过粗时（如「制造业」占净值 40%+）退回宽基，
    /// 避免用窄基指数误导。
    static let csrcIndustryProxies: [String: Proxy] = [
        "A": Proxy(symbol: "sz399997", label: "中证农业"),
        "B": Proxy(symbol: "sz399998", label: "中证煤炭"),
        "C": Proxy(symbol: "sh000300", label: "沪深300"),
        "D": Proxy(symbol: "sh000011", label: "上证公用"),
        "E": Proxy(symbol: "sz399995", label: "基建工程"),
        "F": Proxy(symbol: "sh000993", label: "全指可选"),
        "G": Proxy(symbol: "sz399997", label: "中证交运"),
        "I": Proxy(symbol: "sz399997", label: "中证信息"),
        "J": Proxy(symbol: "sh000992", label: "全指金融"),
        "K": Proxy(symbol: "sh000006", label: "上证地产"),
        "L": Proxy(symbol: "sh000300", label: "沪深300"),
        "M": Proxy(symbol: "sh000300", label: "沪深300"),
        "N": Proxy(symbol: "sh000300", label: "沪深300"),
        "O": Proxy(symbol: "sh000300", label: "沪深300"),
        "P": Proxy(symbol: "sh000300", label: "沪深300"),
        "Q": Proxy(symbol: "sh000300", label: "沪深300"),
        "R": Proxy(symbol: "sh000300", label: "沪深300"),
        "S": Proxy(symbol: "sh000300", label: "沪深300"),
    ]

    /// 证监会门类中文名 → 门类代码（报告里的名称形如「制造业」「金融业」）。
    static let csrcNameToCode: [String: String] = [
        "农、林、牧、渔业": "A",
        "采矿业": "B",
        "制造业": "C",
        "电力、热力、燃气及水生产和供应业": "D",
        "建筑业": "E",
        "批发和零售业": "F",
        "交通运输、仓储和邮政业": "G",
        "住宿和餐饮业": "H",
        "信息传输、软件和信息技术服务业": "I",
        "金融业": "J",
        "房地产业": "K",
        "租赁和商务服务业": "L",
        "科学研究和技术服务业": "M",
        "水利、环境和公共设施管理业": "N",
        "居民服务、修理和其他服务业": "O",
        "教育": "P",
        "卫生和社会工作": "Q",
        "文化、体育和娱乐业": "R",
        "综合": "S",
    ]

    /// GICS 行业 → 跨境 ETF / 指数。用于港美股仓位（A 股盘中时港美股状态不同，
    /// 腾讯行情对港股为实时、对美股为前收，`FundHoldingsEstimateEngine` 会按报价新鲜度处理）。
    static let gicsProxies: [String: Proxy] = [
        "能源": Proxy(symbol: "sh513350", label: "油气ETF"),
        "材料": Proxy(symbol: "sh513350", label: "标普油气"),
        "工业": Proxy(symbol: "sh513500", label: "标普500"),
        "资本货物": Proxy(symbol: "sh513500", label: "标普500"),
        "商业和专业服务": Proxy(symbol: "sh513500", label: "标普500"),
        "运输": Proxy(symbol: "sh513500", label: "标普500"),
        "非必需消费品": Proxy(symbol: "sh513050", label: "中概互联"),
        "消费者服务": Proxy(symbol: "sh513050", label: "中概互联"),
        "耐用消费品和服装": Proxy(symbol: "sh513050", label: "中概互联"),
        "消费者服务行业": Proxy(symbol: "sh513050", label: "中概互联"),
        "汽车与汽车零部件": Proxy(symbol: "sh513050", label: "中概互联"),
        "必需消费品": Proxy(symbol: "sh513050", label: "中概互联"),
        "食品、饮料与烟草": Proxy(symbol: "sh513050", label: "中概互联"),
        "食品与主要用品零售": Proxy(symbol: "sh513050", label: "中概互联"),
        "家庭与个人用品": Proxy(symbol: "sh513050", label: "中概互联"),
        "保健": Proxy(symbol: "sh513120", label: "港股创新药"),
        "医疗保健设备与服务": Proxy(symbol: "sh513120", label: "港股创新药"),
        "制药、生物科技与生命科学": Proxy(symbol: "sh513120", label: "港股创新药"),
        "金融": Proxy(symbol: "sh513050", label: "中概互联"),
        "银行": Proxy(symbol: "sh513050", label: "中概互联"),
        "多元金融": Proxy(symbol: "sh513050", label: "中概互联"),
        "保险": Proxy(symbol: "sh513050", label: "中概互联"),
        "房地产": Proxy(symbol: "sh513050", label: "中概互联"),
        "信息技术": Proxy(symbol: "sh513130", label: "恒生科技"),
        "软件与服务": Proxy(symbol: "sh513130", label: "恒生科技"),
        "技术硬件与设备": Proxy(symbol: "sh513130", label: "恒生科技"),
        "半导体与半导体生产设备": Proxy(symbol: "sh513130", label: "恒生科技"),
        "电信服务": Proxy(symbol: "sh513130", label: "恒生科技"),
        "电信业务": Proxy(symbol: "sh513130", label: "恒生科技"),
        "媒体与娱乐": Proxy(symbol: "sh513130", label: "恒生科技"),
        "公用事业": Proxy(symbol: "sh513500", label: "标普500"),
        "原材料": Proxy(symbol: "sh513350", label: "标普油气"),
    ]

    /// GICS 一级行业中文名（简写形式）→ 代理。
    static let gicsTopLevelNames: Set<String> = [
        "能源", "材料", "工业", "非必需消费品", "必需消费品", "保健", "金融",
        "信息技术", "电信服务", "公用事业", "房地产",
    ]

    static func proxy(forIndustryName name: String) -> Proxy? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let code = csrcNameToCode[trimmed], let proxy = csrcIndustryProxies[code] {
            return proxy
        }
        if let proxy = gicsProxies[trimmed] {
            return proxy
        }
        // 宽松匹配：报告里的名称可能带后缀或空格差异。
        for (key, proxy) in gicsProxies where trimmed.contains(key) || key.contains(trimmed) {
            return proxy
        }
        for (key, code) in csrcNameToCode where trimmed.contains(key) || key.contains(trimmed) {
            if let proxy = csrcIndustryProxies[code] { return proxy }
        }
        return nil
    }
}

/// 单只基金的穿透估值输入：披露持仓/行业/资产配置 + 各代理标的的实时涨跌。
struct FundHoldingsEstimateInput {
    let fundCode: String
    let holdings: [FundUnderlyingHolding]
    let industries: [FundIndustryExposure]
    let assetAllocation: FundAssetAllocation?
    /// 披露截止日期（yyyy-MM-dd），用于陈旧降级。
    let asOf: String
    /// 个股实时涨幅（百分数），key 为归一化代码（A股 6 位、港股 HK00700、美股大写）。
    let stockChangePcts: [String: Double]
    /// 代理标的实时涨幅（百分数），key 为腾讯 symbol。
    let proxyChangePcts: [String: Double]
    /// 债券代理涨幅（百分数），nil 表示不可用。
    let bondProxyChangePct: Double?
}

/// 穿透估值结果。
struct FundHoldingsEstimateResult {
    /// 估算日内涨幅（百分数）。
    let changePct: Double
    /// 估算净值 = 官方净值 × (1 + changePct/100)。
    let estimatedNav: Double
    /// 已精确计算的权重（百分数）。
    let coveredWeightPct: Double
    /// 用行业代理填充的权重。
    let proxiedWeightPct: Double
    /// 既无行情又无代理的权重（按 0 处理）。
    let unmodeledWeightPct: Double
    /// 现金/债券权重。
    let cashAndBondWeightPct: Double
    /// 持仓披露是否陈旧（超过 `staleAfterDays`）。
    let isStale: Bool
    /// 主要贡献（代码、名称、权重、贡献百分点），按绝对贡献降序，最多 10 条。
    let topContributors: [FundEstimateContribution]

    var coveragePct: Double {
        coveredWeightPct + proxiedWeightPct
    }

    /// 内在可信度：按精确覆盖率和陈旧度打分，0...1。
    var intrinsicConfidence: Double {
        var score = min(1.0, coveredWeightPct / 100 * 1.6)
        score += min(0.3, proxiedWeightPct / 100 * 0.3)
        if isStale { score *= 0.6 }
        return max(0, min(1.0, score))
    }
}

struct FundEstimateContribution: Hashable, Sendable {
    let code: String
    let name: String
    let weightPct: Double
    let changePct: Double
    /// 对基金净值的贡献（百分点）= 权重% × 涨幅% / 100。
    let contributionPct: Double
}

/// 持仓穿透估值器：纯计算，无网络。
///
/// 公式：
/// ```
/// 估算涨幅 = Σ(个股权重ᵢ × 个股涨幅ᵢ)/100          ← 已披露且有行情
///          + Σ(未覆盖行业权重ⱼ × 代理涨幅ⱼ)/100       ← 行业配置填充剩余股票仓位
///          + 债券权重 × 债券代理涨幅/100 + 现金 × 0
/// ```
/// 未披露股票仓位按行业配置比例摊到代理指数；行业配置也不覆盖的部分退回宽基（沪深300）。
enum FundHoldingsEstimateEngine {
    /// 披露超过该天数视为陈旧，权重打折。
    static let staleAfterDays = 120
    /// 没有任何行业/代理可用时的最终兜底。
    static let fallbackProxy = FundEstimateProxyMap.Proxy(symbol: "sh000300", label: "沪深300")
    static let maximumContributors = 10

    static func estimate(
        input: FundHoldingsEstimateInput,
        officialNav: Double,
        now: Date = Date()
    ) -> FundHoldingsEstimateResult? {
        guard officialNav > 0, officialNav.isFinite else { return nil }

        let allocation = input.assetAllocation
        let stockPct = allocation?.stockPct
        let bondPct = allocation?.bondPct
        let cashPct = allocation?.cashPct

        var covered = 0.0
        var proxied = 0.0
        var contributionSum = 0.0
        var contributors: [FundEstimateContribution] = []
        var unmappedIndustries: [FundIndustryExposure] = []

        // 1. 已披露个股：有行情则精确计入。
        var holdingsWeight = 0.0
        for holding in input.holdings where holding.kind == .stock {
            holdingsWeight += max(0, holding.weightPct)
            guard let change = input.stockChangePcts[Self.normalizedStockKey(holding.code)],
                  change.isFinite, abs(change) <= 50 else {
                continue
            }
            let weight = max(0, holding.weightPct)
            let contribution = weight * change / 100
            contributionSum += contribution
            covered += weight
            contributors.append(
                FundEstimateContribution(
                    code: holding.code,
                    name: holding.name,
                    weightPct: weight,
                    changePct: change,
                    contributionPct: contribution
                )
            )
        }

        // 2. 债券持仓：按债券代理计。
        var bondWeight = 0.0
        for holding in input.holdings where holding.kind == .bond {
            bondWeight += max(0, holding.weightPct)
        }

        // 3. 确定股票总仓位：优先资产配置，否则用「已披露股票 + 行业配置合计」上界。
        let industryTotal = input.industries.reduce(0) { $0 + max(0, $1.weightPct) }
        let disclosedStockTotal = max(holdingsWeight, industryTotal)
        let effectiveStockPct = min(100, max(stockPct ?? 0, disclosedStockTotal))
        let remainingStockPct = max(0, effectiveStockPct - holdingsWeight)

        // 4. 剩余股票仓位按行业配置摊（行业配置通常已含前十大，这里用其相对比例分摊剩余）。
        let industryByProxy = Self.aggregateIndustries(input.industries)
        let mappedIndustryTotal = industryByProxy.values.reduce(0, +)
        if remainingStockPct > 0, mappedIndustryTotal > 0 {
            for (proxy, weight) in industryByProxy {
                guard let change = input.proxyChangePcts[proxy.symbol], change.isFinite, abs(change) <= 30 else {
                    unmappedIndustries.append(
                        FundIndustryExposure(name: proxy.label, weightPct: weight, disclosureDate: input.asOf)
                    )
                    continue
                }
                let allocated = remainingStockPct * weight / mappedIndustryTotal
                let contribution = allocated * change / 100
                contributionSum += contribution
                proxied += allocated
                contributors.append(
                    FundEstimateContribution(
                        code: proxy.symbol,
                        name: proxy.label,
                        weightPct: allocated,
                        changePct: change,
                        contributionPct: contribution
                    )
                )
            }
            // 行业代理无行情的部分退回宽基。
            let unmappedWeight = unmappedIndustries.reduce(0) { $0 + $1.weightPct }
            if unmappedWeight > 0, let fallback = input.proxyChangePcts[fallbackProxy.symbol],
               fallback.isFinite, abs(fallback) <= 30 {
                let allocated = remainingStockPct * unmappedWeight / mappedIndustryTotal
                contributionSum += allocated * fallback / 100
                proxied += allocated
            }
        } else if remainingStockPct > 0, let fallback = input.proxyChangePcts[fallbackProxy.symbol],
                  fallback.isFinite, abs(fallback) <= 30 {
            // 无行业配置：整体退回宽基。
            contributionSum += remainingStockPct * fallback / 100
            proxied += remainingStockPct
        }

        // 5. 债券 + 现金。
        let effectiveBondPct = min(100, max(bondPct ?? 0, bondWeight))
        if effectiveBondPct > 0, let bondChange = input.bondProxyChangePct, bondChange.isFinite {
            contributionSum += effectiveBondPct * bondChange / 100
            proxied += effectiveBondPct
        }
        let effectiveCashPct = max(0, min(100, cashPct ?? 0))

        // 6. 陈旧降级：披露过旧时，把估算向宽基回归（降低个股权重，提高代理权重）。
        let stale = Self.isStale(asOf: input.asOf, now: now)
        let unmodeled = max(0, 100 - covered - proxied - effectiveCashPct)
        var finalChange = contributionSum
        if stale, let fallback = input.proxyChangePcts[fallbackProxy.symbol], fallback.isFinite {
            let shrink = 0.7
            finalChange = contributionSum * shrink + (fallback * effectiveStockPct / 100) * (1 - shrink)
        }

        let result = FundHoldingsEstimateResult(
            changePct: finalChange,
            estimatedNav: officialNav * (1 + finalChange / 100),
            coveredWeightPct: covered,
            proxiedWeightPct: proxied,
            unmodeledWeightPct: unmodeled,
            cashAndBondWeightPct: effectiveCashPct + effectiveBondPct,
            isStale: stale,
            topContributors: Array(
                contributors
                    .sorted { abs($0.contributionPct) > abs($1.contributionPct) }
                    .prefix(Self.maximumContributors)
            )
        )
        return result
    }

    /// 把行业暴露按代理标的聚合（多个行业映射到同一代理时合并权重）。
    static func aggregateIndustries(_ industries: [FundIndustryExposure]) -> [FundEstimateProxyMap.Proxy: Double] {
        var byProxy: [FundEstimateProxyMap.Proxy: Double] = [:]
        for industry in industries where industry.weightPct > 0 {
            guard let proxy = FundEstimateProxyMap.proxy(forIndustryName: industry.name) else { continue }
            byProxy[proxy, default: 0] += industry.weightPct
        }
        return byProxy
    }

    /// 个股代码归一化：与 `MarketQuote.code` 口径一致（A股 6 位、港股 HK00700、美股大写）。
    static func normalizedStockKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return "" }
        // 港股：5 位数字或 "HK00700" / "00700.HK"
        if trimmed.hasPrefix("HK") {
            return "HK" + trimmed.dropFirst(2).prefix(5)
        }
        if trimmed.hasSuffix(".HK") {
            return "HK" + trimmed.dropLast(3).prefix(5)
        }
        // 美股：含字母且非 A 股格式
        if trimmed.range(of: #"^[A-Z]{1,5}$"#, options: .regularExpression) != nil {
            return trimmed
        }
        // A 股：6 位数字
        if trimmed.range(of: #"^\d{6}$"#, options: .regularExpression) != nil {
            return trimmed
        }
        if let match = trimmed.range(of: #"\d{6}"#, options: .regularExpression) {
            return String(trimmed[match])
        }
        return trimmed
    }

    static func isStale(asOf: String, now: Date) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: String(asOf.prefix(10))) else {
            return false
        }
        let today = formatter.calendar.startOfDay(for: now)
        guard let days = formatter.calendar.dateComponents([.day], from: date, to: today).day else {
            return false
        }
        return days > staleAfterDays
    }
}
