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
            comparison: PlanComparisonResult(pairwise: [:], paretoFront: ["A"], blockingUnknowns: []),
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

    func testLookthroughSnapshotRoundTrip() throws {
        // 二轮审查 P1-5:LookthroughSnapshot(第 6 类)codec 补齐
        try roundTrip(makeLookthrough(), kind: ArtifactRow.lookthroughSnapshotKind) { try $0.toLookthroughSnapshot() }
    }

    func testWriteIsIdempotentOnIdenticalReplay() throws {
        // 二轮审查 P1-5:同语义 ID 重放第二次 = no-op(不再主键冲突)
        let queue = try dbQueue
        let domain = makeAttribution()
        let pair = try ArtifactRow.from(domain, kind: ArtifactRow.dailyAttributionKind)
        try queue.write { db in
            try ArtifactRow.write(pair, into: db)
        }
        // 第二次写入同内容 → no-op 不抛
        XCTAssertNoThrow(try queue.write { db in
            try ArtifactRow.write(pair, into: db)
        })
        // 行数仍 1
        let count = try queue.read({ db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artifacts")!
        })
        XCTAssertEqual(count, 1)
    }

    func testRecomputedArtifactWithLaterProducedAtIsIdempotent() throws {
        // 三轮 P1-2 回归:ID 不含 producedAt——稍后重算同语义(不同 producedAt)
        // 必须幂等通过,且库里保留首次产出时间
        let queue = try dbQueue
        let first = makeAttribution()   // producedAt = date(1_700_000_000_000)
        let laterResult = AttributionEngine().compute(
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
        let recomputed = DailyAttribution(
            attributionDate: first.attributionDate, portfolioKey: first.portfolioKey,
            result: laterResult,
            producedAt: date(1_700_086_400_000)   // 更晚的重算时间
        )
        XCTAssertEqual(first.id, recomputed.id, "同语义同 ID(producedAt 排除)")

        let firstPair = try ArtifactRow.from(first, kind: ArtifactRow.dailyAttributionKind)
        let recomputedPair = try ArtifactRow.from(recomputed, kind: ArtifactRow.dailyAttributionKind)
        try queue.write { db in
            try ArtifactRow.write(firstPair, into: db)
        }
        // 稍后重算写入 → no-op(不再伪冲突)
        XCTAssertNoThrow(try queue.write { db in
            try ArtifactRow.write(recomputedPair, into: db)
        })
        // 库里保留首次 producedAt
        let stored = try queue.read({ db in
            try ArtifactRow.fetchOne(db, sql: "SELECT * FROM artifacts WHERE id = ?", arguments: [first.id.rawValue])
        })
        XCTAssertEqual(stored?.producedAt, CanonicalColumnCodec.encodeTimestamp(date(1_700_000_000_000)),
                       "首次产出时间保留")
    }

    func testFetchDomainRejectsDependencyDivergence() throws {
        // 五轮 P1-4 回归:依赖表缺行 / 错行 → split-brain 拒收(fail-closed)
        let queue = try dbQueue
        let domain = makeAttribution()
        let pair = try ArtifactRow.from(domain, kind: ArtifactRow.dailyAttributionKind)
        try queue.write { db in
            try pair.row.insert(db)
            // 只写部分依赖行(漏一条)
            for dep in pair.dependencies.dropLast() {
                try dep.insert(db)
            }
        }
        XCTAssertThrowsError(try queue.read({ db in
            try ArtifactRow.fetchDomain(DailyAttribution.self, id: domain.id.rawValue,
                                         expectedKind: ArtifactRow.dailyAttributionKind, from: db)
        })) { error in
            guard case ArtifactReadError.dependencyDivergence = error else {
                return XCTFail("应为依赖分歧,实际 \(error)")
            }
        }
    }

    func testFetchDomainRoundTripWhenConsistent() throws {
        // 依赖表完整时 → 领域对象相等读回
        let queue = try dbQueue
        let domain = makeAttribution()
        let pair = try ArtifactRow.from(domain, kind: ArtifactRow.dailyAttributionKind)
        try queue.write { db in
            try ArtifactRow.write(pair, into: db)
        }
        let fetched = try queue.read({ db in
            try ArtifactRow.fetchDomain(DailyAttribution.self, id: domain.id.rawValue,
                                        expectedKind: ArtifactRow.dailyAttributionKind, from: db)
        })
        XCTAssertEqual(fetched, domain)
    }

    func testAgentJobRebuildRejectsForeignEvents() throws {
        // 三轮 P2-8 回归:混入其他作业的事件(状态相同)→ 身份闭环拒收
        var job = AgentJob(workflowKind: "k", inputFingerprint: "f", createdAt: date(1_700_000_000_000))
        try job.transition(to: .running, at: date(1_700_000_000_100))
        try job.transition(to: .completed, at: date(1_700_000_000_300))
        // 另一作业(同 workflow/状态,不同指纹与事件时间——可区分)
        var other = AgentJob(workflowKind: "k", inputFingerprint: "FOREIGN", createdAt: date(1_700_000_000_000))
        try other.transition(to: .running, at: date(1_700_000_000_999))
        try other.transition(to: .completed, at: date(1_700_000_000_888))

        let queue = try dbQueue
        let row = try AgentJobRow.from(job: job)
        try queue.write { db in
            try row.insert(db)
            // 混入 foreign 作业的事件(job_id 却指向本 job)
            for (index, event) in try AgentJobRow.eventRows(for: other).enumerated() {
                let foreign = AgentJobEventRow(
                    jobID: job.id, seq: index,
                    occurredAt: event.occurredAt, kind: event.kind, payloadJSON: event.payloadJSON
                )
                try foreign.insert(db)
            }
        }
        let events = try queue.read({ db in
            try AgentJobEventRow.filter(Column("job_id") == job.id).order(Column("seq")).fetchAll(db)
        })
        XCTAssertThrowsError(try row.toAgentJob(events: events)) { error in
            guard case AgentJobRow.JobCodecError.identityMismatch = error else {
                return XCTFail("应为身份闭环失败,实际 \(error)")
            }
        }
    }

    func testWriteConflictsOnDivergedContent() throws {
        // 二轮审查 P1-5:同 ID 内容不一致 → conflict(不静默覆盖)
        let queue = try dbQueue
        let original = makeAttribution()
        let pair = try ArtifactRow.from(original, kind: ArtifactRow.dailyAttributionKind)
        try queue.write { db in
            try ArtifactRow.write(pair, into: db)
        }
        // 构造同 ID 不同 payload 的行(不同 result 的 attribution 复用 id)
        let divergent = DailyAttribution(
            attributionDate: original.attributionDate, portfolioKey: original.portfolioKey,
            result: AttributionEngine().compute(
                positions: [
                    AttributionPositionInput(
                        subject: .fund(FundProductID(rawValue: "A")),
                        weight: Ratio(value: d("0.5")), periodReturn: Ratio(value: d("0.1")),
                        sourceObservationID: ObservationID(rawValue: "nav_a")
                    ),
                ],
                portfolioReturn: nil
            )!,
            producedAt: original.producedAt
        )
        // 覆盖 id 使其与 original 相同
        let divergentPair = try ArtifactRow.from(divergent, kind: ArtifactRow.dailyAttributionKind)
        let forged = (row: ArtifactRow(
            id: original.id.rawValue, artifactKind: divergentPair.row.artifactKind,
            producedAt: divergentPair.row.producedAt,
            validityPolicyJSON: divergentPair.row.validityPolicyJSON,
            payloadJSON: divergentPair.row.payloadJSON
        ), dependencies: divergentPair.dependencies)
        XCTAssertThrowsError(try queue.write { db in
            try ArtifactRow.write(forged, into: db)
        }) { error in
            XCTAssertEqual(error as? ArtifactWriteError,
                           .conflict(artifactID: original.id.rawValue, field: "payload_json(semantic)"))
        }
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
            for eventRow in try AgentJobRow.eventRows(for: job) {
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
        XCTAssertEqual(fetched?.idempotencyKey, "dailyAttribution|p1|1699999999", "幂等键含 workflow 前缀")
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

    func testAgentJobRoundTripRebuildsDomain() throws {
        // 二轮审查 P1-6:job + 事件行 → AgentJob 领域对象往返
        var job = AgentJob(workflowKind: "dailyAttribution", inputFingerprint: "p|1", createdAt: date(1_700_000_000_000))
        try job.transition(to: .running, at: date(1_700_000_000_100))
        // detail 含引号/反斜杠/换行(曾产生非法 JSON)
        try job.transition(to: .failed, at: date(1_700_000_000_200), detail: "boom \"quote\" \\slash\nnewline")

        let queue = try dbQueue
        let row = try AgentJobRow.from(job: job)
        try queue.write { db in
            try row.insert(db)
            for eventRow in try AgentJobRow.eventRows(for: job) {
                try eventRow.insert(db)
            }
        }
        let fetched = try queue.read({ db in
            try AgentJobRow.fetchOne(db, sql: "SELECT * FROM agent_jobs WHERE id = ?", arguments: [job.id])
        })
        let eventRows = try queue.read({ db in
            try AgentJobEventRow.filter(Column("job_id") == job.id).order(Column("seq")).fetchAll(db)
        })
        let rebuilt = try fetched?.toAgentJob(events: eventRows)
        XCTAssertEqual(rebuilt, job, "双向往返:状态/事件/时间戳/detail 全等")
        XCTAssertEqual(rebuilt?.events.last?.detail, "boom \"quote\" \\slash\nnewline", "特殊字符 detail 完整保留")

        // nil detail 不降格为空串
        var nilDetailJob = AgentJob(workflowKind: "k2", inputFingerprint: "f2", createdAt: date(1_700_000_000_000))
        try nilDetailJob.transition(to: .running, at: date(1_700_000_000_100))
        try nilDetailJob.transition(to: .completed, at: date(1_700_000_000_300), detail: nil)
        let nilRow = try AgentJobRow.from(job: nilDetailJob)
        try queue.write { db in
            try nilRow.insert(db)
            for eventRow in try AgentJobRow.eventRows(for: nilDetailJob) {
                try eventRow.insert(db)
            }
        }
        let nilFetched = try queue.read({ db in
            try AgentJobRow.fetchOne(db, sql: "SELECT * FROM agent_jobs WHERE id = ?", arguments: [nilDetailJob.id])
        })
        let nilEvents = try queue.read({ db in
            try AgentJobEventRow.filter(Column("job_id") == nilDetailJob.id).order(Column("seq")).fetchAll(db)
        })
        let nilRebuilt = try nilFetched?.toAgentJob(events: nilEvents)
        XCTAssertNil(nilRebuilt?.events.last?.detail, "nil detail 保留 nil 语义")
        XCTAssertEqual(nilRebuilt, nilDetailJob)
    }

    func testIdempotencyKeyIncludesWorkflow() throws {
        // 二轮审查 P1-6:不同 workflow 同指纹不撞 UNIQUE
        let a = AgentJob(workflowKind: "dailyAttribution", inputFingerprint: "shared", createdAt: date(1))
        let b = AgentJob(workflowKind: "marketDiscovery", inputFingerprint: "shared", createdAt: date(1))
        let rowA = try AgentJobRow.from(job: a)
        let rowB = try AgentJobRow.from(job: b)
        XCTAssertNotEqual(rowA.idempotencyKey, rowB.idempotencyKey)
        XCTAssertEqual(rowA.idempotencyKey, "dailyAttribution|shared")

        let queue = try dbQueue
        try queue.write { db in
            try rowA.insert(db)
            try rowB.insert(db)   // 同指纹不同 workflow → 不再 UNIQUE 冲突
        }
    }

    func testStatusMismatchRebuildRejected() throws {
        // 行 status 与事件时间线不一致 → 反向 codec 拒绝
        var job = AgentJob(workflowKind: "k", inputFingerprint: "f", createdAt: date(1_700_000_000_000))
        try job.transition(to: .running, at: date(1_700_000_000_100))
        try job.transition(to: .completed, at: date(1_700_000_000_300))
        var row = try AgentJobRow.from(job: job)
        // 篡改行 status 为 FAILED
        row = AgentJobRow(
            id: row.id, workflow: row.workflow, idempotencyKey: row.idempotencyKey,
            status: "FAILED", inputJSON: row.inputJSON, createdAt: row.createdAt,
            startedAt: row.startedAt, completedAt: row.completedAt, errorMessage: row.errorMessage
        )
        let queue = try dbQueue
        try queue.write { db in
            try row.insert(db)
            for eventRow in try AgentJobRow.eventRows(for: job) {
                try eventRow.insert(db)
            }
        }
        let fetched = try queue.read({ db in
            try AgentJobRow.fetchOne(db, sql: "SELECT * FROM agent_jobs WHERE id = ?", arguments: [job.id])
        })
        let events = try queue.read({ db in
            try AgentJobEventRow.filter(Column("job_id") == job.id).order(Column("seq")).fetchAll(db)
        })
        XCTAssertThrowsError(try fetched?.toAgentJob(events: events)) { error in
            guard case AgentJobRow.JobCodecError.statusMismatch = error else {
                return XCTFail("应为 statusMismatch,实际 \(error)")
            }
        }
    }

    func testAgentJobRebuildRejectsStrippedRedundantColumns() throws {
        // 四轮 P2-6 回归:删掉 startedAt 列但保留 STARTED 事件 → 不再静默通过
        var job = AgentJob(workflowKind: "k", inputFingerprint: "f", createdAt: date(1_700_000_000_000))
        try job.transition(to: .running, at: date(1_700_000_000_100))
        try job.transition(to: .completed, at: date(1_700_000_000_300))

        let queue = try dbQueue
        var row = try AgentJobRow.from(job: job)
        // 篡改:startedAt 置 nil(事件保留)
        row = AgentJobRow(
            id: row.id, workflow: row.workflow, idempotencyKey: row.idempotencyKey,
            status: row.status, inputJSON: row.inputJSON, createdAt: row.createdAt,
            startedAt: nil, completedAt: row.completedAt, errorMessage: row.errorMessage
        )
        try queue.write { db in
            try row.insert(db)
            for eventRow in try AgentJobRow.eventRows(for: job) {
                try eventRow.insert(db)
            }
        }
        let fetched = try queue.read({ db in
            try AgentJobRow.fetchOne(db, sql: "SELECT * FROM agent_jobs WHERE id = ?", arguments: [job.id])
        })
        let events = try queue.read({ db in
            try AgentJobEventRow.filter(Column("job_id") == job.id).order(Column("seq")).fetchAll(db)
        })
        XCTAssertThrowsError(try fetched?.toAgentJob(events: events)) { error in
            guard case AgentJobRow.JobCodecError.identityMismatch = error else {
                return XCTFail("应冗余列不一致,实际 \(error)")
            }
        }
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
