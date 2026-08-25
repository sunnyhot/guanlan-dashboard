import XCTest
@testable import QiemanDashboard

/// FAC-1 单元测试：FactorDefinition / FactorMetric / FactorSnapshot /
/// FactorSeries / FactorEngine 的模型与 PIT 接线。
final class FactorModelTests: XCTestCase {

    // MARK: - 测试基建

    private struct WeekdayCalendar: TradingCalendar {
        func isTradingDay(_ date: Date, jurisdiction: Jurisdiction) -> Bool {
            let w = Calendar(identifier: .gregorian).component(.weekday, from: date)
            return w >= 2 && w <= 6
        }
        func tradingDay(after date: Date, offset: Int, jurisdiction: Jurisdiction) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            var current = date; var remaining = max(offset, 0); var safety = 0
            while remaining > 0 && safety < 14 {
                current = cal.date(byAdding: .day, value: 1, to: current)!
                if isTradingDay(current, jurisdiction: jurisdiction) { remaining -= 1 }
                safety += 1
            }
            return current
        }
        func tradingDayStart(_ date: Date, jurisdiction: Jurisdiction) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            return cal.startOfDay(for: date)
        }
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.startOfDay(for: cal.date(from: DateComponents(year: y, month: m, day: d))!)
    }

    private func makeProv() -> AvailabilityProvenance {
        AvailabilityProvenance(policyID: "market_close", policyVersion: "v1", derivedAt: date(2024, 1, 1))
    }

    /// 构造单根 DailyBar（availableAt = effectiveAt 当日，简化 PIT 语义）。
    private func bar(
        id: String, listing: String, on day: Date, close: Decimal,
        adjustmentFactor: Decimal = 1, publisherVersion: Int = 1
    ) -> DailyBar {
        DailyBar(
            id: ObservationID(rawValue: id),
            listingID: ListingID(rawValue: listing),
            temporalEnvelope: TemporalEnvelope(
                effectiveAt: day, publishedAt: day,
                availableAt: tradingDayClose(day), ingestedAt: tradingDayClose(day)
            ),
            availabilityProvenance: makeProv(),
            dataQuality: .from(.officialStable, providerID: .stooq),
            vintage: Vintage(announcementDate: day, publisherVersion: publisherVersion),
            rawOpen: Price(value: close, currency: .cny),
            rawHigh: Price(value: close, currency: .cny),
            rawLow: Price(value: close, currency: .cny),
            rawClose: Price(value: close, currency: .cny),
            volume: 1000, adjustmentFactor: adjustmentFactor
        )
    }

    /// availableAt 用当日收盘时刻（15:00），asOf 取当日 16:00 即可见。
    private func tradingDayClose(_ day: Date) -> Date {
        day.addingTimeInterval(15 * 3600)
    }

    /// 桩 calculator：输出「最后一根复权收盘 × 系数」验证引擎接线。
    private struct LastCloseCalculator: FactorCalculator {
        let multiplier: Decimal
        var definitions: [FactorDefinition] {
            [FactorDefinition(key: "test.lastClose", version: "v1", unit: .ratio)]
        }
        func compute(inputs: FactorInputs) -> [FactorMetric] {
            guard let last = inputs.assetSeries.last else {
                return [FactorMetric(definition: definitions[0], insufficiency: .init(
                    reason: .emptySeries, requiredBars: 1, actualBars: 0
                ))]
            }
            return [FactorMetric(definition: definitions[0], value: last.adjustedClose * multiplier)]
        }
    }

    // MARK: - Codable round-trip

    func testFactorDefinitionCodableRoundTrip() throws {
        let def = FactorDefinition(
            key: "trend.closeVsMA20", version: "v1", unit: .ratio,
            parameters: [FactorDefinition.Parameter(name: "windowBars", intValue: 20)]
        )
        let data = try JSONEncoder().encode(def)
        let decoded = try JSONDecoder().decode(FactorDefinition.self, from: data)
        XCTAssertEqual(decoded, def)
        XCTAssertEqual(decoded.parameters.first?.intValue, 20)
    }

    func testFactorMetricCodableRoundTrip_bothStates() throws {
        let def = FactorDefinition(key: "momentum.return20", version: "v1", unit: .ratio)
        let valued = FactorMetric(definition: def, value: Decimal(string: "0.123456789012345")!)
        let decodedValued = try roundTrip(valued)
        XCTAssertEqual(decodedValued.value, Decimal(string: "0.123456789012")!)
        XCTAssertNil(decodedValued.insufficiency)

        let insufficient = FactorMetric(definition: def, insufficiency: .init(
            reason: .insufficientBars, requiredBars: 21, actualBars: 10
        ))
        let decodedInsufficient = try roundTrip(insufficient)
        XCTAssertNil(decodedInsufficient.value)
        XCTAssertEqual(decodedInsufficient.insufficiency?.reason, .insufficientBars)
        XCTAssertEqual(decodedInsufficient.insufficiency?.requiredBars, 21)
        XCTAssertEqual(decodedInsufficient.insufficiency?.actualBars, 10)
    }

    func testFactorSnapshotCodableAndArtifactConformance() throws {
        let repo = makeRepoWithAscendingBars(count: 3)
        let engine = FactorEngine(calculators: [LastCloseCalculator(multiplier: 1)])
        let snap = engine.snapshot(
            listingID: ListingID(rawValue: "L"),
            asOf: date(2024, 1, 31),
            repository: repo,
            producedAt: date(2024, 1, 31)
        )

        XCTAssertEqual(snap.validityPolicy, .untilDependencyChanges)
        XCTAssertEqual(snap.assetCoverage.barCount, 3)
        XCTAssertEqual(snap.sourceObservationIDs.count, 3)
        // dependencies 与 sourceObservationIDs 一一对应（Artifact 语义）
        XCTAssertEqual(
            snap.dependencies.map(\.referenceID),
            snap.sourceObservationIDs.map(\.rawValue)
        )
        XCTAssertTrue(snap.dependencies.allSatisfy { $0.kind == .observation })

        let decoded = try roundTrip(snap)
        XCTAssertEqual(decoded.id, snap.id)
        XCTAssertEqual(decoded.metrics, snap.metrics)
        XCTAssertEqual(decoded.factorVersion, snap.factorVersion)
    }

    // MARK: - 序列提取

    func testAdjustedCloseSeries_ordersAppliesAdjustmentAndDeduplicates() {
        let d1 = date(2024, 1, 2), d2 = date(2024, 1, 3)
        // 乱序输入 + 复权因子 2.0：adjustedClose = raw × factor
        let bars = [
            bar(id: "b2", listing: "L", on: d2, close: 50, adjustmentFactor: 2),
            bar(id: "b1", listing: "L", on: d1, close: 100, adjustmentFactor: 1),
            // 同日重复 bar（防御性兜底）：取 observationID 字典序最小。
            // 真实链路中 economicKnowledge 输出每日一条，此分支仅为
            // 「绕过 Repository 的调用」保证确定性行为。
            bar(id: "b0", listing: "L", on: d2, close: 999),
        ]
        let series = FactorSeries.adjustedCloseSeries(from: bars)
        XCTAssertEqual(series.count, 2)
        XCTAssertEqual(series.map(\.effectiveAt), [d1, d2])
        XCTAssertEqual(series[0].adjustedClose, 100)
        XCTAssertEqual(series[1].adjustedClose, 999)
        XCTAssertEqual(series.map(\.observationID.rawValue), ["b1", "b0"])
    }

    // MARK: - FactorEngine 接线

    func testFactorEngine_computesFromPITVisibleBarsOnly() {
        let repo = InMemoryRepository(calendarBackend: WeekdayCalendar())
        // T=1-08 bar：availableAt 1-08 15:00
        repo.upsert(bar(id: "a1", listing: "L", on: date(2024, 1, 8), close: 100))
        // T=1-09 bar 有两个 vintage：v1 availableAt 1-09 15:00，v2（修订）availableAt 1-20
        let d9 = date(2024, 1, 9)
        repo.upsert(bar(id: "a2_v1", listing: "L", on: d9, close: 110))
        let revised = DailyBar(
            id: ObservationID(rawValue: "a2_v2"),
            listingID: ListingID(rawValue: "L"),
            temporalEnvelope: TemporalEnvelope(
                effectiveAt: d9, publishedAt: date(2024, 1, 20),
                availableAt: date(2024, 1, 20), ingestedAt: date(2024, 1, 20)
            ),
            availabilityProvenance: makeProv(),
            dataQuality: .from(.officialStable, providerID: .stooq),
            vintage: Vintage(announcementDate: date(2024, 1, 20), publisherVersion: 2),
            rawOpen: Price(value: 120, currency: .cny),
            rawHigh: Price(value: 120, currency: .cny),
            rawLow: Price(value: 120, currency: .cny),
            rawClose: Price(value: 120, currency: .cny),
            volume: 1000, adjustmentFactor: 1
        )
        repo.upsert(revised)

        let engine = FactorEngine(calculators: [LastCloseCalculator(multiplier: 1)])

        // asOf 1-10：只见 v1（110）
        let atEarly = engine.snapshot(
            listingID: ListingID(rawValue: "L"), asOf: date(2024, 1, 10),
            repository: repo, producedAt: date(2024, 1, 10)
        )
        XCTAssertEqual(atEarly.metrics.first?.value, 110)
        // PIT provenance：v2 未参与，sourceIDs 只有 a1 + a2_v1
        XCTAssertEqual(atEarly.sourceObservationIDs.map(\.rawValue), ["a1", "a2_v1"])

        // asOf 1-21：v2 可见（120），且 v1 被同 effectiveAt 择优淘汰
        let atLate = engine.snapshot(
            listingID: ListingID(rawValue: "L"), asOf: date(2024, 1, 21),
            repository: repo, producedAt: date(2024, 1, 21)
        )
        XCTAssertEqual(atLate.metrics.first?.value, 120)
        XCTAssertEqual(atLate.sourceObservationIDs.map(\.rawValue), ["a1", "a2_v2"])
    }

    func testFactorEngine_deterministicID_sameInputsSameID() {
        // 十二轮 P3:sourceObservationIDs 无默认值——源身份必须显式传入
        /// (无源调用 = 显式空数组,四元组形态不再是可静默省略的形态)
        let engine = FactorEngine(calculators: [LastCloseCalculator(multiplier: 2)])
        let id1 = FactorEngine.deterministicID(
            listingID: ListingID(rawValue: "L"), asOf: date(2024, 1, 31),
            benchmarkListingID: nil, factorVersion: engine.factorVersion,
            sourceObservationIDs: []
        )
        let id2 = FactorEngine.deterministicID(
            listingID: ListingID(rawValue: "L"), asOf: date(2024, 1, 31),
            benchmarkListingID: nil, factorVersion: engine.factorVersion,
            sourceObservationIDs: []
        )
        XCTAssertEqual(id1, id2)

        // asOf 不同 → id 不同；benchmark 不同 → id 不同
        let idLater = FactorEngine.deterministicID(
            listingID: ListingID(rawValue: "L"), asOf: date(2024, 2, 1),
            benchmarkListingID: nil, factorVersion: engine.factorVersion,
            sourceObservationIDs: []
        )
        XCTAssertNotEqual(id1, idLater)
        let idWithBenchmark = FactorEngine.deterministicID(
            listingID: ListingID(rawValue: "L"), asOf: date(2024, 1, 31),
            benchmarkListingID: ListingID(rawValue: "B"), factorVersion: engine.factorVersion,
            sourceObservationIDs: []
        )
        XCTAssertNotEqual(id1, idWithBenchmark)
    }

    func testFactorEngine_deterministicID_bindsSourceObservations() {
        // 十一轮 P2-1 回归:同 (listing/asOf/benchmark/factorVersion) 四元组
        // 下,参与计算的 observation 身份不同(修订场景)→ ID 必须分裂——
        // 否则 ArtifactRow.write 幂等比对把语义应为 untilDependencyChanges
        // supersede 的修订误报 conflict;源 ID 顺序无关(规范化排序)
        let version = FactorEngine(calculators: [LastCloseCalculator(multiplier: 2)]).factorVersion
        let base = FactorEngine.deterministicID(
            listingID: ListingID(rawValue: "L"), asOf: date(2024, 1, 31),
            benchmarkListingID: nil, factorVersion: version,
            sourceObservationIDs: [ObservationID(rawValue: "a1"), ObservationID(rawValue: "a2_v1")]
        )
        let sameSources = FactorEngine.deterministicID(
            listingID: ListingID(rawValue: "L"), asOf: date(2024, 1, 31),
            benchmarkListingID: nil, factorVersion: version,
            sourceObservationIDs: [ObservationID(rawValue: "a2_v1"), ObservationID(rawValue: "a1")]
        )
        XCTAssertEqual(base, sameSources, "源 ID 集合相同(顺序不同)→ 同 ID")
        let revised = FactorEngine.deterministicID(
            listingID: ListingID(rawValue: "L"), asOf: date(2024, 1, 31),
            benchmarkListingID: nil, factorVersion: version,
            sourceObservationIDs: [ObservationID(rawValue: "a1"), ObservationID(rawValue: "a2_v2")]
        )
        XCTAssertNotEqual(base, revised, "修订(a2_v1 → a2_v2)后重算 → 新 ID(supersede 而非 conflict)")
    }

    func testFactorDefinition_fingerprintBindsParameters() {
        // 十一轮 P2-2 回归:同 key@version 不同参数值 → 指纹分裂;
        /// 无参数定义保持纯 key@version(既有形态兼容)
        let noParams = FactorDefinition(key: "test.lastClose", version: "v1", unit: .ratio)
        XCTAssertEqual(noParams.fingerprint, "test.lastClose@v1")

        let window20 = FactorDefinition(
            key: "momentum.return", version: "v1", unit: .ratio,
            parameters: [.init(name: "window", intValue: 20)]
        )
        let window60 = FactorDefinition(
            key: "momentum.return", version: "v1", unit: .ratio,
            parameters: [.init(name: "window", intValue: 60)]
        )
        XCTAssertNotEqual(window20.fingerprint, window60.fingerprint,
                          "参数值变更(不 bump version)→ 指纹变化——同 ID 下不同数学的通道关闭")
        XCTAssertEqual(window20.fingerprint, window20.fingerprint,
                       "同定义 → 指纹稳定")
        // 参数顺序无关(规范化排序)
        let reordered = FactorDefinition(
            key: "momentum.return", version: "v1", unit: .ratio,
            parameters: [.init(name: "window", intValue: 20), .init(name: "benchmark", value: "L")]
        )
        let original = FactorDefinition(
            key: "momentum.return", version: "v1", unit: .ratio,
            parameters: [.init(name: "benchmark", value: "L"), .init(name: "window", intValue: 20)]
        )
        XCTAssertEqual(reordered.fingerprint, original.fingerprint)
    }

    func testFactorEngine_factorVersionChangesWithDefinitions() {
        let v1 = FactorEngine(calculators: [LastCloseCalculator(multiplier: 1)]).factorVersion
        // 参数 / 版本变更（不同 definition 集合）→ 指纹变化
        let otherVersion = FactorEngine(calculators: [ScaledLastCloseCalculator()]).factorVersion
        XCTAssertNotEqual(v1, otherVersion)
        // 相同 calculator 重建 → 指纹稳定
        let v1again = FactorEngine(calculators: [LastCloseCalculator(multiplier: 1)]).factorVersion
        XCTAssertEqual(v1, v1again)
    }

    func testFactorEngine_emptySeriesReportsInsufficiency() {
        let repo = InMemoryRepository(calendarBackend: WeekdayCalendar())
        let engine = FactorEngine(calculators: [LastCloseCalculator(multiplier: 1)])
        let snap = engine.snapshot(
            listingID: ListingID(rawValue: "L"), asOf: date(2024, 1, 31),
            repository: repo, producedAt: date(2024, 1, 31)
        )
        XCTAssertNil(snap.metrics.first?.value)
        XCTAssertEqual(snap.metrics.first?.insufficiency?.reason, .emptySeries)
        XCTAssertEqual(snap.assetCoverage.barCount, 0)
        XCTAssertTrue(snap.sourceObservationIDs.isEmpty)
        XCTAssertTrue(snap.dependencies.isEmpty)
    }

    func testFactorEngine_benchmarkBarsEnterSourceAndCoverage() {
        let repo = InMemoryRepository(calendarBackend: WeekdayCalendar())
        repo.upsert(bar(id: "a1", listing: "L", on: date(2024, 1, 8), close: 100))
        repo.upsert(bar(id: "bm1", listing: "B", on: date(2024, 1, 8), close: 500))
        let engine = FactorEngine(calculators: [LastCloseCalculator(multiplier: 1)])
        let snap = engine.snapshot(
            listingID: ListingID(rawValue: "L"), asOf: date(2024, 1, 31),
            repository: repo, benchmarkListingID: ListingID(rawValue: "B"),
            producedAt: date(2024, 1, 31)
        )
        XCTAssertEqual(snap.sourceObservationIDs.count, 2)
        XCTAssertEqual(snap.assetCoverage.barCount, 1)
        XCTAssertEqual(snap.benchmarkCoverage?.barCount, 1)

        // 不指定 benchmark：benchmarkCoverage 为 nil，benchmark bar 不进 source
        let snapNoBenchmark = engine.snapshot(
            listingID: ListingID(rawValue: "L"), asOf: date(2024, 1, 31),
            repository: repo, producedAt: date(2024, 1, 31)
        )
        XCTAssertNil(snapNoBenchmark.benchmarkCoverage)
        XCTAssertEqual(snapNoBenchmark.sourceObservationIDs.count, 1)
    }

    // MARK: - helpers

    /// 参数不同的 calculator（同 key 但 version 不同）——验证指纹对 definition 敏感。
    private struct ScaledLastCloseCalculator: FactorCalculator {
        var definitions: [FactorDefinition] {
            [FactorDefinition(key: "test.lastClose", version: "v2", unit: .ratio)]
        }
        func compute(inputs: FactorInputs) -> [FactorMetric] {
            [FactorMetric(definition: definitions[0], value: 0)]
        }
    }

    private func makeRepoWithAscendingBars(count: Int) -> InMemoryRepository {
        let repo = InMemoryRepository(calendarBackend: WeekdayCalendar())
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var day = date(2024, 1, 2)
        for i in 0..<count {
            repo.upsert(bar(
                id: "b\(i)", listing: "L", on: day,
                close: Decimal(100 + i)
            ))
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return repo
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
