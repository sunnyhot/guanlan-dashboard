import XCTest
@testable import QiemanDashboard

/// DOM-6 单元测试：DataQueryMode 双模式 + KnowledgeContext 强制入参语义。
///
/// 重点验证 ADR-DATA002 §Decision 2/3：
/// - economicKnowledge 只返回 availableAt ≤ asOf（防 lookahead bias）
/// - exactSnapshot 返回 effectiveAt == at 的所有 vintage
/// - KnowledgeContext 不可省略 mode
final class KnowledgeContextTests: XCTestCase {

    private let day710 = Date(timeIntervalSince1970: 1_720_560_000)    // 2024-07-10 ish
    private let day720 = Date(timeIntervalSince1970: 1_721_424_000)    // 2024-07-20 ish
    private let day721 = Date(timeIntervalSince1970: 1_721_510_400)
    private let day801 = Date(timeIntervalSince1970: 1_724_262_400)

    // MARK: - DataQueryMode.includes

    func testEconomicKnowledge_includesAvailableBeforeAsOf() {
        let mode: DataQueryMode = .economicKnowledge(asOf: day721)
        // availableAt 7-21 ≤ 7-21 → 包含
        let env = TemporalEnvelope(
            effectiveAt: day710, publishedAt: day720,
            availableAt: day721, ingestedAt: day801
        )
        XCTAssertTrue(mode.includes(envelope: env))
    }

    func testEconomicKnowledge_excludesAvailableAfterAsOf() {
        let mode: DataQueryMode = .economicKnowledge(asOf: day710)
        // availableAt 7-21 > 7-10 → 排除（M2 场景 3 核心）
        let env = TemporalEnvelope(
            effectiveAt: day710, publishedAt: day720,
            availableAt: day721, ingestedAt: day801
        )
        XCTAssertFalse(mode.includes(envelope: env))
    }

    func testM2Scenario3_fundQ2HoldingNotVisibleAt710() {
        // 基金 Q2 持仓 effectiveAt 6-30，7-20 公告，客观 7-21 可知
        // economicKnowledge(asOf: 7-10) 必须查不到（防 lookahead bias）
        let mode: DataQueryMode = .economicKnowledge(asOf: day710)
        let env = TemporalEnvelope(
            effectiveAt: Date(timeIntervalSince1970: 1_719_715_200),  // 6-30
            publishedAt: day720,
            availableAt: day721,
            ingestedAt: day801
        )
        XCTAssertFalse(mode.includes(envelope: env))
    }

    func testM2Scenario4_visibleAt721EvenIngestedAt801() {
        // Provider 故障 8-01 抓到，但 availableAt 仍记客观的 7-21
        // economicKnowledge(asOf: 7-21) 应该能看到（不受 ingestedAt 延迟影响）
        let mode: DataQueryMode = .economicKnowledge(asOf: day721)
        let env = TemporalEnvelope(
            effectiveAt: Date(timeIntervalSince1970: 1_719_715_200),  // 6-30
            publishedAt: day720,
            availableAt: day721,
            ingestedAt: day801
        )
        XCTAssertTrue(mode.includes(envelope: env))
    }

    func testExactSnapshot_includesMatchingEffectiveAt() {
        let mode: DataQueryMode = .exactSnapshot(at: day710)
        let env = TemporalEnvelope(
            effectiveAt: day710, publishedAt: day720,
            availableAt: day721, ingestedAt: day801
        )
        XCTAssertTrue(mode.includes(envelope: env))
    }

    func testExactSnapshot_excludesNonMatchingEffectiveAt() {
        let mode: DataQueryMode = .exactSnapshot(at: day710)
        let env = TemporalEnvelope(
            effectiveAt: day720, publishedAt: day720,
            availableAt: day721, ingestedAt: day801
        )
        XCTAssertFalse(mode.includes(envelope: env))
    }

    // MARK: - 两种 mode 不可互换（语义不同）

    func testEconomicKnowledge_vs_exactSnapshot_semanticsDiffer() {
        // 同一个 envelope，在两种 mode 下结果不同
        let env = TemporalEnvelope(
            effectiveAt: day710, publishedAt: day720,
            availableAt: day721, ingestedAt: day801
        )
        let economic = DataQueryMode.economicKnowledge(asOf: day710)
        let snapshot = DataQueryMode.exactSnapshot(at: day710)
        // economicKnowledge(asOf:7-10)：availableAt 7-21 > 7-10 → 排除
        XCTAssertFalse(economic.includes(envelope: env))
        // exactSnapshot(at:7-10)：effectiveAt 7-10 == 7-10 → 包含
        XCTAssertTrue(snapshot.includes(envelope: env))
    }

    // MARK: - KnowledgeContext

    func testKnowledgeContext_economicKnowledgeConvenience() {
        let ctx = KnowledgeContext.economicKnowledge(asOf: day721)
        XCTAssertEqual(ctx.mode, .economicKnowledge(asOf: day721))
        XCTAssertNil(ctx.vintageFilter)
        XCTAssertNil(ctx.preferredProvider)
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
            mode: .economicKnowledge(asOf: day721),
            preferredProvider: .eastmoney
        )
        XCTAssertEqual(ctx.preferredProvider, .eastmoney)
    }

    // MARK: - Codable round-trip

    func testDataQueryMode_codableRoundTrip_economic() throws {
        let mode = DataQueryMode.economicKnowledge(asOf: day721)
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
            mode: .economicKnowledge(asOf: day721),
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
        let ctx = KnowledgeContext.economicKnowledge(asOf: day721)
        let received = await receiver.receive(ctx)
        XCTAssertEqual(ctx, received)
    }
}
