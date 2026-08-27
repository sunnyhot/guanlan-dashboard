import XCTest
@testable import QiemanDashboard

// MARK: - 研究证据明细读面测试（审计 A6）
//
// 覆盖：EvidenceRow 写入 → researchEvidence 查询（最新 vintage、来源
// 人话、数据截至、内容节选）；DashboardProjector 的信号明细派生（带
// 证据引用）；发现候选失效条件文案（审计 B2）。

final class ResearchEvidenceQueryTests: XCTestCase {

    private var repository: GRDBRepository!
    private var queryService: ArtifactQueryService!

    override func setUpWithError() throws {
        repository = GRDBRepository(
            database: try CanonicalDatabase(),
            calendarBackend: HolidayTableTradingCalendar.bundled)
        queryService = ArtifactQueryService(repository: repository)
    }

    private func writeEvidence(
        evidenceID: String, content: String, sourceDate: Date
    ) throws {
        let observation = try ResearchEvidenceFactory().observation(
            evidenceID: EvidenceID(rawValue: evidenceID),
            toolName: "web_search",
            content: .string(content),
            subject: .listing(ListingID(rawValue: "600519")),
            sourceDate: sourceDate,
            at: Date(timeIntervalSince1970: 1_800_000_000))
        _ = try repository.write(observation)
    }

    func testResearchEvidenceReturnsLatestVintageWithDigest() throws {
        let published = Date(timeIntervalSince1970: 1_799_000_000)
        try writeEvidence(evidenceID: "ev_a", content: "贵州茅台 2026 中报营收同比增长", sourceDate: published)
        try writeEvidence(evidenceID: "ev_b", content: "白酒板块动量回升", sourceDate: published)

        let digests = try queryService.researchEvidence(evidenceIDs: ["ev_a", "ev_b", "ev_missing"])
        XCTAssertEqual(digests.count, 2, "未入库的 ID 静默跳过")
        XCTAssertEqual(digests[0].evidenceID, "ev_a")
        XCTAssertEqual(digests[0].sourceName, "网络检索", "来源 raw → 人话")
        XCTAssertTrue(digests[0].contentExcerpt.contains("贵州茅台"))
        XCTAssertEqual(digests[0].publishedAt, published, "数据截至 = publishedAt")
        XCTAssertTrue(digests[0].id.hasPrefix("obs_"))
    }

    func testResearchEvidenceEmptyInput() throws {
        XCTAssertTrue(try queryService.researchEvidence(evidenceIDs: []).isEmpty)
    }

    // MARK: - Projector：信号明细（A6）+ 失效条件（B2）

    func testDashboardSnapshotCarriesSignalDetailsAndInvalidation() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let subject = CanonicalRef.fundShareClass(
            FundShareClassID(rawValue: "portfolio_live"))

        // 证据 + 信号入库（portfolio subject）
        try writeEvidence(evidenceID: "ev_p1", content: "组合层面证据", sourceDate: now)
        let signal = InvestmentSignal(
            id: SignalID(rawValue: "sig_p1"),
            subjectCanonical: subject,
            dimension: .momentum,
            direction: .bullish,
            strength: .strong,
            derivedFromEvidenceIDs: [EvidenceID(rawValue: "ev_p1")],
            effectiveAt: now,
            producer: SignalProducer(kind: .llm, modelIdentifier: "test-model"),
            rationale: "动量修复")
        _ = try repository.write(signal)

        // 发现报告（带因子 metrics → 失效条件派生）
        let seedCandidate = DiscoveryCandidate(
            universeKey: "test_universe",
            listingID: ListingID(rawValue: "600519"),
            displayName: "贵州茅台",
            score: Decimal(string: "0.8")!,
            metrics: [
                "momentum_20d": Decimal(string: "1.2")!,
                "trend_60d": Decimal(string: "0.5")!,
            ],
            factorSnapshotID: ArtifactID(rawValue: "fsnap_test"),
            rank: 1)
        let report = MarketDiscoveryReport(
            id: ArtifactID(rawValue: "mkt_test_report"),
            producedAt: now,
            validityPolicy: .untilDependencyChanges,
            dependencies: [],
            asOf: now,
            universeVersion: 1,
            rankingPolicy: DiscoveryRankingPolicy(),
            candidates: [seedCandidate],
            coverageGaps: [])
        try repository.writeMarketDiscoveryReport(report)

        let materials = IntelligenceDashboardUserMaterials(
            currentTarget: nil,
            resolvableTargetIDs: [],
            currentClassWeights: nil,
            unresolvedSubjects: [],
            valuationStaleAsOf: nil,
            providerConfigured: true)
        let snapshot = try queryService.dashboardSnapshot(userMaterials: materials, now: now)

        // A6：信号明细带证据引用
        XCTAssertEqual(snapshot.research?.signalDetails.count, 1)
        let detail = snapshot.research?.signalDetails.first
        XCTAssertEqual(detail?.id, "sig_p1")
        XCTAssertEqual(detail?.evidenceIDs, ["ev_p1"])
        XCTAssertTrue(detail?.text.contains("MOMENTUM") == true)

        // B2：候选失效条件非空且含人工复核标注
        let candidate = snapshot.discovery?.topCandidates.first
        XCTAssertNotNil(candidate?.invalidationNote)
        XCTAssertTrue(candidate?.invalidationNote.contains("人工复核") == true)
        XCTAssertTrue(candidate?.invalidationNote.contains("动量") == true)
    }
}
