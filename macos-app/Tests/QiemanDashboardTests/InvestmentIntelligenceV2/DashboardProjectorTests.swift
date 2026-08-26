import XCTest
@testable import QiemanDashboard

// P1 产品重构 §7.1 / §12.3：Dashboard 投影 golden tests。
//
// 锁定：全状态矩阵（never-run / missing-target / unclassified / stale /
// provider-missing / hold / execute / expired）、旧自复制 Target 产物不进
// 有效结论但保留历史、Discovery 两态区分（无候选 ≠ 数据不足）、
// 投影不改决策语义（只做形态映射）。

private let projDay = Date(timeIntervalSince1970: 1_860_000_000) // 2028-12-10 CST

final class DashboardProjectorTests: XCTestCase {

    private var repository: GRDBRepository!
    private var service: ArtifactQueryService!

    override func setUpWithError() throws {
        repository = GRDBRepository(
            database: try CanonicalDatabase(),
            calendarBackend: TestWeekdayCalendar())
        service = ArtifactQueryService(repository: repository)
    }

    // MARK: - fixtures

    private func makeCompleteTarget(now: Date = projDay) throws -> AllocationTarget {
        try StrategicAllocationPolicy().applyUserAllocation(
            entries: AssetClass.allCases.map { assetClass in
                AllocationTargetEntry(
                    assetClass: assetClass,
                    targetWeight: Ratio(value: assetClass == .equity
                        ? Decimal(string: "0.6")!
                        : Decimal(string: "0.1")!))
            },
            note: nil, now: now)
    }

    private func readyMaterials(
        target: AllocationTarget? = nil,
        resolvable: Set<String> = [],
        unresolved: [String] = [],
        staleAsOf: Date? = nil,
        provider: Bool = true,
        classWeights: [AssetClass: Decimal]? = [.equity: Decimal(string: "0.62")!]
    ) throws -> IntelligenceDashboardUserMaterials {
        let theTarget = try target ?? makeCompleteTarget()
        return IntelligenceDashboardUserMaterials(
            currentTarget: theTarget,
            resolvableTargetIDs: resolvable.isEmpty && theTarget != nil
                ? [theTarget.id.rawValue] : resolvable,
            currentClassWeights: unresolved.isEmpty ? classWeights : nil,
            unresolvedSubjects: unresolved,
            valuationStaleAsOf: staleAsOf,
            providerConfigured: provider)
    }

    private func makeIntradayReport(
        decision: IntradayDecisionKind,
        target: AllocationTarget?,
        holdReasons: [String] = [],
        actions: [PlannedAction] = [],
        validity: ValidityPolicy = .tradingSession(exchange: .otc, sessionDate: projDay),
        producedAt: Date = projDay
    ) throws -> IntradayExecutionReport {
        IntradayExecutionReport(
            id: ArtifactID(
                rawValue: "intra_\(decision.rawValue)_\(target?.id.rawValue ?? "none")_\(Int(producedAt.timeIntervalSince1970))"),
            producedAt: producedAt,
            validityPolicy: validity,
            dependencies: [],
            asOf: producedAt,
            decision: decision,
            eligibility: IntradayEligibilityPolicy(),
            plan: actions.isEmpty ? nil : PortfolioActionPlan(
                id: "plan_\(Int(producedAt.timeIntervalSince1970))",
                asOf: producedAt,
                targetID: target?.id,
                actions: actions,
                notes: [],
                plannerVersion: "test"),
            gateVerdict: nil,
            holdReasons: holdReasons,
            referencedSignalIDs: [],
            target: target)
    }

    private func write(_ report: IntradayExecutionReport) throws {
        try repository.database.queue.write { db in
            try ArtifactRow.write(try ArtifactRow.from(report), into: db)
        }
    }

    private func makeDiscoveryReport(
        candidates: [DiscoveryCandidate],
        gaps: [DiscoveryCoverageGap],
        producedAt: Date = projDay
    ) throws -> MarketDiscoveryReport {
        MarketDiscoveryReport(
            id: ArtifactID(
                rawValue: "disc_\(Int(producedAt.timeIntervalSince1970))_\(candidates.count)_\(gaps.count)"),
            producedAt: producedAt,
            validityPolicy: .untilDependencyChanges,
            dependencies: [],
            asOf: producedAt,
            universeVersion: 1,
            rankingPolicy: DiscoveryRankingPolicy(),
            candidates: candidates,
            coverageGaps: gaps)
    }

