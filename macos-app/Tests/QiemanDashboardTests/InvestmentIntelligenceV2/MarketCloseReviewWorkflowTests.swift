import XCTest
@testable import QiemanDashboard

// MARK: - MarketCloseReviewWorkflow 测试（审计 A1）
//
// 覆盖：纯计算确定性（同输入同 ID）、LLM 叙述成功（narrativeSource = llm）、
// LLM 失败降级（不阻断冻结，narrativeSource = localFactors）、本地因子
// 叙述派生、新鲜度状态机（上海 21:00 日界）。

final class MarketCloseReviewWorkflowTests: XCTestCase {

    private let reviewDate = Date(timeIntervalSince1970: 1_800_000_000)
    private let now = Date(timeIntervalSince1970: 1_800_003_600)

    private func makeInput() -> MarketCloseReviewWorkflow.Input {
        MarketCloseReviewWorkflow.Input(
            portfolioKey: "app:userPortfolio",
            reviewDate: reviewDate,
            portfolioReview: MarketCloseReview.PortfolioReview(
                totalMarketValue: 100_000,
                dailyChangeAmount: 1_234.5,
                dailyChangePct: 1.25,
                holdingCount: 5,
                coveredHoldingCount: 4,
                topImpacts: [
                    .init(name: "基金A", code: "000001", changeAmount: 800, changePct: 2.1),
                    .init(name: "基金B", code: "000002", changeAmount: -300, changePct: -0.8),
                ]),
            marketDigest: [
                .init(name: "沪深300", changePct: 1.2, kind: "index"),
                .init(name: "中证1000", changePct: -0.6, kind: "index"),
                .init(name: "白酒因子", factorScore: 1.5, kind: "factor"),
                .init(name: "地产因子", factorScore: -1.2, kind: "factor"),
            ],
            tomorrowWatch: ["关注：单一持仓集中（40.0%）"],
            dataBoundary: "估值覆盖 5/5 · 涨跌覆盖 4/5",
            attributionArtifactID: "attr_test123")
    }

    func testDeterministicIDWithoutNarrativeProvider() async {
        let workflow = MarketCloseReviewWorkflow(narrativeProvider: nil)
        let first = await workflow.run(input: makeInput(), now: now)
        let second = await workflow.run(input: makeInput(), now: now)

        XCTAssertTrue(first.succeeded)
        XCTAssertNotNil(first.artifact)
        XCTAssertEqual(first.artifact?.id, second.artifact?.id, "同输入同 ID（producedAt 不参与身份）")
        XCTAssertEqual(first.artifact?.validityPolicy, .immutableHistorical)
        XCTAssertEqual(first.artifact?.narrativeSource, .localFactors)
        XCTAssertFalse(first.narrativeFallback, "无 Provider 是常规路径，不算降级")
        XCTAssertEqual(first.artifact?.portfolioReview?.dailyChangeAmount ?? 0, 1_234.5, accuracy: 0.001)
        XCTAssertEqual(first.artifact?.attributionArtifactID, "attr_test123")
    }

    func testLLMNarrativeUsedWhenProviderSucceeds() async {
        let narrative = CloseReviewNarrative(
            marketPulse: [
                .init(name: "沪深300", direction: .up, confidenceText: "证据较强", rationale: "涨 1.2% 领先"),
            ],
            strongThemes: [.init(name: "白酒", direction: .strong, rationale: "因子评分领先")],
            weakThemes: [])
        let workflow = MarketCloseReviewWorkflow(narrativeProvider: { _ in narrative })
        let outcome = await workflow.run(input: makeInput(), now: now)

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.artifact?.narrativeSource, .llm)
        XCTAssertEqual(outcome.artifact?.marketPulse.first?.name, "沪深300")
        XCTAssertEqual(outcome.artifact?.strongThemes.count, 1)
        XCTAssertFalse(outcome.narrativeFallback)
    }

    func testLLMFailureFallsBackToLocalFactors() async {
        struct Boom: Error {}
        let workflow = MarketCloseReviewWorkflow(narrativeProvider: { _ in throw Boom() })
        let outcome = await workflow.run(input: makeInput(), now: now)

        // 冻结不被 LLM 失败阻断：artifact 照常产出，叙述降级本地因子
        XCTAssertTrue(outcome.succeeded)
        XCTAssertNotNil(outcome.artifact)
        XCTAssertEqual(outcome.artifact?.narrativeSource, .localFactors)
        XCTAssertTrue(outcome.narrativeFallback)
        // 本地因子版从摘要派生：指数 → 脉搏；因子首尾 → 强弱主题
        XCTAssertEqual(outcome.artifact?.marketPulse.count, 2)
        XCTAssertEqual(outcome.artifact?.marketPulse.first?.direction, .up)
        XCTAssertEqual(outcome.artifact?.strongThemes.first?.name, "白酒因子")
        XCTAssertEqual(outcome.artifact?.weakThemes.first?.name, "地产因子")
    }

    func testLocalNarrativeFromEmptyDigest() {
        let narrative = MarketCloseReviewWorkflow.localNarrative(from: [])
        XCTAssertTrue(narrative.marketPulse.isEmpty)
        XCTAssertTrue(narrative.strongThemes.isEmpty)
        XCTAssertTrue(narrative.weakThemes.isEmpty)
    }

    func testTomorrowWatchCappedAtThree() async {
        var input = makeInput()
        input.tomorrowWatch = ["一", "二", "三", "四", "五"]
        let workflow = MarketCloseReviewWorkflow(narrativeProvider: nil)
        let outcome = await workflow.run(input: input, now: now)
        XCTAssertEqual(outcome.artifact?.tomorrowWatch.count, 3, "明日关注 ≤3 条（V1 语义）")
    }
}

