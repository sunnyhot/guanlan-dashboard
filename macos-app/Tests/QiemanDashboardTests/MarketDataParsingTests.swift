import XCTest
@testable import QiemanDashboard

// MARK: - 腾讯行情解析

final class TencentQuoteProviderTests: XCTestCase {
    /// 构造一条腾讯行情响应行。元组为 (占位名, 字段索引, 值)，索引口径见 TencentQuoteProvider 文档注释。
    private func tencentLine(symbol: String, fields: [(String, Int, String)]) -> String {
        var parts = [String](repeating: "", count: 50)
        for (_, index, value) in fields {
            parts[index] = value
        }
        return "v_\(symbol)=\"\(parts.joined(separator: "~"))\""
    }

    func testParseFullFields() {
        // 构造 600519：价格 1435.00、昨收 1422.66、换手 0.35%、流通市值 1.8e12 元（18000 亿）
        let line = tencentLine(symbol: "sh600519", fields: [
            ("name", 1, "贵州茅台"), ("code", 2, "600519"), ("price", 3, "1435.00"),
            ("prevClose", 4, "1422.66"), ("open", 5, "1440.00"), ("volume", 6, "1234567"),
            ("time", 30, "20260828150000"), ("change", 31, "12.34"), ("pct", 32, "0.87"),
            ("high", 33, "1445.00"), ("low", 34, "1430.00"),
            ("triple", 35, "1435.00/1234567/1771000000"),
            ("amountWan", 37, "177100000"),
            ("turnover", 38, "0.35"), ("pe", 39, "20.50"), ("amplitude", 43, "1.00"),
            ("circCapYi", 44, "18000.00"), ("totalCapYi", 45, "18010.00"), ("pb", 46, "8.20"),
            ("limitUp", 47, "1564.93"), ("limitDown", 48, "1280.39"), ("volumeRatio", 49, "1.05"),
        ])
        let quotes = TencentQuoteProvider.parseQuotes(text: line + ";")
        XCTAssertEqual(quotes.count, 1)
        let quote = quotes[0]

        XCTAssertEqual(quote.code, "600519")
        XCTAssertEqual(quote.name, "贵州茅台")
        XCTAssertEqual(quote.price ?? 0, 1435.0)
        XCTAssertEqual(quote.previousClose ?? 0, 1422.66)
        XCTAssertEqual(quote.open ?? 0, 1440.0)
        XCTAssertEqual(quote.high ?? 0, 1445.0)
        XCTAssertEqual(quote.low ?? 0, 1430.0)
        XCTAssertEqual(quote.changePct ?? 0, 0.87, accuracy: 0.0001)
        XCTAssertEqual(quote.limitUpPrice ?? 0, 1564.93)
        XCTAssertEqual(quote.limitDownPrice ?? 0, 1280.39)
        XCTAssertEqual(quote.peRatio ?? 0, 20.5)
        XCTAssertEqual(quote.pbRatio ?? 0, 8.2)
        XCTAssertEqual(quote.volumeRatio ?? 0, 1.05)
        XCTAssertEqual(quote.turnoverRate ?? 0, 0.35)
        // 市值：亿 → 元
        XCTAssertEqual(quote.circMarketCap ?? 0, 1.8e12, accuracy: 1e6)
        XCTAssertEqual(quote.totalMarketCap ?? 0, 1.801e12, accuracy: 1e7)
        // 成交额：字段 37 万元 → 元
        XCTAssertEqual(quote.amount ?? 0, 1.771e12, accuracy: 1e6)
        XCTAssertEqual(quote.quotedAt, "2026-08-28 15:00:00")
        XCTAssertEqual(quote.board, .shMain)
        XCTAssertFalse(quote.isST)
        // 成交量交叉校验：估算股数 = 1.8e12 / 1435 × 0.35% ≈ 4.39e6 股
        // 字段 6 = 1234567，×100 后 1.23e8 远偏离估算，故按「股」保留
        XCTAssertEqual(quote.volume ?? 0, 1_234_567, accuracy: 1)
    }