    private func candidate(_ rank: Int, name: String) -> DiscoveryCandidate {
        DiscoveryCandidate(
            universeKey: "test-\(rank)",
            listingID: ListingID(rawValue: "test-\(rank)"),
            displayName: name,
            score: Decimal(1) - Decimal(rank),
            metrics: [
                "momentum.return60": Decimal(string: "0.12")!,
                "trend.closeVsMA20": Decimal(string: "-0.05")!,
            ],
            factorSnapshotID: ArtifactID(rawValue: "fs-\(rank)"),
            rank: rank)
    }

    private func gap(_ key: String) -> DiscoveryCoverageGap {
        DiscoveryCoverageGap(
            universeKey: key,
            listingID: ListingID(rawValue: key),
            reason: "insufficient metrics")
    }

    // MARK: - 状态矩阵

    func testNeverRunBaselineIsUndecidableWithReadyInputs() throws {
        let materials = try readyMaterials()
        let snapshot = try service.dashboardSnapshot(userMaterials: materials, now: projDay)
        XCTAssertEqual(snapshot.headline.status, .undecidable)
        XCTAssertNil(snapshot.readiness.blocker)
        XCTAssertNil(snapshot.intraday)
        XCTAssertNil(snapshot.discovery)
        XCTAssertFalse(snapshot.history.isEmpty == false, "空库无历史")
        XCTAssertTrue(snapshot.history.isEmpty)
        // allocation 五类全展示
        XCTAssertEqual(snapshot.allocation.rows.count, AssetClass.allCases.count)
        XCTAssertEqual(snapshot.allocation.rows.first?.currentWeight, Decimal(string: "0.62"))
    }

    func testMissingTargetBlocksEverything() throws {
        let materials = IntelligenceDashboardUserMaterials(
            currentTarget: nil, resolvableTargetIDs: [],
            currentClassWeights: [.equity: Decimal(string: "0.62")!],
            unresolvedSubjects: [], valuationStaleAsOf: nil,
            providerConfigured: true)
        let snapshot = try service.dashboardSnapshot(userMaterials: materials, now: projDay)
        XCTAssertEqual(snapshot.headline.status, .notReady)
        XCTAssertEqual(snapshot.readiness.blocker, .missingTarget)
        XCTAssertFalse(snapshot.allocation.targetConfigured)
        // 无目标时偏差列不显示（deviation nil，不伪装 0 偏差）
        XCTAssertTrue(snapshot.allocation.rows.allSatisfy { $0.deviation == nil })
    }

    func testUnclassifiedHoldingsBlock() throws {
        let materials = try readyMaterials(unresolved: ["fund|000009", "fund|000010"])
        let snapshot = try service.dashboardSnapshot(userMaterials: materials, now: projDay)
        XCTAssertEqual(snapshot.readiness.blocker, .unclassifiedHoldings(["fund|000009", "fund|000010"]))
        XCTAssertEqual(snapshot.headline.status, .notReady)
        // 分类阻断时当前占比不显示（nil ≠ 0）
        XCTAssertTrue(snapshot.allocation.rows.allSatisfy { $0.currentWeight == nil })
    }

    func testStaleValuationBlocks() throws {
        let staleDate = projDay.addingTimeInterval(-14 * 86_400)
        let materials = try readyMaterials(staleAsOf: staleDate)
        let snapshot = try service.dashboardSnapshot(userMaterials: materials, now: projDay)
        XCTAssertEqual(snapshot.readiness.blocker, .staleValuation(latestAsOf: staleDate))
    }

    func testProviderMissingSurfacesInReadiness() throws {
        let materials = try readyMaterials(provider: false)
        let snapshot = try service.dashboardSnapshot(userMaterials: materials, now: projDay)
        XCTAssertFalse(snapshot.readiness.providerConfigured)
    }

    // MARK: - 盘中结论（resolvable target 过滤 + hold/execute/expired）

