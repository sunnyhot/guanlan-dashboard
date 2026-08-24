import XCTest
import GRDB
@testable import QiemanDashboard

/// 审查 P1-2 回归：Epic 7–10 五类 Artifact + AgentJob 的 GRDB 往返 codec。
/// 用真实内存数据库验证「事务写入 → 读出 → 领域对象相等」。
final class IntelligenceArtifactCodecTests: XCTestCase {

    /// 整毫秒 Date（payload JSON 默认 Date 策略为 double 秒，毫秒内无损）。
    private func date(_ ms: Int) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
    private func d(_ s: String) -> Decimal { Decimal(string: s)! }

    /// 内存 DatabaseQueue + 迁移（写操作走 db.write 包 inTransaction）。
    private var dbQueue: DatabaseQueue {
        get throws {
            let queue = try DatabaseQueue()
            try CanonicalDatabase.makeMigrations().migrate(queue)
            return queue
        }
    }

    // MARK: - 领域对象 fixture

    private func makeFactorSnapshot() -> FactorSnapshot {
        FactorEngine(calculators: [TrendFactorCalculator()]).snapshot(
            listingID: ListingID(rawValue: "L"),
            asOf: date(1_700_000_000_000),
            repository: InMemoryRepository(calendarBackend: WeekdayCalendarStub()),
            producedAt: date(1_700_000_000_000)
        )
    }

    private struct WeekdayCalendarStub: TradingCalendar {
        func isTradingDay(_ date: Date, jurisdiction: Jurisdiction) -> Bool { true }
        func tradingDay(after date: Date, offset: Int, jurisdiction: Jurisdiction) -> Date {
            date.addingTimeInterval(Double(offset) * 86400)
        }
        func tradingDayStart(_ date: Date, jurisdiction: Jurisdiction) -> Date { date }
    }

    private func makeAttribution() -> DailyAttribution {
        let result = AttributionEngine().compute(
            positions: [
                AttributionPositionInput(
                    subject: .fund(FundProductID(rawValue: "A")),
                    weight: Ratio(value: d("0.6")), periodReturn: Ratio(value: d("0.1")),
                    sourceObservationID: ObservationID(rawValue: "nav_a")
                ),
                AttributionPositionInput(
                    subject: .listing(ListingID(rawValue: "L1")),
                    weight: Ratio(value: d("0.4")), periodReturn: Ratio(value: d("-0.05")),
                    sourceObservationID: ObservationID(rawValue: "bar_l1")
                ),
            ],
            portfolioReturn: Ratio(value: d("0.045"))
        )!
        return DailyAttribution(
            attributionDate: date(1_700_000_000_000), portfolioKey: "p1",
            result: result, producedAt: date(1_700_000_000_000)
        )
    }

    private func makeLookthrough() -> LookthroughSnapshot {
        PortfolioLookthroughCalculator().compute(
            positions: [.init(weight: Ratio(value: 1), directListingID: ListingID(rawValue: "L1"))],
            disclosures: [], asOf: date(1_700_000_000_000), producedAt: date(1_700_000_000_000)
        )!
    }

    private func makeExposure() -> ExposureReport {
        ExposureEngine().compute(
            lookthrough: makeLookthrough(), holdings: [:],
            producedAt: date(1_700_000_000_000)
        )
    }

    private func makeRiskProfile() -> PortfolioRiskProfile {
        PortfolioRiskProfiler().profile(
            lookthrough: makeLookthrough(), series: [:],
            producedAt: date(1_700_000_000_000)
        )
    }

    private func makeDecision() -> PortfolioDecisionArtifact {
        let plan = TargetRebalancePlanner().plan(
            portfolio: PortfolioSnapshot(asOf: date(1_700_000_000_000), positions: [
                PortfolioPosition(subjectKey: "listing|A", assetClass: .equity, weight: Ratio(value: d("0.5"))),
            ]),
            target: nil, remediationTargets: [],
            userDirectives: [UserDirectiveInput(
                subjectKey: "listing|A", deltaWeight: Ratio(value: d("0.05")),
                directiveID: "u1", note: nil)],
            actionDomain: ActionDomain(
                perSubjectBounds: ["listing|A": .init(lower: Ratio(value: d("-1")), upper: Ratio(value: d("1")))],
                eligibleNewSubjects: [:], builderVersion: "t", newSubjectBuyUpper: Ratio(value: 1)),
            now: date(1_700_000_000_000)
        )
        return .assemble(
            signalIDs: [SignalID(rawValue: "s1")],
            criterionVersions: ["c@v1"],
            factorSnapshotIDs: [ArtifactID(rawValue: "fs_x")],
            target: nil, bandVersion: "b@v1",
            knowledgeContextSummary: "economicKnowledge(2024)",
            decision: PartialDecision(status: .singlePreferred, admissiblePlans: ["A"], explanation: "x"),
            plans: ["A": plan],
            producedAt: date(1_700_000_000_000)
        )
    }

    // MARK: - 往返测试

