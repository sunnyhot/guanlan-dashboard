import Foundation

/// 腾讯行情 Provider（`qt.gtimg.cn/q=sh600519`）。免 token，GBK 编码，`~` 分隔。
///
/// 字段映射对拍 daily_stock_analysis（MIT）`akshare_fetcher.py:1455-1481`：
/// 1 名称 / 2 代码 / 3 最新价 / 4 昨收 / 5 今开 / 6 成交量 / 30 时间 /
/// 31 涨跌额 / 32 涨跌幅% / 33 最高 / 34 最低 / 35 量额三元组 / 37 成交额(万元) /
/// 38 换手率% / 39 PE / 43 振幅% / 44 流通市值(亿) / 45 总市值(亿) / 46 PB /
/// 47 涨停价 / 48 跌停价 / 49 量比。
///
/// 量纲坑（对拍 DSA `_normalize_tencent_volume`）：字段 6 的成交量「手/股」口径不稳定，
/// 用 `流通市值/价格 × 换手率` 交叉校验后决定是否 ×100。
struct TencentQuoteProvider: Sendable {
    static let batchSize = 30

    let session: MarketDataSession

    init(session: MarketDataSession) {
        self.session = session
    }

    enum ParseError: Error, Equatable {
        case noQuotePayload
    }

    // MARK: - 抓取

    /// 批量抓取 A股/港股行情。返回按传入顺序对齐的结果（抓不到的代码不出现在结果里）。
    func quotes(codes: [String]) async throws -> [MarketQuote] {
        var result: [MarketQuote] = []
        for chunk in codes.chunked(into: Self.batchSize) where !chunk.isEmpty {
            let symbols = chunk.compactMap(Self.tencentSymbol(for:))
            guard !symbols.isEmpty else { continue }
            let url = URL(string: "https://qt.gtimg.cn/q=\(symbols.joined(separator: ","))")!
            let text = try await session.text(url, headers: [
                "Accept": "text/plain,*/*",
                "Referer": "https://gu.qq.com/",
            ])
            result += Self.parseQuotes(text: text)
        }
        return result
    }

    // MARK: - 解析（纯函数，供测试）

    /// 解析 `v_sh600519="...";v_sz000001="...";` 形式的整段响应。
    static func parseQuotes(text: String) -> [MarketQuote] {
        var quotes: [MarketQuote] = []
        for line in text.split(separator: ";") where line.contains("=") {
            if let quote = parseLine(String(line)) {
                quotes.append(quote)
            }
        }
        return quotes
    }

    private static func parseLine(_ line: String) -> MarketQuote? {
        guard
            let equals = line.firstIndex(of: "="),
            let openQuote = line[equals...].firstIndex(of: "\""),
            line.hasSuffix("\"") || line.contains("\"")
        else { return nil }
        let afterQuote = line.index(after: openQuote)
        let payload: Substring
        if let closeQuote = line[afterQuote...].lastIndex(of: "\""), closeQuote > afterQuote {
            payload = line[afterQuote..<closeQuote]
        } else {
            payload = line[afterQuote...]
        }
        guard !payload.isEmpty else { return nil }

        let parts = payload.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 32, let rawName = parts.at(1), !rawName.isEmpty else { return nil }

        let code = MarketCodeNormalizer.bareACode(from: parts.at(2) ?? "")
        let price = parts.double(at: 3)
        let previousClose = parts.double(at: 4)
        let open = parts.double(at: 5)
        let high = parts.double(at: 33)
        let low = parts.double(at: 34)
        let changePct = parts.double(at: 32)
        let turnoverRate = parts.double(at: 38)
        let peRatio = parts.double(at: 39)
        let pbRatio = parts.double(at: 46)
        let volumeRatio = parts.double(at: 49)
        let circMarketCapYi = parts.double(at: 44)
        let totalMarketCapYi = parts.double(at: 45)
        let circMarketCap = circMarketCapYi.map { $0 * 1e8 }
        let totalMarketCap = totalMarketCapYi.map { $0 * 1e8 }

        // 成交额：字段 37（万元）为基准；缺失时兜底 35 三元组第 3 段。
        let amountYuan = parts.double(at: 37).map { $0 * 1e4 }
            ?? parseAmountTriple(parts.at(35))

        let volume = normalizedVolume(
            raw: parts.double(at: 6),
            price: price,
            circMarketCap: circMarketCap,
            turnoverRate: turnoverRate
        )

        let isST = MarketBoardRule.isSTName(rawName)
        let board = MarketBoardRule.board(forCode: code)

        return MarketQuote(
            code: code,
            name: rawName,
            price: price,
            previousClose: previousClose,
            changePct: changePct,
            open: open,
            high: high,
            low: low,
            volume: volume,
            amount: amountYuan,
            turnoverRate: turnoverRate,
            peRatio: peRatio,
            pbRatio: pbRatio,
            volumeRatio: volumeRatio,
            totalMarketCap: totalMarketCap,
            circMarketCap: circMarketCap,
            limitUpPrice: parts.double(at: 47),
            limitDownPrice: parts.double(at: 48),
            isST: isST,
            board: board,
            quotedAt: formatQuoteTime(parts.at(30)),
            source: "tencent"
        )
    }

