import XCTest
@testable import QiemanDashboard

/// ATTR-4 单元测试：DailyAttributionWorkflow + AgentJob/Event 生命周期。
final class DailyAttributionWorkflowTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_700_000_000)
    private let now = Date(timeIntervalSince1970: 1_700_086_400)

    private func r(_ s: String) -> Ratio { Ratio(value: Decimal(string: s)!) }

    /// 可编程 mock provider。
    private struct MockProvider: DailyAttributionInputProvider {
        var positionsResult: Result<[AttributionPositionInput], Error>
        var portfolioReturnResult: Result<Ratio?, Error> = .success(nil)

        func positions(portfolioKey: String, on date: Date) throws -> [AttributionPositionInput] {
            try positionsResult.get()
        }
        func portfolioReturn(portfolioKey: String, on date: Date) throws -> Ratio? {
            try portfolioReturnResult.get()
        }
    }

    private let samplePositions = [
        AttributionPositionInput(
            subject: .fund(FundProductID(rawValue: "A")), weight: Ratio(value: Decimal(string: "0.6")!),
            periodReturn: Ratio(value: Decimal(string: "0.1")!),
            sourceObservationID: ObservationID(rawValue: "nav_a")
        ),
        AttributionPositionInput(
            subject: .listing(ListingID(rawValue: "L1")), weight: Ratio(value: Decimal(string: "0.4")!),
            periodReturn: Ratio(value: Decimal(string: "-0.05")!),
            sourceObservationID: ObservationID(rawValue: "bar_l1")
        ),
    ]

    // MARK: - 正常路径

    func testHappyPathTransitionsQueuedRunningCompleted() {
        let workflow = DailyAttributionWorkflow(provider: MockProvider(
            positionsResult: .success(samplePositions),
            portfolioReturnResult: .success(Ratio(value: Decimal(string: "0.045")!))
        ))
        let outcome = workflow.run(portfolioKey: "qieman:LONG_WIN", on: day, now: now)

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.job.state, .completed)
        XCTAssertEqual(outcome.job.events.map(\.kind), [.queued, .started, .completed])
        XCTAssertEqual(outcome.job.events.last?.detail, outcome.artifact?.id.rawValue)
        // 事件时间线单调
        XCTAssertTrue(zip(outcome.job.events, outcome.job.events.dropFirst())
            .allSatisfy { $0.0.timestamp <= $0.1.timestamp })

        // artifact + 渲染都产出
        XCTAssertEqual(outcome.artifact?.result.attributedReturn.value, Decimal(string: "0.04"))
        XCTAssertEqual(outcome.rendered?.grade, .high)
        XCTAssertNil(outcome.errorDetail)
    }

    func testJobIdDeterministicByFingerprint() {
        let workflow = DailyAttributionWorkflow(provider: MockProvider(
            positionsResult: .success(samplePositions)
        ))
        let a = workflow.run(portfolioKey: "p1", on: day, now: now)
        let b = workflow.run(portfolioKey: "p1", on: day, now: now.addingTimeInterval(3600))
        XCTAssertEqual(a.job.id, b.job.id, "同 portfolioKey+date → 同 job(时间无关)")
        XCTAssertEqual(a.artifact?.id, b.artifact?.id)

        let other = workflow.run(portfolioKey: "p2", on: day, now: now)
        XCTAssertNotEqual(a.job.id, other.job.id)
        let otherDay = workflow.run(portfolioKey: "p1", on: day.addingTimeInterval(86400), now: now)
        XCTAssertNotEqual(a.job.id, otherDay.job.id)
    }

    // MARK: - failed 路径

    func testProviderErrorFailsJob() {
        struct Boom: Error {}
        let workflow = DailyAttributionWorkflow(provider: MockProvider(
            positionsResult: .failure(Boom())
        ))
        let outcome = workflow.run(portfolioKey: "p1", on: day, now: now)
        XCTAssertEqual(outcome.job.state, .failed)
        XCTAssertEqual(outcome.job.events.map(\.kind), [.queued, .started, .failed])
        XCTAssertNotNil(outcome.errorDetail)
        XCTAssertNil(outcome.artifact)
    }

    func testEmptyPortfolioFailsJob() {
        let workflow = DailyAttributionWorkflow(provider: MockProvider(
            positionsResult: .success([])
        ))
        let outcome = workflow.run(portfolioKey: "p1", on: day, now: now)
        XCTAssertEqual(outcome.job.state, .failed)
        XCTAssertNotNil(outcome.errorDetail)
    }

    // MARK: - 状态机守护

    func testStateMachineIllegalTransitions() {
        var job = AgentJob(workflowKind: "dailyAttribution", inputFingerprint: "f", createdAt: now)
        XCTAssertEqual(job.state, .queued)

        try? job.transition(to: .running, at: now)
        try? job.transition(to: .completed, at: now)
        XCTAssertEqual(job.state, .completed)
        XCTAssertTrue(job.state.isTerminal)

        // 终态不可再迁
        XCTAssertThrowsError(try job.transition(to: .running, at: now)) { error in
            XCTAssertEqual(error as? AgentJobStateError, .illegalTransition(from: .completed, to: .running))
        }
        XCTAssertThrowsError(try job.transition(to: .failed, at: now))

        // queued 不能直接 completed
        var job2 = AgentJob(workflowKind: "k", inputFingerprint: "f2", createdAt: now)
        XCTAssertThrowsError(try job2.transition(to: .completed, at: now))
        // queued / running 都可以 cancelled
        try? job2.transition(to: .cancelled, at: now)
        XCTAssertEqual(job2.state, .cancelled)

        var job3 = AgentJob(workflowKind: "k", inputFingerprint: "f3", createdAt: now)
        try? job3.transition(to: .running, at: now)
        try? job3.transition(to: .cancelled, at: now, detail: "user requested")
        XCTAssertEqual(job3.state, .cancelled)
        XCTAssertEqual(job3.events.last?.detail, "user requested")
    }

    // MARK: - Codable

    func testJobCodableRoundTrip() throws {
        let workflow = DailyAttributionWorkflow(provider: MockProvider(
            positionsResult: .success(samplePositions)
        ))
        let outcome = workflow.run(portfolioKey: "p1", on: day, now: now)
        let data = try JSONEncoder().encode(outcome.job)
        let decoded = try JSONDecoder().decode(AgentJob.self, from: data)
        XCTAssertEqual(decoded, outcome.job)
        XCTAssertEqual(decoded.workflowKind, "dailyAttribution")
    }
}
