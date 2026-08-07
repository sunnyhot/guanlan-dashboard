import XCTest
@testable import QiemanDashboard

final class DecisionCaseJournalStoreTests: XCTestCase {
    func testResearchRunRoundTripsAndUsesRestrictedPermissions() throws {
        let directory = makeTemporaryDirectory()
        let store = DecisionCaseJournalStore(baseDirectory: directory)
        let caseID = UUID()
        let report = makeReport(caseID: caseID)
        let record = DecisionCaseResearchRunRecord(
            caseID: caseID,
            startedAt: "2026-08-05 10:00:00",
            finishedAt: "2026-08-05 10:02:00",
            trigger: "用户手动",
            status: .succeeded,
            report: report
        )

        try store.saveResearchRun(record)

        XCTAssertEqual(try store.loadLatestResearchRun(caseID: caseID), record)
        let file = directory
            .appendingPathComponent(caseID.uuidString)
            .appendingPathComponent("research")
            .appendingPathComponent("\(record.id.uuidString).json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testReviewRoundTripsInChronologicalOrder() throws {
        let directory = makeTemporaryDirectory()
        let store = DecisionCaseJournalStore(baseDirectory: directory)
        let caseID = UUID()
        let later = makeReview(caseID: caseID, at: "2026-08-05 12:00:00")
        let earlier = makeReview(caseID: caseID, at: "2026-08-05 09:00:00")

        try store.saveReview(later)
        try store.saveReview(earlier)

        XCTAssertEqual(try store.loadReviews(caseID: caseID).map(\.id), [earlier.id, later.id])
    }

    func testLegacyBareReportDoesNotBreakRunLoading() throws {
        let directory = makeTemporaryDirectory()
        let store = DecisionCaseJournalStore(baseDirectory: directory)
        let caseID = UUID()
        let report = makeReport(caseID: caseID)
        let researchDirectory = directory
            .appendingPathComponent(caseID.uuidString)
            .appendingPathComponent("research")
        try FileManager.default.createDirectory(at: researchDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(report).write(
            to: researchDirectory.appendingPathComponent("legacy.json"),
            options: .atomic
        )

        XCTAssertNil(try store.loadLatestResearchRun(caseID: caseID))
        XCTAssertEqual(store.loadLegacyLatestResearch(caseID: caseID), report)
    }

    func testPresenterTreatsMissingPortfolioEvidenceAsInsufficientData() {
        let summary = InvestmentIntelligencePresenter.makeSummary(
            cases: [],
            rows: [],
            lookThroughSnapshot: nil,
            evaluatedAt: ""
        )

        XCTAssertEqual(summary.overallState, .insufficientData)
        XCTAssertNil(summary.lookThroughCoverageText)
        XCTAssertTrue(InvestmentIntelligence.releaseDefaultEnabled)
    }

    func testLegacyDirectoryRepositoryMigratesWithoutDeletingSource() throws {
        let baseDirectory = makeTemporaryDirectory()
        let decisionCase = makeDecisionCase()
        let caseDirectory = baseDirectory
            .appendingPathComponent("cases")
            .appendingPathComponent(decisionCase.id.uuidString)
        let researchDirectory = caseDirectory.appendingPathComponent("research")
        let reviewsDirectory = caseDirectory.appendingPathComponent("reviews")
        try FileManager.default.createDirectory(at: researchDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reviewsDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(decisionCase).write(
            to: caseDirectory.appendingPathComponent("case.json"),
            options: .atomic
        )

        let legacyRunID = UUID()
        let legacyRun: [String: Any] = [
            "id": legacyRunID.uuidString,
            "caseID": decisionCase.id.uuidString,
            "trigger": "automatic",
            "inputFingerprint": "legacy",
            "startedAt": "2026-08-05 08:00:00",
            "status": "cancelled",
            "providerName": "provider",
            "modelName": "model"
        ]
        try JSONSerialization.data(withJSONObject: legacyRun).write(
            to: researchDirectory.appendingPathComponent("\(legacyRunID.uuidString).json"),
            options: .atomic
        )
        let review = makeReview(caseID: decisionCase.id, at: "2026-08-05 09:00:00")
        try JSONEncoder().encode(review).write(
            to: reviewsDirectory.appendingPathComponent("\(review.id.uuidString).json"),
            options: .atomic
        )

        let journal = DecisionCaseJournalStore(baseDirectory: baseDirectory.appendingPathComponent("journals"))
        let migration = LegacyDecisionCaseMigration(baseDirectory: baseDirectory)
        let migrated = try migration.migrate(into: journal)

        XCTAssertEqual(migrated, [decisionCase])
        XCTAssertEqual(try journal.loadLatestResearchRun(caseID: decisionCase.id)?.id, legacyRunID)
        XCTAssertEqual(try journal.loadLatestResearchRun(caseID: decisionCase.id)?.status, .interrupted)
        XCTAssertEqual(try journal.loadReviews(caseID: decisionCase.id), [review])
        XCTAssertTrue(FileManager.default.fileExists(atPath: caseDirectory.path), "旧目录必须保留")
        XCTAssertFalse(migration.needsMigration)
        XCTAssertTrue(try migration.migrate(into: journal).isEmpty)
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("decision-journal-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeReport(caseID: UUID) -> DecisionCaseResearchReport {
        DecisionCaseResearchReport(
            caseID: caseID,
            generatedAt: "2026-08-05 10:02:00",
            suggestedState: .watch,
            rationale: "继续观察集中度变化"
        )
    }

    private func makeReview(caseID: UUID, at: String) -> DecisionReview {
        DecisionReview(
            caseID: caseID,
            reviewedAt: at,
            reviewHorizon: "7 天",
            originalDecisionState: .watch,
            originalMetricValue: 45,
            currentMetricValue: 42,
            conclusion: .partiallySupported
        )
    }

    private func makeDecisionCase() -> DecisionCase {
        DecisionCase(
            caseKey: "concentrationRisk|directHolding|000001",
            kind: .concentrationRisk,
            dimension: .directHolding,
            subjectName: "示例基金",
            subjectCode: "000001",
            lifecycle: .monitoring,
            decisionState: .watch,
            metricValue: 42,
            metricLabel: "42.0%",
            metricDescription: "第一大标的占比",
            title: "示例基金 · 持仓集中度偏高",
            detail: "测试迁移",
            createdAt: "2026-08-05 08:00:00",
            updatedAt: "2026-08-05 08:00:00",
            userDisposition: .acknowledged
        )
    }
}
