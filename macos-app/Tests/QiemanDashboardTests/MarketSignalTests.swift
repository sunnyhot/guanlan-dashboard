import XCTest
@testable import QiemanDashboard

// MARK: - 抽取

final class MarketSignalExtractorTests: XCTestCase {
    private func candidate(
        kind: TrendActionKind,
        title: String = "关注科技板块",
        detail: String = "科技板块回调后企稳",
        targetName: String? = "中证科技 600519",
        triggers: [String] = [],
        invalidations: [String] = [],
        confidenceScore: Int = 70
    ) -> TrendActionCandidate {
        TrendActionCandidate(
            id: "\(kind.rawValue)-test",
            kind: kind,
            title: title,
            detail: detail,
            targetName: targetName,
            confidence: TrendConfidence(score: confidenceScore, label: "中"),
            whatWouldChange: "突破压力",
            triggerConditions: triggers,
            invalidatingConditions: invalidations
        )
    }

    func testKindMapping() {
        XCTAssertEqual(MarketSignalExtractor.mapKind(.considerIncrease).direction, .buy)
        XCTAssertEqual(MarketSignalExtractor.mapKind(.considerIncrease).action, .add)
        XCTAssertEqual(MarketSignalExtractor.mapKind(.considerReduce).direction, .sell)
        XCTAssertEqual(MarketSignalExtractor.mapKind(.considerReduce).action, .reduce)
        XCTAssertEqual(MarketSignalExtractor.mapKind(.watch).direction, .hold)
        XCTAssertEqual(MarketSignalExtractor.mapKind(.waitForConfirmation).action, .watch)
    }

    func testPausePlanSkipped() {
        let signal = MarketSignalExtractor.buildSignal(
            from: candidate(kind: .pausePlan, triggers: ["跌破 3000"]),
            createdAt: "2026-08-28 15:00:00",
            now: Date()
        )
        XCTAssertNil(signal, "暂停计划不建信号")
    }

    func testExtractsBuySignalWithParsedPrices() {
        let signal = MarketSignalExtractor.buildSignal(
            from: candidate(
                kind: .considerIncrease,
                triggers: ["回踩 10.5 附近获得支撑", "涨至 12.8 可分批止盈"],
                invalidations: ["跌破 9.8"]
            ),
            createdAt: "2026-08-28 15:00:00",
            now: Date()
        )
        guard let signal else { return XCTFail("应建信号") }
        XCTAssertEqual(signal.direction, .buy)
        XCTAssertEqual(signal.action, .add)
        XCTAssertEqual(signal.subjectCode, "600519", "从名称解析出 A股代码")
        XCTAssertTrue(signal.marketSettleable)
        XCTAssertEqual(signal.priceConditions.entryLow ?? 0, 10.395, accuracy: 0.001, "回踩价 ×0.99")
        XCTAssertEqual(signal.priceConditions.entryHigh ?? 0, 10.605, accuracy: 0.001)
        XCTAssertEqual(signal.priceConditions.targetPrice ?? 0, 12.8)
        XCTAssertEqual(signal.priceConditions.stopLoss ?? 0, 9.8, "作废条件「跌破 9.8」映射为止损")
        XCTAssertTrue(signal.priceConditions.parseNotes.contains { $0.contains("作废条件") })
        XCTAssertEqual(signal.rawConfidence, 0.7, accuracy: 0.001, "score 70 → 0.7")
        XCTAssertEqual(signal.events.first?.type, .created)
        XCTAssertTrue(signal.dedupKey.hasPrefix("trend|"))
    }

    func testInvalidationConditionsMapToStopAndTarget() {
        let signal = MarketSignalExtractor.buildSignal(
            from: candidate(
                kind: .considerIncrease,
                triggers: ["放量突破 11.2"],
                invalidations: ["跌破 10.0 则逻辑失效"]
            ),
            createdAt: "2026-08-28 15:00:00",
            now: Date()
        )
        guard let signal else { return XCTFail() }
        // 突破价在看多语境是目标；作废条件「跌破 10.0」按反向（sell）解析为 targetPrice → 映射回止损
        XCTAssertEqual(signal.priceConditions.targetPrice ?? 0, 11.2)
        XCTAssertEqual(signal.priceConditions.stopLoss ?? 0, 10.0)
        XCTAssertTrue(signal.priceConditions.parseNotes.contains { $0.contains("作废条件") })
    }