    // MARK: - 工具

    /// A股裸代码 → 腾讯 symbol（口径与 QiemanPlatformNativeClient.tencentStockSymbol 一致）。
    /// 注意 92 开头（北交所新号段）须先于 9 开头（沪市 B股）判断。
    static func tencentSymbol(for code: String) -> String? {
        let bare = MarketCodeNormalizer.bareACode(from: code)
        guard bare.count == 6, bare.allSatisfy(\.isNumber) else { return nil }
        if bare.hasPrefix("92") {
            return "bj\(bare)"
        }
        if bare.hasPrefix("5") || bare.hasPrefix("6") || bare.hasPrefix("9") {
            return "sh\(bare)"
        }
        if bare.hasPrefix("4") || bare.hasPrefix("8") {
            return "bj\(bare)"
        }
        return "sz\(bare)"
    }

    /// 成交量单位交叉校验：用估算股数判断原始值是手还是股。
    static func normalizedVolume(
        raw: Double?,
        price: Double?,
        circMarketCap: Double?,
        turnoverRate: Double?
    ) -> Double? {
        guard let raw, raw > 0 else { return raw }
        guard let price, price > 0,
              let circMarketCap, circMarketCap > 0,
              let turnoverRate, turnoverRate > 0
        else { return raw }
        // 估算成交股数 = 流通市值 / 价格 × 换手率%
        let estimatedShares = circMarketCap / price * (turnoverRate / 100)
        guard estimatedShares.isFinite, estimatedShares > 0 else { return raw }
        let asIs = abs(raw - estimatedShares)
        let asHundred = abs(raw * 100 - estimatedShares)
        return asHundred < asIs ? raw * 100 : raw
    }

    /// 字段 35「价格/成交量/成交额」三元组 → 成交额（兜底口径，单位可能带歧义，仅 37 缺失时使用）。
    static func parseAmountTriple(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let segments = raw.split(separator: "/").map(String.init)
        guard segments.count >= 3, let value = Double(segments[2]) else { return nil }
        return value
    }

    /// `20260828150000` → `2026-08-28 15:00:00`；已是横线格式则截取前 19 位。
    static func formatQuoteTime(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        if raw.contains("-"), raw.count >= 10 {
            return String(raw.prefix(19))
        }
        guard raw.count >= 14, raw.allSatisfy(\.isNumber) else { return raw }
        let year = raw.prefix(4)
        let month = raw.dropFirst(4).prefix(2)
        let day = raw.dropFirst(6).prefix(2)
        let hour = raw.dropFirst(8).prefix(2)
        let minute = raw.dropFirst(10).prefix(2)
        let second = raw.dropFirst(12).prefix(2)
        return "\(year)-\(month)-\(day) \(hour):\(minute):\(second)"
    }
}

// MARK: - 小工具

extension Array where Element == String {
    func at(_ index: Int) -> String? {
        guard indices.contains(index) else { return nil }
        return self[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func double(at index: Int) -> Double? {
        guard let raw = at(index), !raw.isEmpty else { return nil }
        return Double(raw).flatMap { $0.isFinite ? $0 : nil }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