    func testHoldReportProducesHoldHeadline() throws {
        let target = try makeCompleteTarget()
        try write(try makeIntradayReport(
            decision: .hold, target: target,
            holdReasons: ["当前配置与战略目标差异均小于 5%"]))
        let materials = try readyMaterials()
        let snapshot = try service.dashboardSnapshot(userMaterials: materials, now: projDay)
        XCTAssertEqual(snapshot.headline.status, .holdConfigured)
        XCTAssertEqual(snapshot.intraday?.decision, .hold)
        XCTAssertEqual(snapshot.intraday?.validity, .current)
        XCTAssertEqual(
            snapshot.intraday?.holdReasons.first,
            "当前配置与战略目标差异均小于 5%")
        XCTAssertTrue(
            snapshot.headline.reason.contains("小于 5%"),
            "HOLD 原因透出到 headline reason")
    }

    func testExecuteReportProducesRebalanceHeadlineWithTargetProvenanceMoves() throws {
        let target = try makeCompleteTarget()
        let actions = [
            PlannedAction(
                action: PortfolioAction(
                    subjectKey: "fund|000002",
                    deltaWeight: Ratio(value: Decimal(string: "-0.08")!)),
                provenance: .targetRebalance(.init(
                    targetID: target.id, targetCreatedAt: target.createdAt))),
            PlannedAction(
                action: PortfolioAction(
                    subjectKey: "fund|000001",
                    deltaWeight: Ratio(value: Decimal(string: "0.08")!)),
                provenance: .targetRebalance(.init(
                    targetID: target.id, targetCreatedAt: target.createdAt))),
        ]
        try write(try makeIntradayReport(
            decision: .executeRebalance, target: target, actions: actions))
        let materials = try readyMaterials()
        let snapshot = try service.dashboardSnapshot(userMaterials: materials, now: projDay)
        XCTAssertEqual(snapshot.headline.status, .rebalanceSuggested)
        XCTAssertEqual(snapshot.intraday?.moves.count, 2)
        let decrease = try XCTUnwrap(snapshot.intraday?.moves.first {
            $0.subjectKey == "fund|000002"
        })
        XCTAssertEqual(decrease.direction, .decrease)
        XCTAssertEqual(decrease.weightChange, Decimal(string: "-0.08")!)
        XCTAssertEqual(decrease.provenanceKind, .targetFollow)
        XCTAssertEqual(
            IntelligencePresentationFormatter.provenanceText(decrease.provenanceKind),
            "跟随战略目标")
    }

    func testLegacySelfCopyTargetExcludedFromConclusionsButKeptInHistory() throws {
        // 旧链路自复制 Target（不在用户意图历史中，两类形态）
        let legacyTarget = try StrategicAllocationPolicy().applyUserAllocation(
            entries: [
                AllocationTargetEntry(assetClass: .equity, targetWeight: Ratio(value: Decimal(string: "0.62")!)),
                AllocationTargetEntry(assetClass: .alternative, targetWeight: Ratio(value: Decimal(string: "0.38")!)),
            ],
            note: "维持当前配置（对照检查漂移）", now: projDay)
        try write(try makeIntradayReport(
            decision: .hold, target: legacyTarget,
            holdReasons: ["旧链路产物"]))

        // 用户真实 target（另一 id）
        let materials = try readyMaterials()
        let snapshot = try service.dashboardSnapshot(userMaterials: materials, now: projDay)
        // 有效结论层不出现旧产物
        XCTAssertNil(snapshot.intraday, "target 不可解析的旧报告不进入有效结论")
        XCTAssertEqual(snapshot.headline.status, .undecidable)
        // 历史层保留（审计），并标注 target 不可解析
        let legacyHistory = try XCTUnwrap(
            snapshot.history.first { $0.artifactID.contains("HOLD") })
        XCTAssertFalse(legacyHistory.targetResolvable)
    }

    func testExpiredReportMarkedAndUndecidable() throws {
        let target = try makeCompleteTarget()
        try write(try makeIntradayReport(
            decision: .hold, target: target,
            holdReasons: ["带内"],
            validity: .timeBound(validUntil: projDay.addingTimeInterval(-1))))
        let materials = try readyMaterials()
        let snapshot = try service.dashboardSnapshot(userMaterials: materials, now: projDay)
        XCTAssertEqual(snapshot.intraday?.validity, .expired)
        XCTAssertEqual(snapshot.headline.status, .undecidable)
        XCTAssertTrue(snapshot.headline.reason.contains("已过期"))
        XCTAssertEqual(
            IntelligencePresentationFormatter.intradayValidityLabel(.expired), "已过期")
    }

