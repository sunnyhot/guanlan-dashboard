import XCTest
@testable import QiemanDashboard

// MARK: - L6/L7/L8 App 集成（2026-08-31 接线）
//
// 覆盖：盘后结算调度守门（纯函数）、信号入库持久化/去重/反向失效（actor + Store 落盘）、
// 到期不可市价结算信号的 expiredUnresolved 路径、UI 汇总文案。

final class MarketSignalIntegrationTests: XCTestCase {

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = MarketPhase.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)!
    }

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("market-signal-integration-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSignal(
        dedupKey: String,
        direction: CanonicalDecisionType,
        subjectCode: String? = "600519",
        marketSettleable: Bool = true,
        createdAt: String = "2026-08-28 15:00:00",
        reviewDueAt: String = "2026-09-10 15:00:00"
    ) -> MarketDecisionSignal {
        MarketDecisionSignal(
            dedupKey: dedupKey,
            sourceKind: .trendReport,
            sourceActionID: String(dedupKey.suffix(2)),
            subjectCode: subjectCode,
            subjectName: "测试标的",
            marketSettleable: marketSettleable,
            direction: direction,
            action: direction == .buy ? .add : .reduce,
            score: 60,
            rawConfidence: 0.7,
            priceConditions: SignalPriceConditions(stopLoss: 9.8, targetPrice: 12.0),
            watchConditions: [],
            invalidatingConditions: [],
            reason: "集成测试信号",
            evidenceIDs: [],
            dataQualitySummary: "",
            createdAt: createdAt,
            reviewDueAt: reviewDueAt
        )
    }

    // MARK: - 盘后结算调度守门

    func testSchedulerShouldSettleTimeWindow() {
        let scheduler = AppModel.MarketSignalSettlementScheduler.self
        XCTAssertTrue(scheduler.shouldSettle(now: date("2026-08-31 15:35:00"), lastSettleDay: nil))
        XCTAssertTrue(scheduler.shouldSettle(now: date("2026-08-31 21:00:00"), lastSettleDay: nil))
        XCTAssertFalse(scheduler.shouldSettle(now: date("2026-08-31 15:34:59"), lastSettleDay: nil), "未到盘后时间")
    }

    func testSchedulerShouldSettleOncePerDay() {
        let scheduler = AppModel.MarketSignalSettlementScheduler.self
        XCTAssertFalse(
            scheduler.shouldSettle(now: date("2026-08-31 16:00:00"), lastSettleDay: "2026-08-31"),
            "同日已结算过"
        )
        XCTAssertTrue(
            scheduler.shouldSettle(now: date("2026-09-01 15:35:00"), lastSettleDay: "2026-08-31"),
            "次日盘后重新结算"
        )
        XCTAssertFalse(
            scheduler.shouldSettle(now: date("2026-09-01 09:00:00"), lastSettleDay: "2026-08-31"),
            "次日但未到盘后时间"
        )
    }

    // MARK: - 入库持久化 / 去重 / 反向失效

    func testIngestPersistsAcrossServiceInstances() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = date("2026-08-28 15:00:00")
        let signal = makeSignal(dedupKey: "trend|a1", direction: .buy)
        let first = try await MarketSignalService(
            store: MarketSignalStore(baseDirectory: dir), engine: nil, now: { now }
        ).ingest(signals: [signal])
        XCTAssertEqual(first.created, 1)

        // 新实例从磁盘加载（模拟 App 重启），同 dedupKey 7 天内去重
        let reloaded = MarketSignalService(
            store: MarketSignalStore(baseDirectory: dir), engine: nil, now: { now }
        )
        let all = await reloaded.allSignals()
        XCTAssertEqual(all.count, 1)
        let second = try await reloaded.ingest(signals: [signal])
        XCTAssertEqual(second.created, 0)
        XCTAssertEqual(second.duplicates, 1)
    }

    func testOppositeDirectionInvalidatesOldSignal() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = date("2026-08-28 15:00:00")
        let service = MarketSignalService(
            store: MarketSignalStore(baseDirectory: dir), engine: nil, now: { now }
        )
        _ = try await service.ingest(signals: [makeSignal(dedupKey: "trend|b1", direction: .buy)])
        let summary = try await service.ingest(
            signals: [makeSignal(dedupKey: "trend|s1", direction: .sell)]
        )
        XCTAssertEqual(summary.invalidatedOpposites, 1)
        let all = await service.allSignals()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(
            all.first { $0.dedupKey == "trend|b1" }?.status,
            .invalidated,
            "同标的反向信号出现后旧看多信号作废"
        )
    }

    // MARK: - 到期结算（无行情引擎 → 不可市价结算路径）

    func testSettleExpiresDueNonMarketSettleableSignal() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = date("2026-08-31 16:00:00")
        let service = MarketSignalService(
            store: MarketSignalStore(baseDirectory: dir), engine: nil, now: { now }
        )
        _ = try await service.ingest(
            signals: [
                makeSignal(
                    dedupKey: "trend|e1",
                    direction: .hold,
                    marketSettleable: false,
                    reviewDueAt: "2026-08-20 15:00:00"
                )
            ]
        )
        let summary = try await service.settleDueSignals()
        XCTAssertEqual(summary.expired, 1)
        let all = await service.allSignals()
        XCTAssertEqual(all.first?.status, .expiredUnresolved)
        XCTAssertEqual(all.first?.settlement?.outcome, .expiredUnresolved)
    }

    // MARK: - 汇总文案

    @MainActor
    func testSettleSummaryText() {
        var summary = MarketSignalService.SettleSummary()
        XCTAssertEqual(AppModel.marketSignalSettleSummaryText(summary), "上次盘后结算：无到期信号 · 活跃 0")
        summary.settledWin = 2
        summary.settledLoss = 1
        summary.expired = 1
        summary.stillActive = 5
        XCTAssertEqual(
            AppModel.marketSignalSettleSummaryText(summary),
            "上次盘后结算：兑现 2 · 止损 1 · 到期未触发 1 · 活跃 5"
        )
    }

    // MARK: - L1 广度预暖 + 注入（2026-08-31）

    func testBreadthPrewarmWindow() {
        XCTAssertTrue(AppModel.isMarketBreadthPrewarmWindow(now: date("2026-08-31 09:00:00")), "周一 09:00 开窗")
        XCTAssertTrue(AppModel.isMarketBreadthPrewarmWindow(now: date("2026-09-04 15:30:00")), "周五 15:30 关窗前")
        XCTAssertFalse(AppModel.isMarketBreadthPrewarmWindow(now: date("2026-08-31 08:59:00")), "未开盘")
        XCTAssertFalse(AppModel.isMarketBreadthPrewarmWindow(now: date("2026-08-31 15:31:00")), "已收盘")
        XCTAssertFalse(AppModel.isMarketBreadthPrewarmWindow(now: date("2026-09-05 10:00:00")), "周六不开窗")
        XCTAssertFalse(AppModel.isMarketBreadthPrewarmWindow(now: date("2026-09-06 10:00:00")), "周日不开窗")
    }

    func testBreadthContextFromStats() {
        var stats = MarketBreadthStats()
        XCTAssertEqual(NextHourGuidanceBreadthContext(stats: stats), nil, "零样本不注入")

        stats.upCount = 2800
        stats.downCount = 2100
        stats.flatCount = 200
        stats.limitUpCount = 45
        stats.limitDownCount = 8
        stats.totalAmountYi = 9876.5
        stats.sampleCount = 5100
        stats.computedAt = "2026-08-31 14:50:00"
        stats.dataBoundary = "样本含北交所"
        guard let context = NextHourGuidanceBreadthContext(stats: stats) else {
            return XCTFail("正样本应注入")
        }
        XCTAssertEqual(context.evidenceID, "market:breadth:2026-08-31", "证据 ID 与工具口径一致")
        XCTAssertTrue(context.summary.contains("上涨 2800"))
        XCTAssertTrue(context.summary.contains("涨停 45"))
        XCTAssertEqual(context.sampleCount, 5100)
        XCTAssertEqual(context.dataBoundary, "样本含北交所")
    }

    func testContextDecodesWithoutBreadthField() throws {
        // 旧版本 JSON 没有 marketBreadth 键 → 解码为 nil，行为与旧版一致
        let legacyJSON = """
        {"generatedAt":"2026-08-30 10:00:00","slot":{"day":"2026-08-30","timeString":"09:15","validUntil":"2026-08-30 10:15","scope":"market_trading"},"assets":[],"market":[],"marketDataIsFresh":false,"marketDataWarnings":[],"latestTrendGeneratedAt":null,"latestTrendHeadline":null,"latestTrendActions":[],"latestAssetConclusions":[],"dataRules":[]}
        """
        let decoder = JSONDecoder()
        let context = try decoder.decode(NextHourGuidanceContext.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(context.marketBreadth)
        XCTAssertNil(context.lastCloseReview)
    }
}