    private func roundTrip<A: Artifact & Encodable & Decodable>(
        _ domain: A, kind: String, decode: (ArtifactRow) throws -> A,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let queue = try dbQueue
        let pair = try ArtifactRow.from(domain, kind: kind)
        try queue.write { db in
            try ArtifactRow.write(pair, into: db)
        }

        let fetched = try queue.read({ db in
            try ArtifactRow.fetchOne(
                db, sql: "SELECT * FROM artifacts WHERE id = ?", arguments: [domain.id.rawValue]
            )
        })
        XCTAssertNotNil(fetched, file: file, line: line)
        let decoded = try decode(fetched!)
        XCTAssertEqual(decoded.id, domain.id, file: file, line: line)
        XCTAssertEqual(decoded, domain, file: file, line: line)

        // 依赖行完整落库（dep_index 顺序）
        let depCount = try queue.read({ db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM artifact_dependencies WHERE artifact_id = ?",
                arguments: [domain.id.rawValue]
            )
        })
        XCTAssertEqual(depCount, domain.dependencies.count, file: file, line: line)
    }

    func testFactorSnapshotRoundTrip() throws {
        try roundTrip(makeFactorSnapshot(), kind: ArtifactRow.factorSnapshotKind) { try $0.toFactorSnapshot() }
    }

    func testExposureReportRoundTrip() throws {
        try roundTrip(makeExposure(), kind: ArtifactRow.exposureReportKind) { try $0.toExposureReport() }
    }

    func testRiskProfileRoundTrip() throws {
        try roundTrip(makeRiskProfile(), kind: ArtifactRow.riskProfileKind) { try $0.toRiskProfile() }
    }

    func testDailyAttributionRoundTrip() throws {
        try roundTrip(makeAttribution(), kind: ArtifactRow.dailyAttributionKind) { try $0.toDailyAttribution() }
    }

    func testPortfolioDecisionRoundTrip() throws {
        try roundTrip(makeDecision(), kind: ArtifactRow.portfolioDecisionKind) { try $0.toPortfolioDecision() }
    }

    func testKindMismatchRejected() throws {
        let queue = try dbQueue
        let pair = try ArtifactRow.from(makeAttribution(), kind: ArtifactRow.dailyAttributionKind)
        try queue.write { db in
            try ArtifactRow.write(pair, into: db)
        }
        let fetched = try queue.read({ db in
            try ArtifactRow.fetchOne(db, sql: "SELECT * FROM artifacts WHERE id = ?", arguments: [pair.row.id])
        })
        XCTAssertThrowsError(try fetched?.toFactorSnapshot()) { error in
            guard case CanonicalColumnCodecError.unknownEnumValue = error else {
                return XCTFail("应为 kind 不匹配错误,实际 \(error)")
            }
        }
    }

    // MARK: - AgentJob 桥

    func testAgentJobRowRoundTrip() throws {
        // 走到 completed 的 job → 行 + 事件行落库,状态/时间/错误列还原
        var job = AgentJob(workflowKind: "dailyAttribution", inputFingerprint: "p1|1699999999", createdAt: date(1_700_000_000_000))
        try job.transition(to: .running, at: date(1_700_000_000_100))
        try job.transition(to: .completed, at: date(1_700_000_000_500), detail: "attr_x")

        let queue = try dbQueue
        let row = try AgentJobRow.from(job: job)
        try queue.write { db in
            try row.insert(db)
            for eventRow in AgentJobRow.eventRows(for: job) {
                try eventRow.insert(db)
            }
        }

        let fetched = try queue.read({ db in
            try AgentJobRow.fetchOne(
                db, sql: "SELECT * FROM agent_jobs WHERE id = ?", arguments: [job.id]
            )
        })
        XCTAssertNotNil(fetched)
        XCTAssertEqual(try fetched?.decodedStatus(), .completed)
        XCTAssertEqual(fetched?.idempotencyKey, "p1|1699999999")
        XCTAssertEqual(fetched?.startedAt, CanonicalColumnCodec.encodeTimestamp(date(1_700_000_000_100)))
        XCTAssertEqual(fetched?.completedAt, CanonicalColumnCodec.encodeTimestamp(date(1_700_000_000_500)))
        XCTAssertNil(fetched?.errorMessage)

        let eventCount = try queue.read({ db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM agent_job_events WHERE job_id = ?", arguments: [job.id]
            )
        })
        XCTAssertEqual(eventCount, 3, "queued + started + completed 三事件")
    }

    func testAgentJobFailedRowCarriesError() throws {
        var job = AgentJob(workflowKind: "k", inputFingerprint: "f", createdAt: date(1_700_000_000_000))
        try job.transition(to: .running, at: date(1_700_000_000_100))
        try job.transition(to: .failed, at: date(1_700_000_000_200), detail: "boom")
        let row = try AgentJobRow.from(job: job)
        XCTAssertEqual(row.status, "FAILED")
        XCTAssertEqual(row.errorMessage, "boom")
        XCTAssertEqual(row.completedAt, CanonicalColumnCodec.encodeTimestamp(date(1_700_000_000_200)))
    }
}