    func testSellSignalPriceSemantics() {
        let signal = MarketSignalExtractor.buildSignal(
            from: candidate(
                kind: .considerReduce,
                targetName: "某股 300750",
                triggers: ["跌破 20.5 确认走弱", "涨至 22.0 反弹离场"]
            ),
            createdAt: "2026-08-28 15:00:00",
            now: Date()
        )
        guard let signal else { return XCTFail() }
        XCTAssertEqual(signal.direction, .sell)
        // 看空：跌破 → 目标；涨至 → 止损
        XCTAssertEqual(signal.priceConditions.targetPrice ?? 0, 20.5)
        XCTAssertEqual(signal.priceConditions.stopLoss ?? 0, 22.0)
    }

    func testUnresolvableSubjectStillCreatesSampleOnlySignal() {
        let signal = MarketSignalExtractor.buildSignal(
            from: candidate(kind: .watch, targetName: "沪深300指数", triggers: ["无价格条件"]),
            createdAt: "2026-08-28 15:00:00",
            now: Date()
        )
        guard let signal else { return XCTFail() }
        XCTAssertNil(signal.subjectCode)
        XCTAssertFalse(signal.marketSettleable, "无 A股代码不市价结算")
    }

    func testPriceParsingPatterns() {
        let buy = MarketSignalExtractor.parsePrices(
            from: ["止损位：9.8", "回踩10.5左右", "突破 11.2 元"],
            direction: .buy
        )
        XCTAssertEqual(buy.stopLoss ?? 0, 9.8)
        XCTAssertEqual(buy.entryLow ?? 0, 10.395, accuracy: 0.001)
        XCTAssertEqual(buy.targetPrice ?? 0, 11.2)

        let none = MarketSignalExtractor.parsePrices(from: ["等待成交量放大"], direction: .buy)
        XCTAssertFalse(none.isSettleable)
    }

    func testFirstAShareCode() {
        XCTAssertEqual(MarketSignalExtractor.firstAShareCode(in: "贵州茅台 600519 目标"), "600519")
        XCTAssertNil(MarketSignalExtractor.firstAShareCode(in: "沪深300 指数"))
        XCTAssertNil(MarketSignalExtractor.firstAShareCode(in: "代码 1234567 太长"))
    }
}

// MARK: - 结算

final class MarketSignalSettlerTests: XCTestCase {
    private func makeSignal(
        direction: CanonicalDecisionType,
        stop: Double?,
        target: Double?,
        createdAt: String = "2026-08-01 15:00:00",
        dueAt: String = "2026-08-20 15:00:00"
    ) -> MarketDecisionSignal {
        MarketDecisionSignal(
            dedupKey: "test|\(direction.rawValue)",
            sourceKind: .trendReport,
            sourceActionID: "a1",
            subjectCode: "600519",
            subjectName: "测试",
            marketSettleable: true,
            direction: direction,
            action: direction == .buy ? .add : .reduce,
            score: 60,
            rawConfidence: 0.7,
            priceConditions: SignalPriceConditions(stopLoss: stop, targetPrice: target),
            watchConditions: [],
            invalidatingConditions: [],
            reason: "测试信号",
            evidenceIDs: [],
            dataQualitySummary: "",
            createdAt: createdAt,
            reviewDueAt: dueAt
        )
    }

    private func bar(_ date: String, open: Double, high: Double, low: Double, close: Double) -> MarketDailyBar {
        MarketDailyBar(date: date, open: open, high: high, low: low, close: close, volume: 1000, amount: close * 1000)
    }

