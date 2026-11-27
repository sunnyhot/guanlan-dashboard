import XCTest
@testable import QiemanDashboard

// MARK: - 估值校准台账

final class FundEstimateCalibrationTests: XCTestCase {
    /// 用公开 API 走「记录 → 结算」构造一条已结算记录。
    static func settle(_ ledger: inout FundEstimateCalibrationLedger, code: String, date: String, est: Double, actual: Double, source: String) {
        ledger.recordEstimate(
            FundEstimateCalibrationRecord(fundCode: code, tradeDate: date, estimatedChangePct: est, source: source, estimatedAt: "\(date) 14:50")
        )
        ledger.settle(fundCode: code, actualChangePctByDate: [date: actual], settledAt: "t")
    }

    private func record(
        _ code: String, _ date: String, est: Double, actual: Double? = nil, source: String = "s"
    ) -> FundEstimateCalibrationRecord {
        FundEstimateCalibrationRecord(
            fundCode: code, tradeDate: date, estimatedChangePct: est, source: source,
            estimatedAt: "\(date) 14:50", actualChangePct: actual, settledAt: actual == nil ? nil : "x"
        )
    }

    func testStatsComputeBiasRmseAndConfidence() {
        // 估算系统性偏低 0.2：真实总是比估算高 0.2 → bias = +0.2
        let errors = [0.2, 0.2, 0.2, 0.2]
        let stats = FundEstimateAccuracyStats.compute(errors: errors, tradeDates: ["d1", "d2", "d3", "d4"])
        XCTAssertEqual(stats.biasPct, 0.2, accuracy: 1e-9)
        XCTAssertEqual(stats.rmsePct, 0.2, accuracy: 1e-9)
        XCTAssertEqual(stats.confidence, .medium)
    }

    func testConfidenceBands() {
        XCTAssertEqual(FundEstimateConfidence.from(rmse: nil, sampleCount: 99), .unknown)
        XCTAssertEqual(FundEstimateConfidence.from(rmse: 0.1, sampleCount: 2), .unknown, "样本不足")
        XCTAssertEqual(FundEstimateConfidence.from(rmse: 0.1, sampleCount: 5), .high)
        XCTAssertEqual(FundEstimateConfidence.from(rmse: 0.3, sampleCount: 5), .medium)
        XCTAssertEqual(FundEstimateConfidence.from(rmse: 0.9, sampleCount: 5), .low)
    }

    func testRecordAndSettleLifecycle() {
        var ledger = FundEstimateCalibrationLedger()
        XCTAssertTrue(ledger.recordEstimate(record("F1", "2026-11-26", est: 1.0)))
        XCTAssertEqual(ledger.pendingCount, 1)

        // 同日更晚的估算覆盖
        var later = record("F1", "2026-11-26", est: 1.2)
        later = FundEstimateCalibrationRecord(
            fundCode: "F1", tradeDate: "2026-11-26", estimatedChangePct: 1.2, source: "s", estimatedAt: "2026-11-26 14:55"
        )
        XCTAssertTrue(ledger.recordEstimate(later))
        XCTAssertEqual(ledger.pendingByFund["F1"]?.estimatedChangePct, 1.2)

        // 非对应日期不结算
        XCTAssertEqual(ledger.settle(fundCode: "F1", actualChangePctByDate: ["2026-11-25": 1.5], settledAt: "t"), 0)
        // 对应日期结算
        XCTAssertEqual(ledger.settle(fundCode: "F1", actualChangePctByDate: ["2026-11-26": 1.5], settledAt: "t"), 1)
        XCTAssertEqual(ledger.pendingCount, 0)
        XCTAssertEqual(ledger.settledCount, 1)
        XCTAssertEqual(ledger.allSettledRecords.first?.errorPct ?? 0, 0.3, accuracy: 1e-9)
    }