    // MARK: - 市场发现两态区分

    func testDiscoveryDistinguishesNoCandidatesFromInsufficientData() throws {
        // 有候选
        try repository.writeMarketDiscoveryReport(try makeDiscoveryReport(
            candidates: [candidate(1, name: "沪深300ETF"), candidate(2, name: "中证500ETF")],
            gaps: [gap("g1"), gap("g2")]))
        var snapshot = try service.dashboardSnapshot(
            userMaterials: try readyMaterials(), now: projDay)
        XCTAssertEqual(snapshot.discovery?.state, .hasCandidates)
        XCTAssertEqual(snapshot.discovery?.topCandidates.count, 2)
        XCTAssertEqual(snapshot.discovery?.coverage.covered, 2)
        XCTAssertEqual(snapshot.discovery?.coverage.total, 4)
        XCTAssertTrue(snapshot.discovery?.topCandidates.first?.factorsSummary.contains("动量") ?? false)

        // 全部参与排名但无候选过阈值（0 候选 0 缺口）→ 真无机会
        try repository.writeMarketDiscoveryReport(try makeDiscoveryReport(
            candidates: [], gaps: [],
            producedAt: projDay.addingTimeInterval(60)))
        snapshot = try service.dashboardSnapshot(
            userMaterials: try readyMaterials(), now: projDay)
        XCTAssertEqual(snapshot.discovery?.state, .noCandidates)

        // 覆盖不足 → 数据准备中（不冒充「暂无机会」）
        try repository.writeMarketDiscoveryReport(try makeDiscoveryReport(
            candidates: [], gaps: (0..<10).map { gap("g\($0)") },
            producedAt: projDay.addingTimeInterval(120)))
        snapshot = try service.dashboardSnapshot(
            userMaterials: try readyMaterials(), now: projDay)
        XCTAssertEqual(snapshot.discovery?.state, .insufficientData)
        XCTAssertEqual(
            IntelligencePresentationFormatter.discoveryStateLabel(.insufficientData),
            "市场数据准备中")
    }

    // MARK: - Formatter 稳定性

    func testFormatterPercentAndDeviation() {
        XCTAssertEqual(IntelligencePresentationFormatter.percentText(Decimal(string: "0.62")!), "62%")
        XCTAssertEqual(IntelligencePresentationFormatter.percentText(Decimal(string: "0.075")!), "7.5%")
        XCTAssertEqual(IntelligencePresentationFormatter.percentText(nil), "—")
        XCTAssertEqual(IntelligencePresentationFormatter.deviationText(Decimal(string: "0.07")!), "+7%")
        XCTAssertEqual(IntelligencePresentationFormatter.deviationText(Decimal(string: "-0.07")!), "-7%")
        XCTAssertEqual(IntelligencePresentationFormatter.deviationText(Decimal(string: "0.001")!), "+0.1%")
        XCTAssertEqual(IntelligencePresentationFormatter.deviationText(Decimal(string: "0.0004")!), "0%")
    }

    func testUserFacingErrorFactoriesCoverRecoveryActions() {
        XCTAssertEqual(IntelligenceUserFacingError.providerNotConfigured().recovery, .goToSettings)
        XCTAssertEqual(IntelligenceUserFacingError.targetMissing().recovery, .configureTarget)
        XCTAssertEqual(
            IntelligenceUserFacingError.holdingsUnclassified(["a"]).recovery,
            .classifyHoldings)
        XCTAssertEqual(
            IntelligenceUserFacingError.from(IntelligenceInputError.missingTarget).diagnosticCode,
            "INTL-TARGET-MISSING")
        XCTAssertEqual(
            IntelligenceUserFacingError.from(
                IntelligenceInputError.unclassifiedHoldings(["a"])).title,
            "1 项持仓待归类")
        // 网络 error 映射
        let network = IntelligenceUserFacingError.from(
            NSError(domain: NSURLErrorDomain, code: -1009))
        XCTAssertEqual(network.diagnosticCode, "INTL-NETWORK")
    }
}