    func testBuyTargetHitWins() {
        let signal = makeSignal(direction: .buy, stop: 9.0, target: 12.0)
        let bars = [
            bar("2026-08-01", open: 10, high: 10.5, low: 9.8, close: 10.2),
            bar("2026-08-05", open: 10.3, high: 12.5, low: 10.2, close: 12.4),
        ]
        let result = MarketSignalSettler.settle(signal: signal, bars: bars, asOf: "2026-08-10 15:00:00", now: date("2026-08-10 15:00:00"))
        XCTAssertEqual(result.status, .settledWin)
        XCTAssertEqual(result.settlement.settlePrice ?? 0, 12.0)
        XCTAssertEqual(result.settlement.settleDate, "2026-08-05")
        XCTAssertEqual(result.settlement.outcome, .hitTarget)
    }

    func testStopLossPriorityOverTargetSameBar() {
        // 同一根 K 线同时触及止损 9.0 和目标 12.0 → 先止损（保守口径）
        let signal = makeSignal(direction: .buy, stop: 9.0, target: 12.0)
        let bars = [
            bar("2026-08-01", open: 10, high: 10.5, low: 9.8, close: 10.2),
            bar("2026-08-05", open: 10, high: 12.5, low: 8.9, close: 9.5),
        ]
        let result = MarketSignalSettler.settle(signal: signal, bars: bars, asOf: "2026-08-10 15:00:00", now: date("2026-08-10 15:00:00"))
        XCTAssertEqual(result.status, .settledLoss, "同根双触按先止损")
        XCTAssertEqual(result.settlement.settlePrice ?? 0, 9.0)
        XCTAssertTrue(result.settlement.note.contains("保守口径"))
    }

    func testGapThroughSettlesAtOpen() {
        // 下一根直接跳空低开到 8.5（低于止损 9.0）→ 按开盘价 8.5 结算
        let signal = makeSignal(direction: .buy, stop: 9.0, target: 12.0)
        let bars = [
            bar("2026-08-01", open: 10, high: 10.5, low: 9.8, close: 10.2),
            bar("2026-08-05", open: 8.5, high: 9.2, low: 8.4, close: 8.8),
        ]
        let result = MarketSignalSettler.settle(signal: signal, bars: bars, asOf: "2026-08-10 15:00:00", now: date("2026-08-10 15:00:00"))
        XCTAssertEqual(result.status, .settledLoss)
        XCTAssertEqual(result.settlement.settlePrice ?? 0, 8.5, "跳空穿越按开盘价")
        XCTAssertTrue(result.settlement.note.contains("跳空"))
    }

    func testSellDirectionInverted() {
        // 看空：止损在上（22.0），目标在下（20.5）
        let signal = makeSignal(direction: .sell, stop: 22.0, target: 20.5)
        let bars = [
            bar("2026-08-01", open: 21, high: 21.5, low: 20.8, close: 21.0),
            bar("2026-08-05", open: 20.8, high: 21.0, low: 20.2, close: 20.4),
        ]
        let result = MarketSignalSettler.settle(signal: signal, bars: bars, asOf: "2026-08-10 15:00:00", now: date("2026-08-10 15:00:00"))
        XCTAssertEqual(result.status, .settledWin, "看空方向 low ≤ 目标 → 兑现")
        XCTAssertEqual(result.settlement.settlePrice ?? 0, 20.5)
    }

    func testNotDueNoTouchStaysActive() {
        let signal = makeSignal(direction: .buy, stop: 9.0, target: 12.0, dueAt: "2026-08-30 15:00:00")
        let bars = [
            bar("2026-08-01", open: 10, high: 10.5, low: 9.8, close: 10.2),
            bar("2026-08-05", open: 10, high: 11.0, low: 9.9, close: 10.8),
        ]
        let result = MarketSignalSettler.settle(signal: signal, bars: bars, asOf: "2026-08-10 15:00:00", now: date("2026-08-10 15:00:00"))
        XCTAssertEqual(result.status, .active)
    }

