import Foundation

// MARK: - 基金概况：跟踪标的 / 基金类型

/// 从天天基金 `jbgk_{code}.html` 解析出的基金概况字段，用于把指数基金映射到真实跟踪标的。
struct FundProfileSummary: Codable, Hashable, Sendable {
    /// 基金类型原文，如「指数型-股票」「联接基金-股票」「QDII」「混合型-偏股」。
    let fundType: String
    /// 跟踪标的原文，如「沪深300指数」「中证500指数」「纳斯达克100指数」。
    let trackingTarget: String?
    /// 业绩比较基准原文。
    let benchmark: String?

    /// 是否指数型（含 ETF 联接）。
    var isIndexFund: Bool {
        fundType.contains("指数")
    }

    /// 是否 ETF 联接基金（类型原文含「联接」）。
    var isETFFeeder: Bool {
        fundType.contains("联接")
    }
}

/// 指数基金跟踪标的解析器。
enum FundProfileParser {
    /// 解析 `jbgk` 页面 HTML，抽取基金类型 / 跟踪标的 / 业绩比较基准。
    /// 页面结构：<th>基金类型</th><td>指数型-股票</td> ... 表格行形式。
    static func parse(_ html: String) -> FundProfileSummary? {
        let typeText = extractRowValue(html, label: "基金类型")
        guard let typeText, !typeText.isEmpty else { return nil }
        return FundProfileSummary(
            fundType: typeText,
            trackingTarget: extractRowValue(html, label: "跟踪标的"),
            benchmark: extractRowValue(html, label: "业绩比较基准")
        )
    }

