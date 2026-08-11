import XCTest
@testable import QiemanDashboard

/// DOM-10 单元测试：Artifact 协议 + ValidityPolicy 五种模式 +
/// ArtifactDependency 引用。
///
/// 重点验证 V2.2 §84 的有效性判断 + D004 引用语义。
final class ArtifactTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_724_000_000)

    // MARK: - ValidityPolicy.isStillValid

    func testTimeBound_validBeforeExpiry() {
        let policy = ValidityPolicy.timeBound(validUntil: now.addingTimeInterval(3600))
        XCTAssertTrue(policy.isStillValid(at: now))
    }

    func testTimeBound_invalidAfterExpiry() {
        let policy = ValidityPolicy.timeBound(validUntil: now)
        XCTAssertFalse(policy.isStillValid(at: now.addingTimeInterval(1)))
    }

    func testTimeBound_validAtExactExpiry() {
        let policy = ValidityPolicy.timeBound(validUntil: now)
        XCTAssertTrue(policy.isStillValid(at: now))  // 边界含
    }

    func testUntilDependencyChanges_alwaysValidByTime() {
        // 粗粒度：时间维度永远 valid（精确判断需查 dependency 状态）
        let policy = ValidityPolicy.untilDependencyChanges
        XCTAssertTrue(policy.isStillValid(at: now))
        XCTAssertTrue(policy.isStillValid(at: now.addingTimeInterval(86400)))
    }

    func testTradingSession_validSameDay() {
        // 必须带 Exchange，时区按交易所法域推导（审查 P2 修复点）
        let cal = Calendar(identifier: .gregorian)
        let sessionDate = cal.date(from: DateComponents(year: 2024, month: 7, day: 22))!
        let policy = ValidityPolicy.tradingSession(exchange: .sse, sessionDate: sessionDate)
        let sameDay = cal.date(byAdding: .hour, value: 10, to: sessionDate)!
        XCTAssertTrue(policy.isStillValid(at: sameDay))
    }

    func testTradingSession_invalidNextDay() {
        let cal = Calendar(identifier: .gregorian)
        let sessionDate = cal.date(from: DateComponents(year: 2024, month: 7, day: 22))!
        let policy = ValidityPolicy.tradingSession(exchange: .sse, sessionDate: sessionDate)
        let nextDay = cal.date(byAdding: .day, value: 1, to: sessionDate)!
        XCTAssertFalse(policy.isStillValid(at: nextDay))
    }

    func testTradingSession_usesExchangeTimezone() {
        // 美股交易时段用 America/New_York 时区判断「同一天」。
        // 同一 UTC 时刻在 Shanghai 是次日、在 New York 仍是当日。
        // 带 exchange = .nasdaq 时应按 NY 时区判，不会因默认时区误判。
        var nyCal = Calendar(identifier: .gregorian)
        nyCal.timeZone = TimeZone(identifier: "America/New_York")!
        // 2024-07-22 14:00 NY（盘中）= 2024-07-23 02:00 Beijing
        let sessionDate = nyCal.date(from: DateComponents(
            year: 2024, month: 7, day: 22, hour: 9, minute: 30))!
        let policy = ValidityPolicy.tradingSession(exchange: .nasdaq, sessionDate: sessionDate)
        // 同一交易日 14:00 NY 仍 valid
        let sameSession = nyCal.date(byAdding: .hour, value: 5, to: sessionDate)!
        XCTAssertTrue(policy.isStillValid(at: sameSession))
    }

    func testImmutableHistorical_alwaysValid() {
        let policy = ValidityPolicy.immutableHistorical
        XCTAssertTrue(policy.isStillValid(at: now))
        XCTAssertTrue(policy.isStillValid(at: now.addingTimeInterval(86400 * 365)))
    }

    func testComposite_allValid_isValid() {
        let policy = ValidityPolicy.composite([
            .timeBound(validUntil: now.addingTimeInterval(3600)),
            .immutableHistorical,
        ])
        XCTAssertTrue(policy.isStillValid(at: now))
    }

    func testComposite_anyInvalid_isInvalid() {
        let policy = ValidityPolicy.composite([
            .timeBound(validUntil: now.addingTimeInterval(3600)),
            .timeBound(validUntil: now.addingTimeInterval(-3600)),  // 已过期
        ])
        XCTAssertFalse(policy.isStillValid(at: now))
    }

    // MARK: - ArtifactDependency

    func testArtifactDependency_withVersion() {
        let dep = ArtifactDependency(
            kind: .signal,
            referenceID: "sig_01J8Z3F9",
            version: "v2"
        )
        XCTAssertEqual(dep.kind, .signal)
        XCTAssertEqual(dep.referenceID, "sig_01J8Z3F9")
        XCTAssertEqual(dep.version, "v2")
    }

    func testArtifactDependency_withoutVersion() {
        let dep = ArtifactDependency(
            kind: .observation,
            referenceID: "obs_1"
        )
        XCTAssertNil(dep.version)
    }

    func testDependencyKind_allCases() {
        let kinds = [
            ArtifactDependency.DependencyKind.observation,
            .signal, .artifact, .factorSnapshot, .target, .policy,
        ]
        XCTAssertEqual(Set(kinds).count, 6)  // 6 种依赖类型
    }

    // MARK: - Artifact 协议 conformance（PlaceholderArtifact）

    func testPlaceholderArtifact_codableRoundTrip() throws {
        let artifact = PlaceholderArtifact(
            id: ArtifactID(rawValue: "art_1"),
            producedAt: now,
            validityPolicy: .timeBound(validUntil: now.addingTimeInterval(3600)),
            dependencies: [
                ArtifactDependency(kind: .observation, referenceID: "obs_1"),
                ArtifactDependency(kind: .signal, referenceID: "sig_1", version: "v1"),
            ],
            payload: "测试 artifact 内容"
        )
        let data = try JSONEncoder().encode(artifact)
        let decoded = try JSONDecoder().decode(PlaceholderArtifact.self, from: data)
        XCTAssertEqual(artifact, decoded)
        XCTAssertEqual(decoded.dependencies.count, 2)
    }

    // MARK: - ATR-2 联动：immutableHistorical for DailyAttribution

    func testDailyAttributionValidityPolicy_isImmutableHistorical() {
        // ATR-2: DailyAttribution artifact ValidityPolicy = immutableHistorical
        // 已发生的归因永不失效（即使数据修订，新 vintage 走新 artifact）
        let artifact = PlaceholderArtifact(
            id: ArtifactID(rawValue: "attr_2024_07_22"),
            producedAt: now,
            validityPolicy: .immutableHistorical,
            dependencies: [
                ArtifactDependency(kind: .observation, referenceID: "obs_bar_2024_07_22"),
            ],
            payload: "daily attribution"
        )
        XCTAssertTrue(artifact.validityPolicy.isStillValid(at: now))
        // 即使一年后仍 valid
        XCTAssertTrue(artifact.validityPolicy.isStillValid(at: now.addingTimeInterval(86400 * 365)))
    }

    // MARK: - ADR-D004 联动：引用 IDs 不可变

    func testArtifactDependencies_areReplayReferences() {
        // artifact 的 dependencies 是 D004 replay 的引用对象
        // 重放时按引用取，不重跑上游
        let deps = [
            ArtifactDependency(kind: .observation, referenceID: "obs_1", version: "v1"),
            ArtifactDependency(kind: .signal, referenceID: "sig_1", version: "v2"),
            ArtifactDependency(kind: .target, referenceID: "target_v1"),
        ]
        let artifact = PlaceholderArtifact(
            id: ArtifactID(rawValue: "art_replay"),
            producedAt: now,
            validityPolicy: .immutableHistorical,
            dependencies: deps,
            payload: ""
        )
        XCTAssertEqual(artifact.dependencies, deps)
        // 引用 IDs 不可变（写入后永不更改，ADR-D004）
        XCTAssertEqual(artifact.dependencies.count, 3)
    }

    // MARK: - Artifact 协议多态

    func testArtifact_polymorphicContainer() {
        let a1 = PlaceholderArtifact(
            id: ArtifactID(rawValue: "art_1"),
            producedAt: now, validityPolicy: .immutableHistorical,
            dependencies: [], payload: "a1"
        )
        let a2 = PlaceholderArtifact(
            id: ArtifactID(rawValue: "art_2"),
            producedAt: now, validityPolicy: .timeBound(validUntil: now),
            dependencies: [], payload: "a2"
        )
        let artifacts: [any Artifact] = [a1, a2]
        XCTAssertEqual(artifacts.count, 2)
        XCTAssertEqual(artifacts[0].id, ArtifactID(rawValue: "art_1"))
    }

    // MARK: - Sendable

    private actor ArtifactReceiver {
        func receive(_ a: PlaceholderArtifact) -> PlaceholderArtifact { a }
    }

    func testArtifact_sendableAcrossActor() async {
        let receiver = ArtifactReceiver()
        let artifact = PlaceholderArtifact(
            id: ArtifactID(rawValue: "art_send"),
            producedAt: now, validityPolicy: .immutableHistorical,
            dependencies: [], payload: ""
        )
        let received = await receiver.receive(artifact)
        XCTAssertEqual(artifact, received)
    }
}