    func testDebiasRemovesSystematicError() {
        var ledger = FundEstimateCalibrationLedger()
        for i in 0..<5 {
            let d = String(format: "2026-11-%02d", 10 + i)
            Self.settle(&ledger, code: "F1", date: d, est: 1.0, actual: 1.3, source: "src") // 真实恒比估算高 0.3
        }
        let debiased = ledger.debiasedChangePct(2.0, fundCode: "F1", source: "src")
        XCTAssertEqual(debiased, 2.3, accuracy: 1e-9, "估算 2.0 + 偏差 0.3")
        // 其它来源不受影响
        XCTAssertEqual(ledger.debiasedChangePct(2.0, fundCode: "F1", source: "other"), 2.0)
        // 样本不足不修正
        XCTAssertEqual(ledger.debiasedChangePct(2.0, fundCode: "F2", source: "src"), 2.0)
    }

    func testPruneStalePending() {
        var ledger = FundEstimateCalibrationLedger()
        ledger.recordEstimate(record("OLD", "2020-01-01", est: 1.0))
        ledger.recordEstimate(record("NEW", "2999-01-01", est: 1.0))
        ledger.pruneStalePending(olderThanDays: 14, now: Date())
        XCTAssertNil(ledger.pendingByFund["OLD"])
        XCTAssertNotNil(ledger.pendingByFund["NEW"])
    }

    func testCodableRoundTrip() throws {
        var ledger = FundEstimateCalibrationLedger()
        ledger.recordEstimate(record("F1", "2026-11-26", est: 1.0))
        Self.settle(&ledger, code: "F2", date: "2026-11-25", est: 0.5, actual: 0.7, source: "s")
        let data = try JSONEncoder().encode(ledger)
        let decoded = try JSONDecoder().decode(FundEstimateCalibrationLedger.self, from: data)
        XCTAssertEqual(decoded.pendingByFund["F1"]?.estimatedChangePct, 1.0)
        XCTAssertEqual(decoded.settledByFund["F2"]?.first?.actualChangePct, 0.7)
    }
}

// MARK: - 持仓穿透估值

final class FundHoldingsEstimateEngineTests: XCTestCase {
    private func holding(_ code: String, _ name: String, _ w: Double, kind: FundUnderlyingAssetKind = .stock) -> FundUnderlyingHolding {
        FundUnderlyingHolding(code: code, name: name, kind: kind, weightPct: w, disclosureDate: "2026-09-30")
    }
    private func industry(_ name: String, _ w: Double) -> FundIndustryExposure {
        FundIndustryExposure(name: name, weightPct: w, disclosureDate: "2026-09-30")
    }
    private let recentAsOf = ISO8601DateFormatter().string(from: Date())

    func testFullyDisclosedFundMatchesWeightedSum() {
        let input = FundHoldingsEstimateInput(
            fundCode: "X", holdings: [holding("600519", "茅台", 10), holding("300750", "宁德", 8)],
            industries: [industry("制造业", 18)], assetAllocation: FundAssetAllocation(stockPct: 18, bondPct: 0, cashPct: 82, otherPct: nil, disclosureDate: "2026-09-30"),
            asOf: "2026-09-30", stockChangePcts: ["600519": 2.0, "300750": -1.0], proxyChangePcts: [:], bondProxyChangePct: nil
        )
        let r = FundHoldingsEstimateEngine.estimate(input: input, officialNav: 1.0, now: Date())!
        // 10% × 2% + 8% × (−1%) = 0.2 − 0.08 = 0.12
        XCTAssertEqual(r.changePct, 0.12, accuracy: 1e-9)
        XCTAssertEqual(r.coveredWeightPct, 18, accuracy: 1e-9)
        XCTAssertEqual(r.proxiedWeightPct, 0, accuracy: 1e-9)
        XCTAssertEqual(r.estimatedNav, 1.0012, accuracy: 1e-9)
    }