    func testVolumeCrossCheckScalesHandsToShares() {
        // 估算股数 = 2.0e9 / 10.0 × 1.0% = 2.0e6 股；字段 6 = 20000 手 → ×100 = 2.0e6 贴合估算 → 判定为手
        let volume = TencentQuoteProvider.normalizedVolume(
            raw: 20_000,
            price: 10.0,
            circMarketCap: 2.0e9,
            turnoverRate: 1.0
        )
        XCTAssertEqual(volume ?? 0, 2.0e6, accuracy: 1)
    }

    func testVolumeCrossCheckKeepsRawWhenEstimateMissing() {
        let volume = TencentQuoteProvider.normalizedVolume(raw: 123, price: nil, circMarketCap: nil, turnoverRate: nil)
        XCTAssertEqual(volume, 123)
    }

    func testParseSTName() {
        let line = tencentLine(symbol: "sz000005", fields: [
            ("name", 1, "ST新海"), ("code", 2, "000005"), ("price", 3, "1.23"),
            ("prevClose", 4, "1.20"), ("pct", 32, "2.50"),
        ])
        let quotes = TencentQuoteProvider.parseQuotes(text: line + ";")
        XCTAssertEqual(quotes.count, 1)
        XCTAssertTrue(quotes[0].isST)
        XCTAssertEqual(quotes[0].board, .szMain)
    }

    func testParseMultipleQuotesAndSkipsGarbage() {
        let line1 = tencentLine(symbol: "sh600519", fields: [
            ("name", 1, "贵州茅台"), ("code", 2, "600519"), ("price", 3, "1435.00"),
            ("prevClose", 4, "1422.66"),
        ])
        let line2 = tencentLine(symbol: "sz300750", fields: [
            ("name", 1, "宁德时代"), ("code", 2, "300750"), ("price", 3, "200.00"),
            ("prevClose", 4, "198.00"),
        ])
        let text = "garbage header\n" + line1 + ";" + line2 + ";"
        let quotes = TencentQuoteProvider.parseQuotes(text: text)
        XCTAssertEqual(quotes.count, 2)
        XCTAssertEqual(quotes[0].code, "600519")
        XCTAssertEqual(quotes[1].code, "300750")
        XCTAssertEqual(quotes[1].board, .chiNext)
    }

    func testTencentSymbolMapping() {
        XCTAssertEqual(TencentQuoteProvider.tencentSymbol(for: "600519"), "sh600519")
        XCTAssertEqual(TencentQuoteProvider.tencentSymbol(for: "510300"), "sh510300")
        XCTAssertEqual(TencentQuoteProvider.tencentSymbol(for: "000001"), "sz000001")
        XCTAssertEqual(TencentQuoteProvider.tencentSymbol(for: "300750"), "sz300750")
        XCTAssertEqual(TencentQuoteProvider.tencentSymbol(for: "830799"), "bj830799")
        XCTAssertEqual(TencentQuoteProvider.tencentSymbol(for: "920001"), "bj920001")
        XCTAssertNil(TencentQuoteProvider.tencentSymbol(for: "AAPL"))
    }

    func testFormatQuoteTime() {
        XCTAssertEqual(TencentQuoteProvider.formatQuoteTime("20260828150000"), "2026-08-28 15:00:00")
        XCTAssertEqual(TencentQuoteProvider.formatQuoteTime("2026-08-28 15:00:03"), "2026-08-28 15:00:03")
        XCTAssertEqual(TencentQuoteProvider.formatQuoteTime("abc"), "abc")
        XCTAssertEqual(TencentQuoteProvider.formatQuoteTime(nil), "")
    }
}

// MARK: - 新浪全市场快照解析

