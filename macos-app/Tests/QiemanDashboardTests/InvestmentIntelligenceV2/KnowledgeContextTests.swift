import XCTest
@testable import QiemanDashboard

/// DOM-6 单元测试：DataQueryMode 双模式 + KnowledgeContext 强制入参语义。
///
/// 重点验证 ADR-DATA002 §Decision 2/3：
/// - economicKnowledge 只返回 availableAt ≤ asOf（防 lookahead bias）
/// - exactSnapshot 返回 effectiveAt == at 的所有 vintage
/// - KnowledgeContext 不可省略 mode
final class KnowledgeContextTests: XCTestCase {

    // 用 Asia/Shanghai 日界构造精确日期，避免 timestamp "ish" 偏移导致 M2 场景
    // 在不同时区下解读不同。所有日期都是该日 00:00 Asia/Shanghai。
    // 2024-07-20 是周六，7-22 是下周一（中国交易日）。
    private let day630 = KnowledgeContextTests.makeDate(2024, 6, 30)
    private let day710 = KnowledgeContextTests.makeDate(2024, 7, 10)
    private let day720 = KnowledgeContextTests.makeDate(2024, 7, 20)   // 周六（公告日）
    private let day722 = KnowledgeContextTests.makeDate(2024, 7, 22)   // 周一（客观可知 = nextTradingDay(7-20)）
    private let day801 = KnowledgeContextTests.makeDate(2024, 8, 1)

