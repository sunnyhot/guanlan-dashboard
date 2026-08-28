import Foundation

// MARK: - A股板块分类

/// A股板块分类，决定涨跌停幅度等交易规则。
/// 识别规则见 `MarketBoardRule`。
enum MarketBoard: String, Codable, Hashable, Sendable, CaseIterable {
    case shMain   // 上交所主板
    case szMain   // 深交所主板
    case chiNext  // 创业板
    case star     // 科创板
    case bse      // 北交所

    var displayName: String {
        switch self {
        case .shMain: return "沪主板"
        case .szMain: return "深主板"
        case .chiNext: return "创业板"
        case .star: return "科创板"
        case .bse: return "北交所"
        }
    }
}

// MARK: - 统一行情契约

/// 全市场统一实时行情。各数据源字段归一到本契约后供广度计算/技术分析/Agent 工具消费。
/// 缺失字段保持 nil，不编造；量纲统一：价格元、成交量股、成交额元、市值元、比率百分比。
struct MarketQuote: Codable, Hashable, Sendable, Identifiable {
    var id: String { code }

    /// 规范化代码：A股 6 位数字；港股 `HK00700`；美股原样大写。
    let code: String
    var name: String = ""
    var price: Double?
    var previousClose: Double?
    var changePct: Double?
    var open: Double?
    var high: Double?
    var low: Double?
    var volume: Double?
    var amount: Double?
    var turnoverRate: Double?
    var peRatio: Double?
    var pbRatio: Double?
    var volumeRatio: Double?
    var totalMarketCap: Double?
    var circMarketCap: Double?
    var limitUpPrice: Double?
    var limitDownPrice: Double?
    var isST: Bool = false
    var board: MarketBoard?
    var quotedAt: String = ""
    var source: String = ""

    var changeAmount: Double? {
        guard let price, let previousClose else { return nil }
        return price - previousClose
    }

    var hasUsablePrice: Bool {
        guard let price, price.isFinite else { return false }
        return price > 0
    }

    /// 用于广度计算的前收盘价：优先源字段，缺失时按涨跌幅反推（精度受涨跌幅小数位限制）。
    var effectivePreviousClose: Double? {
        if let previousClose, previousClose > 0 { return previousClose }
        guard let price, price > 0, let changePct, changePct.isFinite, changePct > -100 else { return nil }
        let derived = price / (1 + changePct / 100)
        return derived.isFinite && derived > 0 ? derived : nil
    }
}

// MARK: - 统一日线

/// 统一日线（前复权）。各源 K 线归一到本契约后供技术分析/回测消费。
struct MarketDailyBar: Codable, Hashable, Sendable {
    /// yyyy-MM-dd
    let date: String
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    /// 股
    let volume: Double
    /// 元
    let amount: Double
    /// %，缺失时由相邻收盘价计算
    var pctChg: Double?
}

// MARK: - 市场广度

/// 市场广度统计（本地计算产物）。涨跌停家数是触板判定而非接口值。
struct MarketBreadthStats: Codable, Hashable, Sendable {
    var upCount: Int = 0
    var downCount: Int = 0
    var flatCount: Int = 0
    var limitUpCount: Int = 0
    var limitDownCount: Int = 0
    /// 成交额合计（亿元）
    var totalAmountYi: Double?
    /// 参与统计的样本数（有可用价格的）
    var sampleCount: Int = 0
    /// 因缺价格/前收盘价被排除的数量
    var excludedCount: Int = 0
    var computedAt: String = ""
    /// 数据边界说明（样本范围/来源局限/反推口径等），随数据一起进 prompt，防过度解读
    var dataBoundary: String = ""

    var advanceDeclineSummary: String {
        "上涨 \(upCount) | 下跌 \(downCount) | 平盘 \(flatCount)"
    }

    var limitSummary: String {
        "涨停 \(limitUpCount) | 跌停 \(limitDownCount)"
    }
}

// MARK: - 错误

/// 市场数据层统一错误。
enum MarketDataError: Error, LocalizedError, Sendable {
    case invalidResponse
    case emptyResponse
    case badStatus(status: Int, snippet: String)
    case rateLimited(status: Int)
    case circuitOpen(key: String)
    case allSourcesFailed(details: [String])

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "行情源返回了无法解析的内容"
        case .emptyResponse: return "行情源返回为空"
        case .badStatus(let status, let snippet): return "行情源 HTTP \(status)：\(snippet)"
        case .rateLimited(let status): return "行情源限流（HTTP \(status)），稍后重试"
        case .circuitOpen(let key): return "行情源熔断中：\(key)"
        case .allSourcesFailed(let details): return "全部行情源失败：\(details.joined(separator: "；"))"
        }
    }
}

// MARK: - 代码规范化

/// 行情代码规范化工具。
enum MarketCodeNormalizer {
    /// 剥离交易所前缀/后缀，得到裸代码：`sh600519`→`600519`，`600519.SH`→`600519`，`1.600519`→`600519`。
    static func bareACode(from symbol: String) -> String {
        var text = symbol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["sh", "sz", "bj", "of", "hk"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
        if text.hasSuffix(".sh") || text.hasSuffix(".sz") || text.hasSuffix(".bj") {
            text = String(text.dropLast(3))
        }
        // 东财 secid 形如 1.600519：单个数字交易所位在前
        if let dot = text.firstIndex(of: "."), dot == text.index(after: text.startIndex) {
            text = String(text[text.index(after: dot)...])
        }
        return text.uppercased()
    }

    /// 规范化为稳定键：A股 6 位数字保持；港股补齐 `HK` 前缀 5 位（`0700.HK`/`hk700`/`HK00700` → `HK00700`）。
    static func canonicalKey(for symbol: String) -> String {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasPrefix("HK") {
            let digits = trimmed.dropFirst(2).prefix(while: \.isNumber)
            if (3...6).contains(digits.count) {
                return "HK" + String(digits).padStart(length: 5)
            }
        }
        if trimmed.hasSuffix(".HK") {
            let digits = trimmed.dropLast(3).prefix(while: \.isNumber)
            if (3...6).contains(digits.count) {
                return "HK" + String(digits).padStart(length: 5)
            }
        }
        return trimmed
    }
}

extension String {
    /// 左侧补零到指定长度（港股代码补齐用）。
    func padStart(length: Int, padding: Character = "0") -> String {
        count >= length ? self : String(repeating: String(padding), count: length - count) + self
    }
}