// MARK: - 新鲜度状态机

final class MarketCloseReviewFreshnessTests: XCTestCase {

    /// 上海时区构造器。
    private func shanghaiDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testNeverGenerated() {
        XCTAssertEqual(
            MarketCloseReviewFreshness.evaluate(latestReviewDate: nil, producedAt: nil, now: shanghaiDate(2026, 8, 27, 15, 0)),
            .neverGenerated)
    }

    func testTodayDone() {
        let now = shanghaiDate(2026, 8, 27, 21, 30)
        XCTAssertEqual(
            MarketCloseReviewFreshness.evaluate(
                latestReviewDate: shanghaiDate(2026, 8, 27, 0, 0),
                producedAt: now, now: now),
            .todayDone)
    }

    func testYesterdayReviewBeforeCloseIsAwaitingTonight() {
        // 27 号白天只有 26 号的复盘 → 今晚 21:00 生成
        XCTAssertEqual(
            MarketCloseReviewFreshness.evaluate(
                latestReviewDate: shanghaiDate(2026, 8, 26, 0, 0),
                producedAt: shanghaiDate(2026, 8, 26, 21, 5),
                now: shanghaiDate(2026, 8, 27, 15, 0)),
            .awaitingTonight)
    }

    func testYesterdayReviewAfterCloseIsOverdue() {
        // 27 号 21:00 后仍只有 26 号的复盘 → 待补做
        XCTAssertEqual(
            MarketCloseReviewFreshness.evaluate(
                latestReviewDate: shanghaiDate(2026, 8, 26, 0, 0),
                producedAt: shanghaiDate(2026, 8, 26, 21, 5),
                now: shanghaiDate(2026, 8, 27, 21, 30)),
            .overdue)
    }
}

// MARK: - Codec 与查询（GRDB roundtrip）

final class MarketCloseReviewCodecTests: XCTestCase {

    func testWriteAndFetchRoundtrip() throws {
        let repository = GRDBRepository(
            database: try CanonicalDatabase(),
            calendarBackend: HolidayTableTradingCalendar.bundled)
        let review = MarketCloseReview(
            reviewDate: Date(timeIntervalSince1970: 1_800_000_000),
            portfolioKey: "app:userPortfolio",
            narrativeSource: .localFactors,
            portfolioReview: MarketCloseReview.PortfolioReview(
                totalMarketValue: 88_888,
                dailyChangeAmount: -120.5,
                dailyChangePct: -0.14,
                holdingCount: 3,
                coveredHoldingCount: 3,
                topImpacts: [.init(name: "基金X", code: "X1", changeAmount: -120.5, changePct: -0.14)]),
            marketPulse: [.init(name: "沪深300", direction: .down, confidenceText: "本地行情", rationale: "当日下跌 0.60%")],
            strongThemes: [],
            weakThemes: [.init(name: "地产因子", direction: .weak, rationale: "评分落后")],
            tomorrowWatch: ["关注：股票配置偏差"],
            dataBoundary: "估值覆盖 3/3 · 涨跌覆盖 3/3",
            attributionArtifactID: nil,
            producedAt: Date(timeIntervalSince1970: 1_800_003_600))

        try repository.writeMarketCloseReview(review)
        // 幂等重放
        try repository.writeMarketCloseReview(review)

        let queryService = ArtifactQueryService(repository: repository)
        let fetched = try queryService.marketCloseReview(id: review.id.rawValue)
        XCTAssertEqual(fetched, review, "GRDB 写读应无损回环")
        XCTAssertEqual(fetched?.id.rawValue, review.id.rawValue)

        let latest = try queryService.latestMarketCloseReviews(limit: 5)
        XCTAssertEqual(latest.count, 1)
        XCTAssertEqual(latest.first?.id, review.id)
    }
}