    func testUndisclosedStockWeightGoesToIndustryProxy() {
        // 前十大只占 40%，股票仓位 90% → 剩余 50% 按行业代理
        let input = FundHoldingsEstimateInput(
            fundCode: "X", holdings: [holding("600519", "茅台", 40)],
            industries: [industry("制造业", 60), industry("金融业", 30)],
            assetAllocation: FundAssetAllocation(stockPct: 90, bondPct: 5, cashPct: 5, otherPct: nil, disclosureDate: "2026-09-30"),
            asOf: "2026-09-30", stockChangePcts: ["600519": 1.0],
            proxyChangePcts: ["sh000300": 0.5, "sh000992": -0.4, "sh000012": 0.01], bondProxyChangePct: 0.01
        )
        let r = FundHoldingsEstimateEngine.estimate(input: input, officialNav: 2.0, now: Date())!
        // 已披露 40 × 1% = 0.40；剩余 50%：制造业 2/3 × 0.5% + 金融 1/3 × (−0.4%) = 0.1667 − 0.0667 = 0.10；债券 5 × 0.01% ≈ 0.0005
        XCTAssertEqual(r.coveredWeightPct, 40, accuracy: 1e-9)
        XCTAssertEqual(r.proxiedWeightPct, 55, accuracy: 1e-9, "50 行业 + 5 债券")
        XCTAssertEqual(r.changePct, 0.40 + 0.10 + 0.0005, accuracy: 1e-6)
    }

    func testBondFundUsesBondProxyNotStock() {
        let input = FundHoldingsEstimateInput(
            fundCode: "B", holdings: [holding("019547", "国债", 80, kind: .bond)],
            industries: [], assetAllocation: FundAssetAllocation(stockPct: 0, bondPct: 90, cashPct: 10, otherPct: nil, disclosureDate: "2026-09-30"),
            asOf: "2026-09-30", stockChangePcts: [:], proxyChangePcts: ["sh000300": 3.0, "sh000012": 0.05], bondProxyChangePct: 0.05
        )
        let r = FundHoldingsEstimateEngine.estimate(input: input, officialNav: 1.0, now: Date())!
        XCTAssertEqual(r.changePct, 90 * 0.05 / 100, accuracy: 1e-9, "债基不应受沪深300影响")
        XCTAssertNil(r.topContributors.first { $0.code == "sh000300" })
    }

    private func makeInput(asOf: String) -> FundHoldingsEstimateInput {
        FundHoldingsEstimateInput(
            fundCode: "X", holdings: [holding("600519", "茅台", 90)],
            industries: [], assetAllocation: nil,
            asOf: asOf, stockChangePcts: ["600519": 4.0], proxyChangePcts: ["sh000300": 0.0], bondProxyChangePct: nil
        )
    }

    func testStaleDisclosureShrinksTowardBroadIndex() {
        let stale = FundHoldingsEstimateEngine.estimate(input: makeInput(asOf: "2020-01-01"), officialNav: 1.0, now: Date())!
        XCTAssertTrue(stale.isStale)
        XCTAssertLessThan(stale.changePct, 3.6, "陈旧披露应向宽基收缩（×0.7）")
        let fresh = FundHoldingsEstimateEngine.estimate(input: makeInput(asOf: recentAsOf), officialNav: 1.0, now: Date())!
        XCTAssertFalse(fresh.isStale)
        XCTAssertEqual(fresh.changePct, 3.6, accuracy: 1e-9)
    }

    func testNormalizesStockKeys() {
        XCTAssertEqual(FundHoldingsEstimateEngine.normalizedStockKey("600519"), "600519")
        XCTAssertEqual(FundHoldingsEstimateEngine.normalizedStockKey("HK00700"), "HK00700")
        XCTAssertEqual(FundHoldingsEstimateEngine.normalizedStockKey("00700.HK"), "HK00700")
        XCTAssertEqual(FundHoldingsEstimateEngine.normalizedStockKey("AAPL"), "AAPL")
        XCTAssertEqual(FundHoldingsEstimateEngine.normalizedStockKey("sh600519"), "600519")
    }

    func testIndustryProxyMapping() {
        XCTAssertEqual(FundEstimateProxyMap.proxy(forIndustryName: "制造业")?.symbol, "sh000300")
        XCTAssertEqual(FundEstimateProxyMap.proxy(forIndustryName: "非必需消费品")?.symbol, "sh513050")
        XCTAssertEqual(FundEstimateProxyMap.proxy(forIndustryName: "电信服务")?.symbol, "sh513130")
        XCTAssertNil(FundEstimateProxyMap.proxy(forIndustryName: "不存在的行业"))
    }
}

// MARK: - 融合引擎