    private static func makeDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.startOfDay(for: cal.date(from: DateComponents(year: y, month: m, day: d))!)
    }

    // MARK: - DataQueryMode.includes（economicKnowledge）

    func testEconomicKnowledge_includesAvailableBeforeAsOf() {
        let mode: DataQueryMode = .economicKnowledge(asOf: day722)
        // availableAt 7-22 ≤ 7-22 → 包含
        let env = TemporalEnvelope(
            effectiveAt: day710, publishedAt: day720,
            availableAt: day722, ingestedAt: day801
        )
        XCTAssertTrue(mode.includes(envelope: env))
    }

    func testEconomicKnowledge_excludesAvailableAfterAsOf() {
        let mode: DataQueryMode = .economicKnowledge(asOf: day710)
        // availableAt 7-22 > 7-10 → 排除（M2 场景 3 核心）
        let env = TemporalEnvelope(
            effectiveAt: day710, publishedAt: day720,
            availableAt: day722, ingestedAt: day801
        )
        XCTAssertFalse(mode.includes(envelope: env))
    }

    func testEconomicKnowledge_ignoresIngestedAt() {
        // economicKnowledge 不看 ingestedAt：即使本机 8-01 才抓到，
        // 7-22 时点外部世界客观可知，economicKnowledge(asOf: 7-22) 仍包含
        let mode: DataQueryMode = .economicKnowledge(asOf: day722)
        let env = TemporalEnvelope(
            effectiveAt: day630, publishedAt: day720,
            availableAt: day722, ingestedAt: day801
        )
        XCTAssertTrue(mode.includes(envelope: env))
    }

    // MARK: - DataQueryMode.includes（operationalKnowledge，ADR-DATA002 §Decision 4）

    func testOperationalKnowledge_requiresBothAvailableAndIngested() {
        // 必须同时满足 availableAt ≤ asOf 且 ingestedAt ≤ asOf
        let mode: DataQueryMode = .operationalKnowledge(asOf: day722)
        // 7-22 时：availableAt = 7-22 满足，但 ingestedAt = 8-01 不满足 → 排除
        let envLateIngest = TemporalEnvelope(
            effectiveAt: day630, publishedAt: day720,
            availableAt: day722, ingestedAt: day801
        )
        XCTAssertFalse(mode.includes(envelope: envLateIngest))
    }

    func testOperationalKnowledge_includesWhenBothMet() {
        // 8-01 时：availableAt = 7-22 满足，ingestedAt = 8-01 满足 → 包含
        let mode: DataQueryMode = .operationalKnowledge(asOf: day801)
        let env = TemporalEnvelope(
            effectiveAt: day630, publishedAt: day720,
            availableAt: day722, ingestedAt: day801
        )
        XCTAssertTrue(mode.includes(envelope: env))
    }

    func testOperationalKnowledge_vs_economicKnowledge_semanticsDiffer() {
        // 同一条数据（ingestedAt 滞后），两种 mode 在 7-22 时点结果不同
        let env = TemporalEnvelope(
            effectiveAt: day630, publishedAt: day720,
            availableAt: day722, ingestedAt: day801
        )
        let economic = DataQueryMode.economicKnowledge(asOf: day722)
        let operational = DataQueryMode.operationalKnowledge(asOf: day722)
        XCTAssertTrue(economic.includes(envelope: env))     // 客观可知即可
        XCTAssertFalse(operational.includes(envelope: env)) // 本机还没抓到
    }

    // MARK: - M2 场景 3：基金 Q2 持仓 7-22 才可知，7-10 查不到

    func testM2Scenario3_fundQ2HoldingNotVisibleAt710() {
        // 基金 Q2 持仓 effectiveAt 6-30，7-20 公告，客观可知 = 7-22（次交易日）
        // economicKnowledge(asOf: 7-10) 必须查不到（防 lookahead bias）
        let mode: DataQueryMode = .economicKnowledge(asOf: day710)
        let env = TemporalEnvelope(
            effectiveAt: day630,
            publishedAt: day720,
            availableAt: day722,
            ingestedAt: day801
        )
        XCTAssertFalse(mode.includes(envelope: env))
    }

    func testM2Scenario4_visibleAt722EvenIngestedAt801() {
        // Provider 故障 8-01 抓到，但 availableAt 仍记客观的 7-22
        // economicKnowledge(asOf: 7-22) 应该能看到（不受 ingestedAt 延迟影响）
        let mode: DataQueryMode = .economicKnowledge(asOf: day722)
        let env = TemporalEnvelope(
            effectiveAt: day630,
            publishedAt: day720,
            availableAt: day722,
            ingestedAt: day801
        )
        XCTAssertTrue(mode.includes(envelope: env))
    }

    func testM2Scenario4_operationalKnowledgeExcludesAt722() {
        // 同一数据，operationalKnowledge(asOf: 7-22) 应排除（本机还没抓到）。
        // 这正是 operational 与 economic 的区别：还原 7-22 当天界面时，
        // 这条数据在 App 里还不存在。
        let mode: DataQueryMode = .operationalKnowledge(asOf: day722)
        let env = TemporalEnvelope(
            effectiveAt: day630, publishedAt: day720,
            availableAt: day722, ingestedAt: day801
        )
        XCTAssertFalse(mode.includes(envelope: env))
    }

    func testExactSnapshot_includesMatchingEffectiveAt() {
        let mode: DataQueryMode = .exactSnapshot(at: day710)
        let env = TemporalEnvelope(
            effectiveAt: day710, publishedAt: day720,
            availableAt: day722, ingestedAt: day801
        )
        XCTAssertTrue(mode.includes(envelope: env))
    }

    func testExactSnapshot_excludesNonMatchingEffectiveAt() {
        let mode: DataQueryMode = .exactSnapshot(at: day710)
        let env = TemporalEnvelope(
            effectiveAt: day720, publishedAt: day720,
            availableAt: day722, ingestedAt: day801
        )
        XCTAssertFalse(mode.includes(envelope: env))
    }

    // MARK: - economicKnowledge vs exactSnapshot 语义不同

    func testEconomicKnowledge_vs_exactSnapshot_semanticsDiffer() {
        // 同一个 envelope，在两种 mode 下结果不同
        let env = TemporalEnvelope(
            effectiveAt: day710, publishedAt: day720,
            availableAt: day722, ingestedAt: day801
        )
        let economic = DataQueryMode.economicKnowledge(asOf: day710)
        let snapshot = DataQueryMode.exactSnapshot(at: day710)
        // economicKnowledge(asOf:7-10)：availableAt 7-22 > 7-10 → 排除
        XCTAssertFalse(economic.includes(envelope: env))
        // exactSnapshot(at:7-10)：effectiveAt 7-10 == 7-10 → 包含
        XCTAssertTrue(snapshot.includes(envelope: env))
    }

    // MARK: - KnowledgeContext

    func testKnowledgeContext_economicKnowledgeConvenience() {
        let ctx = KnowledgeContext.economicKnowledge(asOf: day722)
        XCTAssertEqual(ctx.mode, .economicKnowledge(asOf: day722))
        XCTAssertNil(ctx.vintageFilter)
        XCTAssertNil(ctx.preferredProvider)
    }

    func testKnowledgeContext_operationalKnowledgeConvenience() {
        let ctx = KnowledgeContext.operationalKnowledge(asOf: day722)
        XCTAssertEqual(ctx.mode, .operationalKnowledge(asOf: day722))
    }

    func testKnowledgeContext_exactSnapshotConvenience() {
        let ctx = KnowledgeContext.exactSnapshot(at: day710)
        XCTAssertEqual(ctx.mode, .exactSnapshot(at: day710))
    }

    func testKnowledgeContext_withVintageFilter() {
        let vintage = Vintage(announcementDate: day720, publisherVersion: 2)
        let ctx = KnowledgeContext(
            mode: .exactSnapshot(at: day710),
            vintageFilter: vintage
        )
        XCTAssertEqual(ctx.vintageFilter, vintage)
    }

    func testKnowledgeContext_withPreferredProvider() {
        let ctx = KnowledgeContext(
            mode: .economicKnowledge(asOf: day722),
            preferredProvider: .eastmoney
        )
        XCTAssertEqual(ctx.preferredProvider, .eastmoney)
    }

    // MARK: - Codable round-trip

    func testDataQueryMode_codableRoundTrip_economic() throws {
        let mode = DataQueryMode.economicKnowledge(asOf: day722)
        let data = try JSONEncoder().encode(mode)
        let decoded = try JSONDecoder().decode(DataQueryMode.self, from: data)
        XCTAssertEqual(mode, decoded)
    }

    func testDataQueryMode_codableRoundTrip_operational() throws {
        let mode = DataQueryMode.operationalKnowledge(asOf: day722)
        let data = try JSONEncoder().encode(mode)
        let decoded = try JSONDecoder().decode(DataQueryMode.self, from: data)
        XCTAssertEqual(mode, decoded)
    }

    func testDataQueryMode_codableRoundTrip_exact() throws {
        let mode = DataQueryMode.exactSnapshot(at: day710)
        let data = try JSONEncoder().encode(mode)
        let decoded = try JSONDecoder().decode(DataQueryMode.self, from: data)
        XCTAssertEqual(mode, decoded)
    }

    func testKnowledgeContext_codableRoundTrip() throws {
        let ctx = KnowledgeContext(
            mode: .economicKnowledge(asOf: day722),
            vintageFilter: Vintage(announcementDate: day720, publisherVersion: 1),
            preferredProvider: .qieman
        )
        let data = try JSONEncoder().encode(ctx)
        let decoded = try JSONDecoder().decode(KnowledgeContext.self, from: data)
        XCTAssertEqual(ctx, decoded)
    }

    // MARK: - Sendable

    private actor ContextReceiver {
        func receive(_ ctx: KnowledgeContext) -> KnowledgeContext { ctx }
    }

    func testKnowledgeContext_sendableAcrossActor() async {
        let receiver = ContextReceiver()
        let ctx = KnowledgeContext.economicKnowledge(asOf: day722)
        let received = await receiver.receive(ctx)
        XCTAssertEqual(ctx, received)
    }
}