    func testDueUntouchedExpiresUnresolved() {
        let signal = makeSignal(direction: .buy, stop: 9.0, target: 12.0, dueAt: "2026-08-05 15:00:00")
        let bars = [
            bar("2026-08-01", open: 10, high: 10.5, low: 9.8, close: 10.2),
            bar("2026-08-10", open: 10, high: 11.0, low: 9.9, close: 10.8),
        ]
        // now 超过到期 + 2 交易日
        let result = MarketSignalSettler.settle(signal: signal, bars: bars, asOf: "2026-08-12 15:00:00", now: date("2026-08-12 15:00:00"))
        XCTAssertEqual(result.status, .expiredUnresolved)
        XCTAssertTrue(result.settlement.note.contains("幸存者偏差"))
        XCTAssertNotNil(result.settlement.maxFavorablePct)
        XCTAssertEqual(result.event?.type, .expired)
    }

    func testNoBarsGivesInsufficientData() {
        let signal = makeSignal(direction: .buy, stop: 9.0, target: 12.0)
        let result = MarketSignalSettler.settle(signal: signal, bars: [], asOf: "2026-08-12 15:00:00", now: date("2026-08-12 15:00:00"))
        XCTAssertEqual(result.status, .insufficientData)
        XCTAssertEqual(result.settlement.outcome, .insufficientData)
    }

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = MarketPhase.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)!
    }
}

// MARK: - 胜率记忆

final class SignalAccuracyMemoryTests: XCTestCase {
    private func settledSignal(
        direction: CanonicalDecisionType,
        status: SignalStatus,
        subjectCode: String? = "600519",
        settledAt: String = "2026-08-20 15:00:00"
    ) -> MarketDecisionSignal {
        var signal = MarketDecisionSignal(
            dedupKey: "d-\(direction)-\(status)-\(subjectCode ?? "-")-\(settledAt)",
            sourceKind: .trendReport,
            sourceActionID: "a",
            subjectCode: subjectCode,
            subjectName: "s",
            marketSettleable: true,
            direction: direction,
            action: .add,
            score: 60,
            rawConfidence: 0.7,
            priceConditions: SignalPriceConditions(stopLoss: 9, targetPrice: 12),
            watchConditions: [], invalidatingConditions: [], reason: "r",
            evidenceIDs: [], dataQualitySummary: "",
            createdAt: "2026-08-01 15:00:00",
            reviewDueAt: "2026-08-10 15:00:00",
            status: status,
            settlement: SignalSettlement(
                settledAt: settledAt, outcome: status == .settledWin ? .hitTarget : status == .settledLoss ? .hitStop : .expiredUnresolved,
                settlePrice: 12, settleDate: "2026-08-10",
                maxFavorablePct: 5, maxAdversePct: -2, note: "n"
            )
        )
        signal.status = status
        return signal
    }

    func testWinRateExcludesUnresolvedFromNumeratorOnlyPartially() {
        let signals = (0..<18).map { settledSignal(direction: .buy, status: $0 < 12 ? .settledWin : .settledLoss) }
            + (0..<5).map { _ in settledSignal(direction: .buy, status: .expiredUnresolved) }
        let memory = SignalAccuracyMemory.build(from: signals, asOf: "2026-08-28 15:00:00")

        XCTAssertEqual(memory.byDirection["buy"]?.wins, 12)
        XCTAssertEqual(memory.byDirection["buy"]?.losses, 6)
        XCTAssertEqual(memory.byDirection["buy"]?.unresolved, 5)
        // 胜率 = 12/(12+6) = 66.7%，unresolved 不进分母
        XCTAssertEqual(memory.byDirection["buy"]?.winRate ?? 0, 12.0 / 18.0, accuracy: 0.001)
        XCTAssertEqual(memory.byDirection["buy"]?.sampleCount, 23)
    }