final class FundEstimateFusionEngineTests: XCTestCase {
    // 固定「现在」：2026-11-27 14:30 Asia/Shanghai
    private var now: Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: "2026-11-27 14:30:00")!
    }

    func testRejectsStaleDatedCandidates() {
        let stale = FundEstimateCandidate(source: "a", sourceLabel: "A", changePct: 1, estimatedNav: 1.01, estimatedAt: "2026-11-26 14:50")
        XCTAssertNil(FundEstimateFusionEngine.fuse(candidates: [stale], fundCode: "F", officialNav: 1, ledger: .init(), now: now))
    }

    func testSingleCandidateIsDebiased() {
        var ledger = FundEstimateCalibrationLedger()
        for i in 0..<4 {
            FundEstimateCalibrationTests.settle(&ledger, code: "F", date: "d\(i)", est: 1.0, actual: 1.4, source: "a")
        }
        let c = FundEstimateCandidate(source: "a", sourceLabel: "A", changePct: 2.0, estimatedNav: 1.02, estimatedAt: "2026-11-27 14:20")
        let r = FundEstimateFusionEngine.fuse(candidates: [c], fundCode: "F", officialNav: 1, ledger: ledger, now: now)!
        XCTAssertEqual(r.changePct, 2.4, accuracy: 1e-9)
        XCTAssertEqual(r.fusedSourceCount, 1)
        XCTAssertFalse(r.hasSignificantDisagreement)
    }

    func testCalibratedSourceOutweighsUnreliableOne() {
        var ledger = FundEstimateCalibrationLedger()
        // 源 "good" 几乎无误差；源 "bad" 误差 1.0
        for i in 0..<6 {
            FundEstimateCalibrationTests.settle(&ledger, code: "F", date: "g\(i)", est: 1.0, actual: 1.02, source: "good")
            FundEstimateCalibrationTests.settle(&ledger, code: "F", date: "b\(i)", est: 1.0, actual: 2.0, source: "bad")
        }
        let good = FundEstimateCandidate(source: "good", sourceLabel: "G", changePct: 1.0, estimatedNav: 1.01, estimatedAt: "2026-11-27 14:25")
        let bad = FundEstimateCandidate(source: "bad", sourceLabel: "B", changePct: 3.0, estimatedNav: 1.03, estimatedAt: "2026-11-27 14:25")
        let r = FundEstimateFusionEngine.fuse(candidates: [good, bad], fundCode: "F", officialNav: 1, ledger: ledger, now: now)!
        XCTAssertEqual(r.primarySource, "good")
        XCTAssertLessThan(abs(r.changePct - 1.0), abs(r.changePct - 3.0), "应更靠近可信源")
        XCTAssertEqual(r.confidence, .high, "整体 RMSE 由两源合并决定，但 good 占主导")
    }

    func testTrackingIndexIsAuthoritativeWhenUncalibrated() {
        // 指数基金：跟踪指数 +1.0%，第三方估值 +3.0%（明显高估）。未校准时跟踪指数应主导（其它源 ×0.3）。
        let index = FundEstimateCandidate(source: FundEstimateSource.trackingIndex.rawValue, sourceLabel: "跟踪指数", changePct: 1.0, estimatedNav: 1.01, estimatedAt: "2026-11-27 14:25", intrinsicConfidence: 0.95)
        let sina = FundEstimateCandidate(source: FundEstimateSource.sinaEstimate.rawValue, sourceLabel: "新浪", changePct: 3.0, estimatedNav: 1.03, estimatedAt: "2026-11-27 14:25", intrinsicConfidence: 0.8)
        let r = FundEstimateFusionEngine.fuse(candidates: [index, sina], fundCode: "F", officialNav: 1, ledger: .init(), now: now)!
        XCTAssertEqual(r.primarySource, FundEstimateSource.trackingIndex.rawValue)
        // 权重：跟踪指数 0.95，新浪 0.8 × 0.3 = 0.24 → 跟踪指数占 0.95/1.19 ≈ 0.798
        // 融合 = 1.0 × 0.798 + 3.0 × 0.202 ≈ 1.40，明显偏向跟踪指数而非两者的简单平均 2.0
        XCTAssertEqual(r.changePct, 1.403, accuracy: 0.01)
        XCTAssertLessThan(r.changePct, 2.0, "必须比简单平均更靠近跟踪指数")
    }

    func testDisagreementFlag() {
        let a = FundEstimateCandidate(source: "a", sourceLabel: "A", changePct: 1.0, estimatedNav: 1.01, estimatedAt: "2026-11-27 14:20")
        let b = FundEstimateCandidate(source: "b", sourceLabel: "B", changePct: 1.5, estimatedNav: 1.015, estimatedAt: "2026-11-27 14:20")
        let r = FundEstimateFusionEngine.fuse(candidates: [a, b], fundCode: "F", officialNav: 1, ledger: .init(), now: now)!
        XCTAssertTrue(r.hasSignificantDisagreement)
        XCTAssertEqual(r.maxDisagreementPct ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertTrue(r.sourceLabel.contains("A"))
        XCTAssertTrue(r.sourceLabel.contains("B"))
    }

    func testFreshnessFactorDecaysAndFloor() {
        XCTAssertEqual(FundEstimateFusionEngine.freshnessFactor(estimatedAt: "2026-11-27 14:30", now: now), 1.0, accuracy: 1e-9)
        XCTAssertEqual(FundEstimateFusionEngine.freshnessFactor(estimatedAt: "2026-11-27 14:10", now: now), 0.5, accuracy: 1e-9, "半衰期 20 分钟")
        XCTAssertEqual(FundEstimateFusionEngine.freshnessFactor(estimatedAt: "2026-11-27 06:00", now: now), FundEstimateFusionEngine.minimumFreshnessFactor, accuracy: 1e-9)
    }

    func testParsesTencentTimeFormats() {
        XCTAssertNotNil(FundEstimateFusionEngine.parseEstimateTime("2026-11-27 14:30:00"))
        XCTAssertNotNil(FundEstimateFusionEngine.parseEstimateTime("2026-11-27 14:30"))
        XCTAssertNotNil(FundEstimateFusionEngine.parseEstimateTime("2026/11/27 15:48:28"), "港股斜杠格式")
        XCTAssertNotNil(FundEstimateFusionEngine.parseEstimateTime("2026-11-27"), "仅日期按 15:00")
        XCTAssertNil(FundEstimateFusionEngine.parseEstimateTime(""))
    }

    func testRecentStaleQuoteStillFusesButDownweighted() {
        // 40 分钟前的报价仍参与，但权重为 25%
        XCTAssertEqual(FundEstimateFusionEngine.freshnessFactor(estimatedAt: "2026-11-27 13:50", now: now), 0.25, accuracy: 1e-9)
        XCTAssertTrue(FundEstimateFusionEngine.isToday("2026-11-27 09:30", now: now))
        XCTAssertFalse(FundEstimateFusionEngine.isToday("2026-11-26 14:50", now: now))
    }
}