    /// 取 `<th>label</th><td>value</td>` 或 `<th>label</th>\n<td>value` 的 value 文本。
    private static func extractRowValue(_ html: String, label: String) -> String? {
        // 先定位 label 出现位置，再取其后第一个 <td>...</td>。
        guard let labelRange = html.range(of: label) else { return nil }
        let tail = html[labelRange.upperBound...]
        guard let tdOpen = tail.range(of: "<td"),
              let tagEnd = tail[tdOpen.upperBound...].firstIndex(of: ">"),
              let tdClose = tail[tagEnd...].range(of: "</td>") else {
            return nil
        }
        let inner = tail[tail.index(after: tagEnd)..<tdClose.lowerBound]
        let text = stripTags(String(inner))
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// 去掉 HTML 标签并解码常见实体（仅处理概况页用到的子集）。
    private static func stripTags(_ value: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"<[^>]+>"#)
        let range = NSRange(value.startIndex..., in: value)
        let stripped = regex.stringByReplacingMatches(in: value, range: range, withTemplate: "")
        return stripped
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}

/// 指数名称 → 可交易代理（腾讯 symbol）。用于指数基金 / ETF 联接的实时估值：
/// 估算涨幅 ≈ 跟踪指数涨幅（ETF 联接另有约 5% 现金拖累，`cashDragPct` 处理）。
enum FundTrackingIndexMap {
    struct Target: Hashable, Sendable {
        /// 腾讯行情 symbol（指数用 sh000xxx / sz399xxx，ETF 用 sh51xxxx / sz15xxxx）。
        let symbol: String
        let label: String
        /// 该品种的现金拖累（百分数）。ETF 联接约 5%，普通指数基金约 5%，ETF 本体 0。
        let cashDragPct: Double
    }

    /// 精确匹配表（跟踪标的原文 → 代理）。顺序即优先级，先精确后宽松。
    static let exact: [String: Target] = [
        // —— 宽基（腾讯指数代码已逐一验证返回名称）——
        "沪深300指数": Target(symbol: "sh000300", label: "沪深300", cashDragPct: 5),
        "沪深300": Target(symbol: "sh000300", label: "沪深300", cashDragPct: 5),
        "上证50指数": Target(symbol: "sh000016", label: "上证50", cashDragPct: 5),
        "中证500指数": Target(symbol: "sh000905", label: "中证500", cashDragPct: 5),
        "中证500": Target(symbol: "sh000905", label: "中证500", cashDragPct: 5),
        "中证1000指数": Target(symbol: "sh000852", label: "中证1000", cashDragPct: 5),
        "中证A500指数": Target(symbol: "sh000510", label: "中证A500", cashDragPct: 5),
        "中证A500": Target(symbol: "sh000510", label: "中证A500", cashDragPct: 5),
        "中证2000指数": Target(symbol: "sz159531", label: "中证2000ETF", cashDragPct: 5),
        "中证2000": Target(symbol: "sz159531", label: "中证2000ETF", cashDragPct: 5),
        "北证50指数": Target(symbol: "bj899050", label: "北证50", cashDragPct: 5),
        "北证50": Target(symbol: "bj899050", label: "北证50", cashDragPct: 5),
        "中证800指数": Target(symbol: "sh000906", label: "中证800", cashDragPct: 5),
        "上证指数": Target(symbol: "sh000001", label: "上证指数", cashDragPct: 5),
        // —— 科创 / 创业板 ——
        "科创50指数": Target(symbol: "sh000688", label: "科创50", cashDragPct: 5),
        "科创50": Target(symbol: "sh000688", label: "科创50", cashDragPct: 5),
        "上证科创板50成份指数": Target(symbol: "sh000688", label: "科创50", cashDragPct: 5),
        "科创板50指数": Target(symbol: "sh000688", label: "科创50", cashDragPct: 5),
        "科创100指数": Target(symbol: "sh000698", label: "科创100", cashDragPct: 5),
        "科创100": Target(symbol: "sh000698", label: "科创100", cashDragPct: 5),
        "创业板指数": Target(symbol: "sz399006", label: "创业板指", cashDragPct: 5),
        "创业板指": Target(symbol: "sz399006", label: "创业板指", cashDragPct: 5),
        "创业板50指数": Target(symbol: "sz399673", label: "创业板50", cashDragPct: 5),
        // —— 红利 ——
        "中证红利指数": Target(symbol: "sh000922", label: "中证红利", cashDragPct: 5),
        "中证红利": Target(symbol: "sh000922", label: "中证红利", cashDragPct: 5),
        "中证红利低波动指数": Target(symbol: "sh512890", label: "红利低波ETF", cashDragPct: 5),
        "中证红利的低波动指数": Target(symbol: "sh512890", label: "红利低波ETF", cashDragPct: 5),
        "上证红利指数": Target(symbol: "sh000015", label: "上证红利", cashDragPct: 5),
        "中证红利低波动100指数": Target(symbol: "sh512890", label: "红利低波ETF", cashDragPct: 5),
        // —— 行业（腾讯指数）——
        "中证银行指数": Target(symbol: "sz399986", label: "中证银行", cashDragPct: 5),
        "中证银行": Target(symbol: "sz399986", label: "中证银行", cashDragPct: 5),
        "中证白酒指数": Target(symbol: "sz399997", label: "中证白酒", cashDragPct: 5),
        "中证白酒": Target(symbol: "sz399997", label: "中证白酒", cashDragPct: 5),
        "中证医药指数": Target(symbol: "sh000933", label: "中证医药", cashDragPct: 5),
        "中证医药": Target(symbol: "sh000933", label: "中证医药", cashDragPct: 5),
        "中证医疗指数": Target(symbol: "sz399989", label: "中证医疗", cashDragPct: 5),
        "中证医疗": Target(symbol: "sz399989", label: "中证医疗", cashDragPct: 5),
        "中证军工指数": Target(symbol: "sz399967", label: "中证军工", cashDragPct: 5),
        "中证军工": Target(symbol: "sz399967", label: "中证军工", cashDragPct: 5),
        "中证新能源汽车指数": Target(symbol: "sz399976", label: "CS新能车", cashDragPct: 5),
        "中证新能车指数": Target(symbol: "sz399976", label: "CS新能车", cashDragPct: 5),
        "中证消费指数": Target(symbol: "sh000932", label: "中证消费", cashDragPct: 5),
        "中证消费": Target(symbol: "sh000932", label: "中证消费", cashDragPct: 5),
        "中证传媒指数": Target(symbol: "sz399971", label: "中证传媒", cashDragPct: 5),
        "中证传媒": Target(symbol: "sz399971", label: "中证传媒", cashDragPct: 5),
        "中证煤炭指数": Target(symbol: "sz399998", label: "中证煤炭", cashDragPct: 5),
        "中证煤炭": Target(symbol: "sz399998", label: "中证煤炭", cashDragPct: 5),
        "中证证券公司指数": Target(symbol: "sz399975", label: "证券公司", cashDragPct: 5),
        "中证全指证券公司指数": Target(symbol: "sz399975", label: "证券公司", cashDragPct: 5),
        "中证保险指数": Target(symbol: "sz399809", label: "保险主题", cashDragPct: 5),
        "中证房地产指数": Target(symbol: "sh000952", label: "300地产", cashDragPct: 5),
        "中证全指房地产指数": Target(symbol: "sh000952", label: "300地产", cashDragPct: 5),
        "中证基建指数": Target(symbol: "sz399995", label: "基建工程", cashDragPct: 5),
        "中证基建工程指数": Target(symbol: "sz399995", label: "基建工程", cashDragPct: 5),
        "中证环保指数": Target(symbol: "sh000827", label: "中证环保", cashDragPct: 5),
        "中证农业指数": Target(symbol: "sz399949", label: "内地农业", cashDragPct: 5),
        "中证能源指数": Target(symbol: "sz399928", label: "中证能源", cashDragPct: 5),
        "中证电信服务指数": Target(symbol: "sz399936", label: "中证电信", cashDragPct: 5),
        "中证信息技术指数": Target(symbol: "sz399935", label: "中证信息", cashDragPct: 5),
        // —— 行业（腾讯无对应指数，用 ETF 代理）——
        "国证半导体芯片指数": Target(symbol: "sz159995", label: "芯片ETF", cashDragPct: 5),
        "国证芯片指数": Target(symbol: "sz159995", label: "芯片ETF", cashDragPct: 5),
        "中证半导体材料设备主题指数": Target(symbol: "sz159995", label: "芯片ETF", cashDragPct: 5),
        "中证人工智能指数": Target(symbol: "sz159819", label: "人工智能ETF", cashDragPct: 5),
        "中证人工智能": Target(symbol: "sz159819", label: "人工智能ETF", cashDragPct: 5),
        "中证游戏指数": Target(symbol: "sz159869", label: "游戏ETF", cashDragPct: 5),
        "中证动漫游戏指数": Target(symbol: "sz159869", label: "游戏ETF", cashDragPct: 5),
        "中证光伏产业指数": Target(symbol: "sz515790", label: "光伏ETF", cashDragPct: 5),
        "中证消费电子指数": Target(symbol: "sz159732", label: "消费电子ETF", cashDragPct: 5),
        "中证机器人指数": Target(symbol: "sz159770", label: "机器人ETF", cashDragPct: 5),
        "中证云计算指数": Target(symbol: "sz516510", label: "云计算ETF", cashDragPct: 5),
        "中证大数据指数": Target(symbol: "sz515400", label: "大数据ETF", cashDragPct: 5),
        "中证科技龙头指数": Target(symbol: "sz515000", label: "科技ETF", cashDragPct: 5),
        "中证畜牧养殖指数": Target(symbol: "sz159865", label: "养殖ETF", cashDragPct: 5),
        "中证黄金指数": Target(symbol: "sh518880", label: "黄金ETF", cashDragPct: 5),
        "上海金指数": Target(symbol: "sh518880", label: "黄金ETF", cashDragPct: 5),
        "中证原油指数": Target(symbol: "sh513350", label: "标普油气ETF", cashDragPct: 5),
        "中证全债指数": Target(symbol: "sh000012", label: "国债指数", cashDragPct: 5),
        "中证国债指数": Target(symbol: "sh000012", label: "国债指数", cashDragPct: 5),
        "中证10年期国债指数": Target(symbol: "sh000012", label: "国债指数", cashDragPct: 5),
        // —— 跨境 ——
        "纳斯达克100指数": Target(symbol: "sh513100", label: "纳指ETF", cashDragPct: 5),
        "纳斯达克100": Target(symbol: "sh513100", label: "纳指ETF", cashDragPct: 5),
        "纳斯达克科技市值加权指数": Target(symbol: "sh513100", label: "纳指ETF", cashDragPct: 5),
        "标普500指数": Target(symbol: "sh513500", label: "标普500ETF", cashDragPct: 5),
        "标普500": Target(symbol: "sh513500", label: "标普500ETF", cashDragPct: 5),
        "恒生指数": Target(symbol: "hkHSI", label: "恒生指数", cashDragPct: 5),
        "恒生科技指数": Target(symbol: "hkHSTECH", label: "恒生科技", cashDragPct: 5),
        "恒生科技": Target(symbol: "hkHSTECH", label: "恒生科技", cashDragPct: 5),
        "恒生中国企业指数": Target(symbol: "hkHSCEI", label: "恒生国企", cashDragPct: 5),
        "恒生国企指数": Target(symbol: "hkHSCEI", label: "恒生国企", cashDragPct: 5),
        "恒生港股通指数": Target(symbol: "hkHSI", label: "恒生指数", cashDragPct: 5),
        "中证海外中国互联网50指数": Target(symbol: "sh513050", label: "中概互联", cashDragPct: 5),
        "中证海外中国互联网50人民币指数": Target(symbol: "sh513050", label: "中概互联", cashDragPct: 5),
        "中证海外中国互联网30指数": Target(symbol: "sh513050", label: "中概互联", cashDragPct: 5),
        "中证海外互联网50指数": Target(symbol: "sh513050", label: "中概互联", cashDragPct: 5),
        "中证港股通创新药指数": Target(symbol: "sh513120", label: "港股创新药", cashDragPct: 5),
        "中证港股通科技指数": Target(symbol: "sh513130", label: "恒生科技", cashDragPct: 5),
        "中证港股通高股息投资指数": Target(symbol: "sh513530", label: "港股通红利", cashDragPct: 5),
        "中证香港证券投资主题指数": Target(symbol: "sh513090", label: "香港证券", cashDragPct: 5),
    ]

    /// 关键词宽松匹配（精确表未命中时按包含关系）。按关键词长度降序匹配。
    static let fuzzyKeywords: [(keyword: String, target: Target)] = [
        ("纳斯达克100", Target(symbol: "sh513100", label: "纳指ETF", cashDragPct: 5)),
        ("纳斯达克", Target(symbol: "sh513100", label: "纳指ETF", cashDragPct: 5)),
        ("标普500", Target(symbol: "sh513500", label: "标普500ETF", cashDragPct: 5)),
        ("标普", Target(symbol: "sh513500", label: "标普500ETF", cashDragPct: 5)),
        ("恒生科技", Target(symbol: "hkHSTECH", label: "恒生科技", cashDragPct: 5)),
        ("恒生国企", Target(symbol: "hkHSCEI", label: "恒生国企", cashDragPct: 5)),
        ("恒生指数", Target(symbol: "hkHSI", label: "恒生指数", cashDragPct: 5)),
        ("恒生", Target(symbol: "hkHSI", label: "恒生指数", cashDragPct: 5)),
        ("中国互联网", Target(symbol: "sh513050", label: "中概互联", cashDragPct: 5)),
        ("海外互联网", Target(symbol: "sh513050", label: "中概互联", cashDragPct: 5)),
        ("中概", Target(symbol: "sh513050", label: "中概互联", cashDragPct: 5)),
        ("港股通创新药", Target(symbol: "sh513120", label: "港股创新药", cashDragPct: 5)),
        ("港股通科技", Target(symbol: "sh513130", label: "恒生科技", cashDragPct: 5)),
        ("港股通红利", Target(symbol: "sh513530", label: "港股通红利", cashDragPct: 5)),
        ("香港证券", Target(symbol: "sh513090", label: "香港证券", cashDragPct: 5)),
        ("港股", Target(symbol: "hkHSI", label: "恒生指数", cashDragPct: 5)),
        ("半导体", Target(symbol: "sz159995", label: "芯片ETF", cashDragPct: 5)),
        ("芯片", Target(symbol: "sz159995", label: "芯片ETF", cashDragPct: 5)),
        ("人工智能", Target(symbol: "sz159819", label: "人工智能ETF", cashDragPct: 5)),
        ("游戏", Target(symbol: "sz159869", label: "游戏ETF", cashDragPct: 5)),
        ("动漫", Target(symbol: "sz159869", label: "游戏ETF", cashDragPct: 5)),
        ("光伏", Target(symbol: "sz515790", label: "光伏ETF", cashDragPct: 5)),
        ("消费电子", Target(symbol: "sz159732", label: "消费电子ETF", cashDragPct: 5)),
        ("机器人", Target(symbol: "sz159770", label: "机器人ETF", cashDragPct: 5)),
        ("云计算", Target(symbol: "sz516510", label: "云计算ETF", cashDragPct: 5)),
        ("大数据", Target(symbol: "sz515400", label: "大数据ETF", cashDragPct: 5)),
        ("科技龙头", Target(symbol: "sz515000", label: "科技ETF", cashDragPct: 5)),
        ("畜牧", Target(symbol: "sz159865", label: "养殖ETF", cashDragPct: 5)),
        ("养殖", Target(symbol: "sz159865", label: "养殖ETF", cashDragPct: 5)),
        ("红利低波", Target(symbol: "sh512890", label: "红利低波ETF", cashDragPct: 5)),
        ("红利", Target(symbol: "sh000922", label: "中证红利", cashDragPct: 5)),
        ("科创50", Target(symbol: "sh000688", label: "科创50", cashDragPct: 5)),
        ("科创板50", Target(symbol: "sh000688", label: "科创50", cashDragPct: 5)),
        ("科创100", Target(symbol: "sh000698", label: "科创100", cashDragPct: 5)),
        ("创业板50", Target(symbol: "sz399673", label: "创业板50", cashDragPct: 5)),
        ("创业板", Target(symbol: "sz399006", label: "创业板指", cashDragPct: 5)),
        ("中证500", Target(symbol: "sh000905", label: "中证500", cashDragPct: 5)),
        ("中证1000", Target(symbol: "sh000852", label: "中证1000", cashDragPct: 5)),
        ("中证A500", Target(symbol: "sh000510", label: "中证A500", cashDragPct: 5)),
        ("中证2000", Target(symbol: "sz159531", label: "中证2000ETF", cashDragPct: 5)),
        ("北证50", Target(symbol: "bj899050", label: "北证50", cashDragPct: 5)),
        ("沪深300", Target(symbol: "sh000300", label: "沪深300", cashDragPct: 5)),
        ("上证50", Target(symbol: "sh000016", label: "上证50", cashDragPct: 5)),
        ("白酒", Target(symbol: "sz399997", label: "中证白酒", cashDragPct: 5)),
        ("医药", Target(symbol: "sh000933", label: "中证医药", cashDragPct: 5)),
        ("医疗", Target(symbol: "sz399989", label: "中证医疗", cashDragPct: 5)),
        ("军工", Target(symbol: "sz399967", label: "中证军工", cashDragPct: 5)),
        ("银行", Target(symbol: "sz399986", label: "中证银行", cashDragPct: 5)),
        ("证券", Target(symbol: "sz399975", label: "证券公司", cashDragPct: 5)),
        ("保险", Target(symbol: "sz399809", label: "保险主题", cashDragPct: 5)),
        ("房地产", Target(symbol: "sh000952", label: "300地产", cashDragPct: 5)),
        ("地产", Target(symbol: "sh000952", label: "300地产", cashDragPct: 5)),
        ("新能源车", Target(symbol: "sz399976", label: "CS新能车", cashDragPct: 5)),
        ("新能源汽车", Target(symbol: "sz399976", label: "CS新能车", cashDragPct: 5)),
        ("新能", Target(symbol: "sz399808", label: "中证新能", cashDragPct: 5)),
        ("煤炭", Target(symbol: "sz399998", label: "中证煤炭", cashDragPct: 5)),
        ("农业", Target(symbol: "sz399949", label: "内地农业", cashDragPct: 5)),
        ("基建", Target(symbol: "sz399995", label: "基建工程", cashDragPct: 5)),
        ("环保", Target(symbol: "sh000827", label: "中证环保", cashDragPct: 5)),
        ("传媒", Target(symbol: "sz399971", label: "中证传媒", cashDragPct: 5)),
        ("黄金", Target(symbol: "sh518880", label: "黄金ETF", cashDragPct: 5)),
        ("原油", Target(symbol: "sh513350", label: "标普油气ETF", cashDragPct: 5)),
        ("油气", Target(symbol: "sh513350", label: "标普油气ETF", cashDragPct: 5)),
        ("国债", Target(symbol: "sh000012", label: "国债指数", cashDragPct: 5)),
        ("全债", Target(symbol: "sh000012", label: "国债指数", cashDragPct: 5)),
        ("债券", Target(symbol: "sh000012", label: "国债指数", cashDragPct: 5)),
    ]
    /// 解析跟踪标的原文 → 代理。未命中返回 nil（调用方退回旧版按基金名猜）。
    static func target(forTrackingTarget text: String) -> Target? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let exactMatch = exact[trimmed] { return exactMatch }
        // 去掉「指数」后缀再试一次精确表。
        let stripped = trimmed.replacingOccurrences(of: "指数", with: "")
        if let exactMatch = exact[stripped] { return exactMatch }
        // 宽松匹配：按关键词长度降序，避免「恒生」抢先命中「恒生科技」。
        for (keyword, target) in fuzzyKeywords.sorted(by: { $0.0.count > $1.0.count }) {
            if trimmed.contains(keyword) { return target }
        }
        return nil
    }
}