    func testCalibrationRequiresMinimumSamples() {
        // 29 个样本：不启用校准
        let few = (0..<29).map { _ in settledSignal(direction: .buy, status: .settledWin) }
        let memoryFew = SignalAccuracyMemory.build(from: few, asOf: "2026-08-28 15:00:00")
        XCTAssertEqual(memoryFew.calibrationFactor(direction: .buy, subjectCode: nil, sourceKind: .trendReport), 1.0, "样本不足不干预")

        // 31 个全胜：系数上浮封顶 1.2
        let manyWins = (0..<31).map { _ in settledSignal(direction: .buy, status: .settledWin) }
        let memoryWins = SignalAccuracyMemory.build(from: manyWins, asOf: "2026-08-28 15:00:00")
        XCTAssertEqual(memoryWins.calibrationFactor(direction: .buy, subjectCode: nil, sourceKind: .trendReport), 1.2, accuracy: 0.001)

        // 31 个全败：系数下限 0.3
        let manyLosses = (0..<31).map { _ in settledSignal(direction: .buy, status: .settledLoss) }
        let memoryLosses = SignalAccuracyMemory.build(from: manyLosses, asOf: "2026-08-28 15:00:00")
        XCTAssertEqual(memoryLosses.calibrationFactor(direction: .buy, subjectCode: nil, sourceKind: .trendReport), 0.3, accuracy: 0.001)
    }

    func testCalibratedConfidenceCapsAtOne() {
        let signals = (0..<31).map { _ in settledSignal(direction: .buy, status: .settledWin) }
        let memory = SignalAccuracyMemory.build(from: signals, asOf: "2026-08-28 15:00:00")
        let calibrated = memory.calibratedConfidence(raw: 0.9, direction: .buy, subjectCode: nil, sourceKind: .trendReport)
        XCTAssertEqual(calibrated, 1.0, accuracy: 0.0001, "0.9 × 1.2 封顶 1.0")
        // 低胜率打 3 折
        let losses = (0..<31).map { _ in settledSignal(direction: .sell, status: .settledLoss) }
        let memoryLoss = SignalAccuracyMemory.build(from: losses, asOf: "2026-08-28 15:00:00")
        XCTAssertEqual(memoryLoss.calibratedConfidence(raw: 0.8, direction: .sell, subjectCode: nil, sourceKind: .trendReport), 0.24, accuracy: 0.001)
        XCTAssertNotNil(memoryLoss.calibrationSummary(direction: .sell, subjectCode: nil, sourceKind: .trendReport))
    }

    func testSubjectBucketPreferredOverGlobal() {
        // 标的桶 30 胜 0 败，全局 30 败
        let subjectWins = (0..<30).map { _ in settledSignal(direction: .buy, status: .settledWin, subjectCode: "600519") }
        let globalLosses = (0..<30).map { _ in settledSignal(direction: .buy, status: .settledLoss, subjectCode: "000001") }
        let memory = SignalAccuracyMemory.build(from: subjectWins + globalLosses, asOf: "2026-08-28 15:00:00")
        XCTAssertEqual(memory.calibrationFactor(direction: .buy, subjectCode: "600519", sourceKind: .trendReport), 1.2, accuracy: 0.001, "标的桶优先")
    }

    func testOldSettlementsOutsideWindowExcluded() {
        let old = (0..<35).map { _ in settledSignal(direction: .buy, status: .settledWin, settledAt: "2026-01-10 15:00:00") }
        let memory = SignalAccuracyMemory.build(from: old, asOf: "2026-08-28 15:00:00")
        XCTAssertEqual(memory.byDirection["buy"]?.sampleCount ?? 0, 0, "180 天窗口外的结算不计入")
    }
}

// MARK: - Store 与服务