// MARK: - 跟踪指数

final class FundTrackingIndexTests: XCTestCase {
    func testParsesProfileTable() {
        let html = """
        <table><tr><th>基金类型</th><td>指数型-股票</td></tr>
        <tr><th>跟踪标的</th><td>沪深300指数</td></tr>
        <tr><th>业绩比较基准</th><td>沪深300指数收益率*95%</td></tr></table>
        """
        let p = FundProfileParser.parse(html)!
        XCTAssertEqual(p.fundType, "指数型-股票")
        XCTAssertEqual(p.trackingTarget, "沪深300指数")
        XCTAssertEqual(p.benchmark, "沪深300指数收益率*95%")
        XCTAssertTrue(p.isIndexFund)
    }

    func testParsesWithAttributesAndEntities() {
        let html = """
        <th class="t">基金类型</th><td class="w">联接基金-股票</td>
        <th>跟踪标的</th><td>中证500指数&nbsp;</td>
        """
        let p = FundProfileParser.parse(html)!
        XCTAssertEqual(p.fundType, "联接基金-股票")
        XCTAssertEqual(p.trackingTarget, "中证500指数")
        XCTAssertTrue(p.isETFFeeder)
    }

    func testNonIndexFundHasNoTarget() {
        let html = "<th>基金类型</th><td>混合型-偏股</td><th>跟踪标的</th><td>--</td>"
        let p = FundProfileParser.parse(html)!
        XCTAssertFalse(p.isIndexFund)
    }