final class SinaSnapshotProviderTests: XCTestCase {
    private func pageJSON(_ items: [[String: String]]) -> String {
        let encoder = JSONEncoder()
        let data = (try? encoder.encode(items)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    func testParsePageMapsFieldsAndUnits() {
        let text = pageJSON([
            [
                "symbol": "sh600519", "code": "600519", "name": "贵州茅台",
                "trade": "1435.00", "pricechange": "12.34", "changepercent": "0.87",
                "settlement": "1422.66", "open": "1440.00", "high": "1445.00", "low": "1430.00",
                "volume": "4390000", "amount": "6300000000",
                "ticktime": "15:00:03", "per": "20.50", "pb": "8.20",
                "mktcap": "180100000.00", "nmc": "180000000.00", "turnoverratio": "0.35",
            ],
            [
                "symbol": "sz300750", "code": "300750", "name": "宁德时代",
                "trade": "200.00", "changepercent": "1.01", "settlement": "198.00",
                "volume": "8000000", "amount": "1600000000",
                "mktcap": "88000000.00", "nmc": "78000000.00", "turnoverratio": "0.51",
            ],
        ])
        let quotes = SinaSnapshotProvider.parsePage(text)
        XCTAssertEqual(quotes.count, 2)

        let maotai = quotes[0]
        XCTAssertEqual(maotai.code, "600519")
        XCTAssertEqual(maotai.name, "贵州茅台")
        XCTAssertEqual(maotai.price ?? 0, 1435.0)
        XCTAssertEqual(maotai.previousClose ?? 0, 1422.66)
        XCTAssertEqual(maotai.changePct ?? 0, 0.87)
        XCTAssertEqual(maotai.peRatio ?? 0, 20.5)
        XCTAssertEqual(maotai.pbRatio ?? 0, 8.2)
        // 市值单位：万元 → 元
        XCTAssertEqual(maotai.totalMarketCap ?? 0, 1.801e12, accuracy: 1e6)
        XCTAssertEqual(maotai.circMarketCap ?? 0, 1.8e12, accuracy: 1e6)
        XCTAssertEqual(maotai.turnoverRate ?? 0, 0.35)
        XCTAssertEqual(maotai.volume ?? 0, 4_390_000)
        XCTAssertEqual(maotai.amount ?? 0, 6.3e9)
        XCTAssertEqual(maotai.board, .shMain)
        XCTAssertEqual(maotai.source, "sina")

        let catl = quotes[1]
        XCTAssertEqual(catl.code, "300750")
        XCTAssertEqual(catl.board, .chiNext)
        XCTAssertNil(catl.volumeRatio, "新浪快照无量比字段")
    }

    func testParsePageToleratesBadPayload() {
        XCTAssertEqual(SinaSnapshotProvider.parsePage("null"), [])
        XCTAssertEqual(SinaSnapshotProvider.parsePage("{}"), [])
        XCTAssertEqual(SinaSnapshotProvider.parsePage(""), [])
        // 单条缺 symbol 的坏记录被跳过，其余保留
        let text = pageJSON([
            ["name": "无代码"],
            ["symbol": "sh600519", "trade": "1435.00", "settlement": "1422.66"],
        ])
        XCTAssertEqual(SinaSnapshotProvider.parsePage(text).count, 1)
    }

    func testParsePageFlagsST() {
        let text = pageJSON([
            ["symbol": "sz000005", "name": "ST新海", "trade": "1.23", "settlement": "1.20", "changepercent": "2.50"],
        ])
        let quotes = SinaSnapshotProvider.parsePage(text)
        XCTAssertTrue(quotes[0].isST)
    }

    func testPageURLShape() {
        let provider = SinaSnapshotProvider(session: MarketDataSession())
        let url = provider.pageURL(page: 3)
        XCTAssertEqual(url.host, "vip.stock.finance.sina.com.cn")
        XCTAssertTrue(url.absoluteString.contains("page=3"))
        XCTAssertTrue(url.absoluteString.contains("num=100"))
        XCTAssertTrue(url.absoluteString.contains("node=hs_a"))
    }
}