final class MarketSignalServiceTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("market-signal-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func service(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> MarketSignalService {
        MarketSignalService(
            store: MarketSignalStore(baseDirectory: tempDirectory),
            engine: nil,
            now: { now }
        )
    }

    private func rawSignal(
        dedupKey: String,
        subjectCode: String?,
        direction: CanonicalDecisionType,
        createdAt: String = "2026-08-28 15:00:00",
        settleable: Bool = true
    ) -> MarketDecisionSignal {
        MarketDecisionSignal(
            dedupKey: dedupKey,
            sourceKind: .trendReport,
            sourceActionID: dedupKey,
            subjectCode: subjectCode,
            subjectName: "s-\(dedupKey)",
            marketSettleable: settleable && subjectCode != nil,
            direction: direction,
            action: direction == .buy ? .add : direction == .sell ? .reduce : .watch,
            score: 60,
            rawConfidence: 0.7,
            priceConditions: settleable ? SignalPriceConditions(stopLoss: 9, targetPrice: 12) : SignalPriceConditions(),
            watchConditions: [], invalidatingConditions: [],
            reason: "r", evidenceIDs: [], dataQualitySummary: "",
            createdAt: createdAt,
            reviewDueAt: "2026-08-31 15:00:00"
        )
    }

    func testStoreRoundTripAndIndex() throws {
        let store = MarketSignalStore(baseDirectory: tempDirectory)
        let signal = rawSignal(dedupKey: "k1", subjectCode: "600519", direction: .buy)
        try store.save(signal)

        let loaded = store.loadSignal(id: signal.id)
        XCTAssertEqual(loaded?.dedupKey, "k1")
        XCTAssertEqual(loaded?.priceConditions.targetPrice, 12)

        let index = store.loadIndex()
        XCTAssertEqual(index.entries.count, 1)
        XCTAssertEqual(index.entries.first?.subjectCode, "600519")
        XCTAssertEqual(index.entries.first?.direction, .buy)

        // 状态更新后 index 同步
        var settled = signal
        settled.status = .settledWin
        try store.save(settled)
        XCTAssertEqual(store.loadIndex().entries.first?.status, .settledWin)
        XCTAssertEqual(store.activeSignals().count, 0)
    }

    func testIngestDeduplicatesWithinSevenDays() async throws {
        let service = service()
        let first = try await service.ingest(
            signals: [rawSignal(dedupKey: "same", subjectCode: "600519", direction: .buy)]
        )
        XCTAssertEqual(first.created, 1)
        // 同 dedupKey 且 7 天内 → 去重
        let second = try await service.ingest(
            signals: [rawSignal(dedupKey: "same", subjectCode: "600519", direction: .buy)]
        )
        XCTAssertEqual(second.created, 0)
        XCTAssertEqual(second.duplicates, 1)
        let all = await service.allSignals()
        XCTAssertEqual(all.count, 1)
    }

    func testIngestInvalidatesOppositeActiveSignal() async throws {
        let service = service()
        _ = try await service.ingest(signals: [rawSignal(dedupKey: "bull", subjectCode: "600519", direction: .buy)])
        let summary = try await service.ingest(
            signals: [rawSignal(dedupKey: "bear", subjectCode: "600519", direction: .sell)]
        )
        XCTAssertEqual(summary.created, 1)
        XCTAssertEqual(summary.invalidatedOpposites, 1)

        let all = try await service.allSignals()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first { $0.dedupKey == "bull" }?.status, .invalidated)
        XCTAssertEqual(all.first { $0.dedupKey == "bull" }?.settlement?.outcome, .superseded)
        XCTAssertEqual(all.first { $0.dedupKey == "bear" }?.status, .active)
        // 不同标的的信号不受影响
        _ = try await service.ingest(signals: [rawSignal(dedupKey: "other", subjectCode: "000001", direction: .buy)])
        let final = try await service.allSignals()
        XCTAssertEqual(final.first { $0.dedupKey == "bear" }?.status, .active)
    }

    func testSettleExpiresUnsettleableDueSignals() async throws {
        // now 推进到到期 + 缓冲之后
        let late = Date(timeIntervalSince1970: 1_800_000_000 + 20 * 86_400)
        let service = service(now: late)
        _ = try await service.ingest(
            signals: [
                rawSignal(dedupKey: "watch-only", subjectCode: nil, direction: .hold, settleable: false),
                rawSignal(dedupKey: "no-code", subjectCode: nil, direction: .buy, settleable: true),
            ]
        )
        let summary = try await service.settleDueSignals()
        XCTAssertEqual(summary.expired, 2, "无价格条件/无标的的到期信号 expiredUnresolved")
        let all = await service.allSignals()
        XCTAssertTrue(all.allSatisfy { $0.status == .expiredUnresolved })
        XCTAssertTrue(all.allSatisfy { $0.settlement?.outcome == .expiredUnresolved })
    }
}