    func testTargetMapping() {
        XCTAssertEqual(FundTrackingIndexMap.target(forTrackingTarget: "沪深300指数")?.symbol, "sh000300")
        XCTAssertEqual(FundTrackingIndexMap.target(forTrackingTarget: "中证海外中国互联网50人民币指数")?.symbol, "sh513050", "宽松匹配去掉指数后缀")
        XCTAssertEqual(FundTrackingIndexMap.target(forTrackingTarget: "国证半导体芯片指数")?.symbol, "sz159995", "腾讯无国证芯片指数，用芯片ETF代理")
        XCTAssertEqual(FundTrackingIndexMap.target(forTrackingTarget: "恒生科技指数")?.symbol, "hkHSTECH")
        XCTAssertEqual(FundTrackingIndexMap.target(forTrackingTarget: "北证50指数")?.symbol, "bj899050")
        XCTAssertNil(FundTrackingIndexMap.target(forTrackingTarget: "某某不认识指数"))
    }

    func testFuzzyPrefersLongerKeyword() {
        XCTAssertEqual(FundTrackingIndexMap.target(forTrackingTarget: "恒生科技指数")?.symbol, "hkHSTECH", "不应被「恒生」抢先")
        XCTAssertEqual(FundTrackingIndexMap.target(forTrackingTarget: "中证红利低波动指数")?.symbol, "sh512890", "红利低波动用ETF代理（sz399812实为养老产业）")
    }
}

// MARK: - 腾讯批量行情解析

final class TencentBatchQuoteParsingTests: XCTestCase {
    func testFormatsHongKongSlashTime() {
        // 港股行情时间 "2026/11/27 15:48:28" 必须归一为 "2026-11-27 15:48:28"，
        // 否则融合引擎会把它当隔天数据排除（曾导致恒生指数基金落到错误的沪深300兜底）。
        let hk = """
        v_hkHSI="100~恒生指数~HSI~22664.670~22226.880~22263.700~23716339.7790~0~0~22664.670~0~0~0~0~0~0~0~0~0~22664.670~0~0~0~0~0~0~0~0~0~0.0~2026/11/27 15:48:28~437.790~1.97~22800~22100~22664/22263~237~0.00~0";
        """
        let client = QiemanPlatformNativeClient()
        let quote = client.parseTencentQuoteLines(hk).first?.1
        XCTAssertEqual(quote?.priceTime, "2026-11-27 15:48:28")
        XCTAssertEqual(quote?.changePct ?? 0, 1.97, accuracy: 1e-9)
        // 归一后必须被识别为「今天」
        let now = FundEstimateFusionEngine.parseEstimateTime("2026-11-27 16:00:00")!
        XCTAssertTrue(FundEstimateFusionEngine.isToday(quote?.priceTime ?? "", now: now))
    }

    func testParsesMultipleLines() {
        let text = """
        v_sh600519="1~贵州茅台~600519~1500.00~1480.00~1485.00~100~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~~20261127143000~20~1.35~1505~1479~1500/1480~100~0.01~0";
        v_sz000001="51~平安银行~000001~11.50~11.40~11.42~200~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~~20261127143001~0.10~0.88~11.55~11.35~11.50/11.40~200~0.02~0";
        """
        let client = QiemanPlatformNativeClient()
        let pairs = client.parseTencentQuoteLines(text)
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs[0].0, "sh600519")
        XCTAssertEqual(pairs[0].1.price, 1500.0, accuracy: 1e-9)
        XCTAssertEqual(pairs[0].1.changePct ?? 0, 1.35, accuracy: 1e-9)
        XCTAssertEqual(pairs[0].1.priceTime, "2026-11-27 14:30:00")
    }

    func testTencentSymbolMapping() {
        let client = QiemanPlatformNativeClient()
        XCTAssertEqual(client.tencentSymbol(forKey: "600519"), "sh600519")
        XCTAssertEqual(client.tencentSymbol(forKey: "000001"), "sz000001")
        XCTAssertEqual(client.tencentSymbol(forKey: "830799"), "bj830799", "北交所")
        XCTAssertEqual(client.tencentSymbol(forKey: "HK00700"), "hk00700")
        XCTAssertEqual(client.tencentSymbol(forKey: "AAPL"), "usaapl")
        XCTAssertNil(client.tencentSymbol(forKey: ""))
    }
}
