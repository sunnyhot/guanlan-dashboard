import XCTest
@testable import QiemanDashboard

// MARK: - 板块识别与涨跌停规则

final class MarketBoardRuleTests: XCTestCase {
    func testBoardDetection() {
        XCTAssertEqual(MarketBoardRule.board(forCode: "600519"), .shMain)
        XCTAssertEqual(MarketBoardRule.board(forCode: "000001"), .szMain)
        XCTAssertEqual(MarketBoardRule.board(forCode: "002594"), .szMain)
        XCTAssertEqual(MarketBoardRule.board(forCode: "300750"), .chiNext)
        XCTAssertEqual(MarketBoardRule.board(forCode: "301236"), .chiNext)
        XCTAssertEqual(MarketBoardRule.board(forCode: "688981"), .star)
        XCTAssertEqual(MarketBoardRule.board(forCode: "689009"), .star)
        XCTAssertEqual(MarketBoardRule.board(forCode: "830799"), .bse)
        XCTAssertEqual(MarketBoardRule.board(forCode: "430047"), .bse)
        XCTAssertEqual(MarketBoardRule.board(forCode: "920001"), .bse)
        XCTAssertEqual(MarketBoardRule.board(forCode: "510300"), .shMain)
        XCTAssertNil(MarketBoardRule.board(forCode: "60051"))
        XCTAssertNil(MarketBoardRule.board(forCode: "AAPL"))
    }

    func testBoardDetectionAcceptsPrefixedSymbols() {
        XCTAssertEqual(MarketBoardRule.board(forCode: "sh600519"), .shMain)
        XCTAssertEqual(MarketBoardRule.board(forCode: "600519.SH"), .shMain)
        XCTAssertEqual(MarketBoardRule.board(forCode: "1.600519"), .shMain)
        XCTAssertEqual(MarketBoardRule.board(forCode: "0.000001"), .szMain)
    }

    func testSTDetection() {
        XCTAssertTrue(MarketBoardRule.isSTName("ST摩登"))
        XCTAssertTrue(MarketBoardRule.isSTName("*ST新海"))
        XCTAssertTrue(MarketBoardRule.isSTName("st中安"))
        XCTAssertFalse(MarketBoardRule.isSTName("贵州茅台"))
    }

    func testLimitRatio() {
        XCTAssertEqual(MarketBoardRule.limitRatio(board: .shMain, isST: false), 0.10)
        XCTAssertEqual(MarketBoardRule.limitRatio(board: .szMain, isST: true), 0.05)
        XCTAssertEqual(MarketBoardRule.limitRatio(board: .chiNext, isST: false), 0.20)
        XCTAssertEqual(MarketBoardRule.limitRatio(board: .chiNext, isST: true), 0.20, "注册制板块 ST 不缩幅")
        XCTAssertEqual(MarketBoardRule.limitRatio(board: .star, isST: false), 0.20)
        XCTAssertEqual(MarketBoardRule.limitRatio(board: .bse, isST: false), 0.30)
    }

    func testLimitPriceComputation() {
        // 主板 10%：10.00 → 11.00 / 9.00
        XCTAssertEqual(MarketBoardRule.limitUpPrice(previousClose: 10.0, board: .shMain, isST: false) ?? 0, 11.0)
        XCTAssertEqual(MarketBoardRule.limitDownPrice(previousClose: 10.0, board: .shMain, isST: false) ?? 0, 9.0)
        // 主板四舍五入到分：9.87 × 1.1 = 10.857 → 10.86；9.87 × 0.9 = 8.883 → 8.88
        XCTAssertEqual(MarketBoardRule.limitUpPrice(previousClose: 9.87, board: .shMain, isST: false) ?? 0, 10.86)
        XCTAssertEqual(MarketBoardRule.limitDownPrice(previousClose: 9.87, board: .shMain, isST: false) ?? 0, 8.88)
        // ST 5%：10.00 → 10.50 / 9.50
        XCTAssertEqual(MarketBoardRule.limitUpPrice(previousClose: 10.0, board: .szMain, isST: true) ?? 0, 10.5)
        // 创业板 20%：10.00 → 12.00 / 8.00
        XCTAssertEqual(MarketBoardRule.limitUpPrice(previousClose: 10.0, board: .chiNext, isST: false) ?? 0, 12.0)
        XCTAssertEqual(MarketBoardRule.limitDownPrice(previousClose: 10.0, board: .chiNext, isST: false) ?? 0, 8.0)
        // 非法前收盘价
        XCTAssertNil(MarketBoardRule.limitUpPrice(previousClose: 0, board: .shMain, isST: false))
        XCTAssertNil(MarketBoardRule.limitDownPrice(previousClose: -1, board: .shMain, isST: false))
    }

    func testLimitUpJudgment() {
        // 计算口径：10.00 主板 → 涨停 11.00
        XCTAssertTrue(MarketBoardRule.isLimitUp(price: 11.0, previousClose: 10.0, board: .shMain, isST: false))
        XCTAssertTrue(MarketBoardRule.isLimitUp(price: 11.004, previousClose: 10.0, board: .shMain, isST: false), "半分容差内算触板")
        XCTAssertFalse(MarketBoardRule.isLimitUp(price: 10.99, previousClose: 10.0, board: .shMain, isST: false))
        // 源直接给出涨停价优先
        XCTAssertTrue(MarketBoardRule.isLimitUp(price: 11.02, previousClose: 10.0, board: .shMain, isST: false, sourceLimitUpPrice: 11.02))
        XCTAssertFalse(MarketBoardRule.isLimitUp(price: 0, previousClose: 10.0, board: .shMain, isST: false))
    }

