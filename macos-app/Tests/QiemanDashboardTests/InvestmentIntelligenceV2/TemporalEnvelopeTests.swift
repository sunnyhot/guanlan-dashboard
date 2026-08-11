import XCTest
@testable import QiemanDashboard

/// DOM-4 单元测试：TemporalEnvelope 四时间 + 不变量校验 +
/// AvailabilityProvenance + Vintage 排序。
///
/// 重点验证 ADR-DATA005 §Decision 2「ingestedAt ≠ availableAt」语义
/// 和 ADR-DATA008 vintage 比较。
final class TemporalEnvelopeTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 0)

    // MARK: - TemporalEnvelope.validate() 不变量

    func testValidate_validOrdering() {
        let env = TemporalEnvelope(
            effectiveAt: date(2024, 6, 30),
            publishedAt: date(2024, 7, 20),
            availableAt: date(2024, 7, 21),
            ingestedAt: date(2024, 8, 1)
        )
        XCTAssertNil(env.validate())
    }

    func testValidate_effectiveAfterPublished() {
        let env = TemporalEnvelope(
            effectiveAt: date(2024, 7, 25),   // 晚于 publishedAt
            publishedAt: date(2024, 7, 20),
            availableAt: date(2024, 7, 21),
            ingestedAt: date(2024, 8, 1)
        )
        XCTAssertEqual(
            env.validate(),
            .effectiveAfterPublished(
                effectiveAt: date(2024, 7, 25),
                publishedAt: date(2024, 7, 20)
            )
        )
    }

    func testValidate_publishedAfterAvailable() {
        let env = TemporalEnvelope(
            effectiveAt: date(2024, 6, 30),
            publishedAt: date(2024, 7, 22),   // 晚于 availableAt
            availableAt: date(2024, 7, 21),
            ingestedAt: date(2024, 8, 1)
        )
        XCTAssertEqual(
            env.validate(),
            .publishedAfterAvailable(
                publishedAt: date(2024, 7, 22),
                availableAt: date(2024, 7, 21)
            )
        )
    }

    func testValidate_availableAfterIngested() {
        let env = TemporalEnvelope(
            effectiveAt: date(2024, 6, 30),
            publishedAt: date(2024, 7, 20),
            availableAt: date(2024, 8, 5),    // 晚于 ingestedAt
            ingestedAt: date(2024, 8, 1)
        )
        XCTAssertEqual(
            env.validate(),
            .availableAfterIngested(
                availableAt: date(2024, 8, 5),
                ingestedAt: date(2024, 8, 1)
            )
        )
    }

    func testValidate_equalTimestamps_ok() {
        // 任意相邻时间相等是允许的（如 publishedAt == availableAt）
        let d = date(2024, 7, 20)
        let env = TemporalEnvelope(
            effectiveAt: d, publishedAt: d, availableAt: d, ingestedAt: d
        )
        XCTAssertNil(env.validate())
    }

    // MARK: - M2 场景 4 预演：Provider 故障 ingestedAt ≠ availableAt

    func testM2Scenario4_ingestedLaterThanAvailable() {
        // 基金 Q2 持仓 7-20 公告，客观 7-21 可知（次交易日）；
        // 但 Provider 故障延迟到 8-01 才抓到。
        // ADR-DATA005：availableAt 仍记为客观的 7-21，ingestedAt 记为 8-01。
        let env = TemporalEnvelope(
            effectiveAt: date(2024, 6, 30),
            publishedAt: date(2024, 7, 20),
            availableAt: date(2024, 7, 21),
            ingestedAt: date(2024, 8, 1)
        )
        XCTAssertNil(env.validate())
        XCTAssertNotEqual(env.availableAt, env.ingestedAt)
        // 7-21 决策用 economicKnowledge(asOf: 7-21) 仍能看到这条数据
        // （具体查询逻辑在 REPO 阶段实现，这里只验证 envelope 语义）
    }

    // MARK: - Codable round-trip

    func testTemporalEnvelope_codableRoundTrip() throws {
        let env = TemporalEnvelope(
            effectiveAt: date(2024, 6, 30),
            publishedAt: date(2024, 7, 20),
            availableAt: date(2024, 7, 21),
            ingestedAt: date(2024, 8, 1)
        )
        let data = try JSONEncoder().encode(env)
        let decoded = try JSONDecoder().decode(TemporalEnvelope.self, from: data)
        XCTAssertEqual(env, decoded)
    }

    // MARK: - AvailabilityProvenance

    func testAvailabilityProvenance_codableRoundTrip() throws {
        let prov = AvailabilityProvenance(
            policyID: "fund_disclosure",
            policyVersion: "v1",
            derivedAt: date(2024, 7, 21)
        )
        let data = try JSONEncoder().encode(prov)
        let decoded = try JSONDecoder().decode(AvailabilityProvenance.self, from: data)
        XCTAssertEqual(prov, decoded)
        XCTAssertEqual(decoded.policyID, "fund_disclosure")
        XCTAssertEqual(decoded.policyVersion, "v1")
    }

    // MARK: - Vintage 排序（ADR-DATA008）

    func testVintage_orderingByAnnouncementDate() {
        let v1 = Vintage(announcementDate: date(2024, 7, 20), publisherVersion: 1)
        let v2 = Vintage(announcementDate: date(2024, 8, 15), publisherVersion: 1)
        XCTAssertTrue(v1 < v2)
        XCTAssertFalse(v2 < v1)
    }

    func testVintage_orderingSameDateByPublisherVersion() {
        let d = date(2024, 7, 20)
        let v1 = Vintage(announcementDate: d, publisherVersion: 1)
        let v2 = Vintage(announcementDate: d, publisherVersion: 2)
        XCTAssertTrue(v1 < v2)
    }

    func testVintage_sortLatest() {
        // 模拟 FRED GDP advance / second / third 三次修订
        let v1 = Vintage(announcementDate: date(2024, 1, 28), publisherVersion: 1)  // advance
        let v2 = Vintage(announcementDate: date(2024, 2, 28), publisherVersion: 1)  // second
        let v3 = Vintage(announcementDate: date(2024, 3, 28), publisherVersion: 1)  // third
        let latest = [v3, v1, v2].sorted().last  // economicKnowledge 选最新 vintage
        XCTAssertEqual(latest, v3)
    }

    func testVintage_codableRoundTrip() throws {
        let v = Vintage(announcementDate: date(2024, 7, 20), publisherVersion: 2)
        let data = try JSONEncoder().encode(v)
        let decoded = try JSONDecoder().decode(Vintage.self, from: data)
        XCTAssertEqual(v, decoded)
    }

    // MARK: - Sendable across actor

    private actor TemporalReceiver {
        func receive(_ env: TemporalEnvelope) -> TemporalEnvelope { env }
        func receive(_ v: Vintage) -> Vintage { v }
    }

    func testTemporalTypes_sendableAcrossActor() async {
        let receiver = TemporalReceiver()
        let env = TemporalEnvelope(
            effectiveAt: epoch, publishedAt: epoch,
            availableAt: epoch, ingestedAt: epoch
        )
        let v = Vintage(announcementDate: epoch, publisherVersion: 1)
        _ = await receiver.receive(env)
        _ = await receiver.receive(v)
    }

    // MARK: - 辅助

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        comps.hour = 0
        comps.minute = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: comps)!
    }
}