    func testLimitDownJudgment() {
        XCTAssertTrue(MarketBoardRule.isLimitDown(price: 9.0, previousClose: 10.0, board: .shMain, isST: false))
        XCTAssertFalse(MarketBoardRule.isLimitDown(price: 9.5, previousClose: 10.0, board: .shMain, isST: false))
        XCTAssertTrue(MarketBoardRule.isLimitDown(price: 9.5, previousClose: 10.0, board: .szMain, isST: true, sourceLimitDownPrice: 9.5))
    }

    func testBareACodeNormalization() {
        XCTAssertEqual(MarketCodeNormalizer.bareACode(from: "sh600519"), "600519")
        XCTAssertEqual(MarketCodeNormalizer.bareACode(from: "SZ000001"), "000001")
        XCTAssertEqual(MarketCodeNormalizer.bareACode(from: "600519.SH"), "600519")
        XCTAssertEqual(MarketCodeNormalizer.bareACode(from: "1.600519"), "600519")
        XCTAssertEqual(MarketCodeNormalizer.bareACode(from: " 600519 "), "600519")
    }

    func testCanonicalKeyNormalization() {
        XCTAssertEqual(MarketCodeNormalizer.canonicalKey(for: "0700.HK"), "HK00700")
        XCTAssertEqual(MarketCodeNormalizer.canonicalKey(for: "hk700"), "HK00700")
        XCTAssertEqual(MarketCodeNormalizer.canonicalKey(for: "HK00700"), "HK00700")
        XCTAssertEqual(MarketCodeNormalizer.canonicalKey(for: "600519"), "600519")
    }
}

// MARK: - 市场广度计算

final class MarketBreadthCalculatorTests: XCTestCase {
    func testComputeCountsUpDownFlatAndLimits() {
        let quotes = [
            // 普通上涨：10.2 vs 10.0
            MarketQuote(code: "600001", price: 10.2, previousClose: 10.0, board: .shMain),
            // 普通下跌
            MarketQuote(code: "000002", price: 9.8, previousClose: 10.0, board: .szMain),
            // 平盘
            MarketQuote(code: "600003", price: 10.0, previousClose: 10.0, board: .shMain),
            // 主板涨停：11.0 = 10.0 × 1.1
            MarketQuote(code: "600004", price: 11.0, previousClose: 10.0, board: .shMain),
            // ST 跌停：9.5 = 10.0 × 0.95
            MarketQuote(code: "000005", name: "ST样本", price: 9.5, previousClose: 10.0, isST: true, board: .szMain),
            // 创业板涨停：12.0 = 10.0 × 1.2
            MarketQuote(code: "300006", price: 12.0, previousClose: 10.0, board: .chiNext),
            // 前收盘价缺失，按涨跌幅反推：price 10.05, pct 0.5 → pre 10.0（涨）
            MarketQuote(code: "600007", price: 10.05, changePct: 0.5, amount: 1e8, board: .shMain),
        ]
        let stats = MarketBreadthCalculator.compute(quotes: quotes, computedAt: "2026-08-28 15:00:00")

        XCTAssertEqual(stats.sampleCount, 7)
        XCTAssertEqual(stats.upCount, 4)   // 600001 / 600004 / 300006 / 600007
        XCTAssertEqual(stats.downCount, 2) // 000002 / 000005
        XCTAssertEqual(stats.flatCount, 1) // 600003
        XCTAssertEqual(stats.limitUpCount, 2)
        XCTAssertEqual(stats.limitDownCount, 1)
        XCTAssertEqual(stats.totalAmountYi ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(stats.excludedCount, 0)
        XCTAssertTrue(stats.dataBoundary.contains("前收盘价按涨跌幅反推"))
        XCTAssertTrue(stats.advanceDeclineSummary.contains("上涨 4"))
        XCTAssertTrue(stats.limitSummary.contains("涨停 2"))
    }

    func testComputeExcludesUnusableQuotes() {
        let quotes = [
            MarketQuote(code: "600001", price: nil, previousClose: 10.0),
            MarketQuote(code: "600002", price: 10.0, previousClose: nil, changePct: nil),
            MarketQuote(code: "600003", price: 10.0, previousClose: 10.0, board: .shMain),
        ]
        let stats = MarketBreadthCalculator.compute(quotes: quotes, computedAt: "t")
        XCTAssertEqual(stats.sampleCount, 1)
        XCTAssertEqual(stats.excludedCount, 2)
        XCTAssertEqual(stats.flatCount, 1)
        XCTAssertTrue(stats.dataBoundary.contains("2 只因缺价格/前收盘价未计入"))
    }

    func testComputePrefersSourceLimitPrice() {
        // 源给出的涨停价与规则计算不一致时，以源为准（例：新股上市无涨跌停限制场景反向）
        let quotes = [
            MarketQuote(code: "301999", price: 15.0, previousClose: 10.0, limitUpPrice: 15.0, board: .chiNext),
        ]
        let stats = MarketBreadthCalculator.compute(quotes: quotes, computedAt: "t")
        XCTAssertEqual(stats.limitUpCount, 1)
    }
}
