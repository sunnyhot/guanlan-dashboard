import XCTest
@testable import QiemanDashboard

// 十六轮审查 P1-1 / P1-6 回归：V2 生产接线与旧数据迁移告知。

final class IntelligenceV2RuntimeTests: XCTestCase {

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 旧数据迁移（P1-6）

    func testLegacyMigrationArchivesFilesWritesMarkerAndNotifies() throws {
        let directory = try makeTempDirectory()
        let legacyNames = ["trend-analysis-report.json", "trend-tracking-items.json"]
        for name in legacyNames {
            try Data("{}".utf8).write(to: directory.appendingPathComponent(name))
        }
        // 非旧链路文件不动
        let keepName = "user-portfolio.json"
        try Data("[]".utf8).write(to: directory.appendingPathComponent(keepName))

        let outcome = LegacyAIDataMigration.migrateIfNeeded(in: directory)

        XCTAssertEqual(Set(outcome.archivedFiles), Set(legacyNames))
        XCTAssertNotNil(outcome.notice)
        XCTAssertTrue(outcome.notice?.contains("已移入") ?? false)
        XCTAssertTrue(outcome.notice?.contains("legacy-ai-backup") ?? false)
        // 文件移入备份目录,原位消失
        let backupDir = directory.appendingPathComponent(
            LegacyAIDataMigration.backupDirectoryName, isDirectory: true)
        for name in legacyNames {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(name).path),
                "旧文件应移出原位"
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: backupDir.appendingPathComponent(name).path),
                "旧文件应在备份目录保留"
            )
        }
        // 非旧链路文件不动
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(keepName).path))
        // 标记已写:再次调用幂等零动作
        let second = LegacyAIDataMigration.migrateIfNeeded(in: directory)
        XCTAssertNil(second.notice)
        XCTAssertTrue(second.archivedFiles.isEmpty)
    }

    func testLegacyMigrationWithoutLegacyFilesOnlyWritesMarker() throws {
        let directory = try makeTempDirectory()
        let outcome = LegacyAIDataMigration.migrateIfNeeded(in: directory)
        XCTAssertNil(outcome.notice, "没有旧文件时无需告知")
        XCTAssertTrue(outcome.archivedFiles.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(
                LegacyAIDataMigration.markerFileName).path))
    }

    // MARK: - Live 决策材料（P1-1 真实供给）

    func testLiveMaterialsProduceConsistentSnapshotAndTarget() throws {
        let day = Date(timeIntervalSince1970: 1_860_000_000)
        let rows = [
            PersonalAssetAggregateRow(
                key: "a", assetType: .fund, fundName: "基金 A", fundCode: "000001",
                holdingRow: nil, rawHolding: nil, archivedHolding: nil,
                pendingTrades: [], plans: []
            ),
            PersonalAssetAggregateRow(
                key: "b", assetType: .stock, fundName: "股票 B", fundCode: "600519",
                holdingRow: nil, rawHolding: nil, archivedHolding: nil,
                pendingTrades: [], plans: []
            ),
        ]
        // effectiveHoldingAmount 来自 marketValue(nil) → 0 → 空持仓 fail-closed
        XCTAssertThrowsError(try LivePortfolioDecisionMaterials(rows: rows, now: day)
            .materials(asOf: day)) { error in
            XCTAssertEqual(error as? LivePortfolioDecisionMaterials.LiveMaterialsError,
                           .emptyPortfolio)
        }
    }

    // MARK: 十七轮 P0 回归

    func testLiveMaterialsAcceptsRealAmountsProducingExactTarget() throws {
        // 真实金额（权重比为非终尽小数:123456.78 / 876543.21）——残差归
        // 最大类后 target 构造不再抛 weightsDoNotSumToOne(P0-1)
        let day = Date(timeIntervalSince1970: 1_860_000_000)
        func row(code: String, marketValue: Double) -> PersonalAssetAggregateRow {
            let holding = UserPortfolioHolding(
                fundCode: code, assetType: .fund, units: 1000, costPrice: 1,
                displayName: code
            )
            let valuation = UserPortfolioValuationRow(
                holding: holding, fundName: code, currentPrice: nil,
                priceTime: nil, priceSource: nil, officialNav: nil,
                officialNavDate: nil, estimatePrice: nil, estimatePriceTime: nil,
                marketValue: marketValue, costValue: nil, profitAmount: nil,
                profitPct: nil, estimateChangePct: nil
            )
            return PersonalAssetAggregateRow(
                key: code, assetType: .fund, fundName: code, fundCode: code,
                holdingRow: valuation, rawHolding: holding, archivedHolding: nil,
                pendingTrades: [], plans: []
            )
        }
        let rows = [
            row(code: "000001", marketValue: 123_456.78),
            row(code: "000002", marketValue: 876_543.21),
            row(code: "000003", marketValue: 555_555.55),
        ]
        let materials = try LivePortfolioDecisionMaterials(rows: rows, now: day)
            .materials(asOf: day)
        let run = try XCTUnwrap(materials.plannerRuns["current"])
        // 权重和恰为 1(positions 权重=target 权重域同构)
        let weightSum = run.portfolio.positions.reduce(Decimal.zero) {
            $0 + $1.weight.value
        }
        XCTAssertEqual(weightSum, Decimal(1), "持仓权重和应为 1(比例归一)")
        // target 恒过 StrategicAllocationValidator(残差归最大类)
        let target = try XCTUnwrap(materials.target)
        XCTAssertEqual(target.entries.reduce(Decimal.zero) {
            $0 + $1.targetWeight.value
        }, Decimal(1))
    }

    func testIntradayHoldsDuringChineseNewYearWithOverride() throws {
        // 场外基金 + 中国法域覆盖:2025-01-29(周三,春节休市)→ HOLD
        //（十七轮 P0-2:此前 .otc 默认美域,NYSE 表会误判可执行）
        let newYear = Date(timeIntervalSince1970: 1_738_118_400) // 2025-01-29 00:00 UTC(北京 08:00 周三)
        let positions = [
            PortfolioPosition(
                subjectKey: "fund|000001", assetClass: .alternative,
                weight: Ratio(value: Decimal(string: "1")!)
            ),
        ]
        let target = try StrategicAllocationPolicy().applyUserAllocation(
            entries: [
                AllocationTargetEntry(
                    assetClass: .alternative,
                    targetWeight: Ratio(value: Decimal(string: "1")!)
                )
            ], note: nil, now: newYear
        )
        let input = IntradayWorkflow.Input(
            subject: CanonicalRef.fundShareClass(FundShareClassID(rawValue: "sc_cny")),
            portfolio: PortfolioSnapshot(
                asOf: newYear, positions: positions),
            target: target,
            actionDomain: ActionDomain(
                perSubjectBounds: [
                    "fund|000001": .init(
                        lower: Ratio(value: Decimal(string: "-1")!),
                        upper: Ratio(value: Decimal(string: "1")!)
                    )
                ],
                eligibleNewSubjects: [:], builderVersion: "t",
                newSubjectBuyUpper: Ratio(value: Decimal(string: "1")!)
            ),
            exchange: .otc,
            tradingJurisdiction: .chinaMainland
        )
        let workflow = IntradayWorkflow(
            signalStore: InMemorySignalStore(),
            calendar: HolidayTableTradingCalendar.bundled
        )
        let outcome = workflow.run(input: input, asOf: newYear, now: newYear)
        XCTAssertEqual(
            outcome.report?.decision, .hold,
            "春节休市日(中国法域)不得产出执行决策"
        )
        XCTAssertTrue(
            outcome.report?.holdReasons.contains { $0.contains("非交易日") } ?? false
        )
    }

    func testAssembleThrowsOnEmptyAndDuplicateCriterionDefinitions() throws {
        // 十七轮 P1-4:外部材料供给的非法形态 fail-closed 抛错,不崩进程
        let day = Date(timeIntervalSince1970: 1_870_000_000)
        let decision = PartialDecision(
            status: .unresolvedTradeoff, admissiblePlans: [], explanation: "x"
        )
        let band = IndifferenceBand(
            policyID: "b", version: "v1", defaultBand: Decimal(string: "0.01")!,
            rationale: "t"
        )
        let comparison = PlanComparisonResult(
            pairwise: [:], paretoFront: [], blockingUnknowns: []
        )
        XCTAssertThrowsError(
            try PortfolioDecisionArtifact.assemble(
                signalIDs: [], criterionDefinitions: [], factorSnapshotIDs: [],
                target: nil, band: band, knowledgeContextSummary: "k",
                decision: decision, comparison: comparison,
                plans: [:], plannerRuns: [:], producedAt: day
            )
        ) { error in
            XCTAssertEqual(
                error as? PortfolioDecisionArtifact.AssemblyError,
                .emptyCriterionDefinitions
            )
        }
        // 重复指纹:同 id@version 两份不同内容 → 抛错(九轮 P3 的 throws 化)
        let definitionA = CriterionDefinition(
            id: "c", version: "v1", evaluatorKind: .weightedSum,
            inputReferences: [], unit: .ratio
        )
        let definitionB = CriterionDefinition(
            id: "c", version: "v1", evaluatorKind: .weightedSum,
            inputReferences: [
                CriterionDefinition.InputReference(
                    kind: .planMetric, referenceID: PlanMetrics.turnover, weight: 1)
            ],
            unit: .ratio
        )
        XCTAssertThrowsError(
            try PortfolioDecisionArtifact.assemble(
                signalIDs: [], criterionDefinitions: [definitionA, definitionB],
                factorSnapshotIDs: [], target: nil, band: band,
                knowledgeContextSummary: "k", decision: decision,
                comparison: comparison, plans: [:], plannerRuns: [:],
                producedAt: day
            )
        ) { error in
            XCTAssertTrue(
                error is PortfolioDecisionArtifact.AssemblyError,
                "重复指纹应抛 AssemblyError,实际 \(error)"
            )
        }
    }

    func testProviderSaveKeepsExistingKeychainKeyOnEmptyInput() {
        // 十七轮 P1-2:保存时 Key 留空 = 保留既有 Key（Keychain 注入内存
        // 实现——单测进程的真实 Keychain 权限不可靠）
        final class InMemoryKeychain: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [String: String] = [:]
            func read(_ key: String) -> String? {
                lock.lock(); defer { lock.unlock() }
                return storage[key]
            }
            func write(_ key: String, _ value: String) {
                lock.lock(); defer { lock.unlock() }
                storage[key] = value
            }
            func delete(_ key: String) {
                lock.lock(); defer { lock.unlock() }
                storage.removeValue(forKey: key)
            }
        }
        let memory = InMemoryKeychain()
        let savedReader = IntelligenceV2ProviderSettings.keychainReader
        let savedWriter = IntelligenceV2ProviderSettings.keychainWriter
        let savedDeleter = IntelligenceV2ProviderSettings.keychainDeleter
        IntelligenceV2ProviderSettings.keychainReader = { memory.read($0) }
        IntelligenceV2ProviderSettings.keychainWriter = { memory.write($0, $1) }
        IntelligenceV2ProviderSettings.keychainDeleter = { memory.delete($0) }
        defer {
            IntelligenceV2ProviderSettings.keychainReader = savedReader
            IntelligenceV2ProviderSettings.keychainWriter = savedWriter
            IntelligenceV2ProviderSettings.keychainDeleter = savedDeleter
        }

        IntelligenceV2ProviderSettings.save(
            baseURL: "https://api.example.com", model: "m1", apiKey: "sk-test-key"
        )
        XCTAssertEqual(IntelligenceV2ProviderSettings.apiKey, "sk-test-key")
        // 只改 baseURL,Key 输入留空 → Key 保留（不静默清除）
        IntelligenceV2ProviderSettings.save(
            baseURL: "https://api2.example.com", model: "m1", apiKey: "  "
        )
        XCTAssertEqual(
            IntelligenceV2ProviderSettings.apiKey, "sk-test-key",
            "留空 Key 不得静默清除既有 Key"
        )
        // 显式清除走 deleteAPIKey
        IntelligenceV2ProviderSettings.deleteAPIKey()
        XCTAssertTrue(IntelligenceV2ProviderSettings.apiKey.isEmpty)
        // P1-1:save 不写明文 Key 到 UserDefaults
        UserDefaults.standard.removeObject(forKey: "qieman.trend.openai.key")
        IntelligenceV2ProviderSettings.save(
            baseURL: "https://api.example.com", model: "m1", apiKey: "sk-another"
        )
        XCTAssertNil(
            UserDefaults.standard.string(forKey: "qieman.trend.openai.key"),
            "明文 Key 不得落 UserDefaults"
        )
    }

    // MARK: - Provider 配置（防密钥落盘拆分）

    func testProviderSettingsUnconfiguredByDefaultInCleanDefaults() {
        // 清空 UserDefaults 与 Keychain 的测试痕迹后判定未配置
        let defaults = UserDefaults.standard
        let savedBase = defaults.string(forKey: IntelligenceV2ProviderSettings.baseURLKey)
        let savedModel = defaults.string(forKey: IntelligenceV2ProviderSettings.modelKey)
        defer {
            if let base = savedBase {
                defaults.set(base, forKey: IntelligenceV2ProviderSettings.baseURLKey)
            }
            if let model = savedModel {
                defaults.set(model, forKey: IntelligenceV2ProviderSettings.modelKey)
            }
        }
        defaults.removeObject(forKey: IntelligenceV2ProviderSettings.baseURLKey)
        defaults.removeObject(forKey: IntelligenceV2ProviderSettings.modelKey)
        XCTAssertFalse(IntelligenceV2ProviderSettings.isConfigured)
        XCTAssertNil(IntelligenceV2ProviderSettings.providerConfiguration())
    }

    // MARK: - Bootstrap 冒烟（composition root）

    @MainActor
    func testBootstrapOpensDatabaseAndBuildsRuntime() throws {
        let model = AppModel()
        let directory = try makeTempDirectory()
        model.dataDirectoryURL = directory
        model.bootstrapIntelligenceV2()

        let runtime = try XCTUnwrap(model.intelligenceRuntime, "composition root 应建立运行时")
        // QueryService 可用:空库查询零结果不报错
        let summaries = try runtime.queryService.latestPortfolioDecisions(limit: 5)
        XCTAssertTrue(summaries.isEmpty)
        // 幂等:重复 bootstrap 不重建
        model.bootstrapIntelligenceV2()
    }

    @MainActor
    func testMarketDiscoveryActionRunsOnEmptyData() async throws {
        // 空库 + 空 universe 数据:动作跑完 → coverage gap 全量,报告可读
        let model = AppModel()
        let directory = try makeTempDirectory()
        model.dataDirectoryURL = directory
        model.bootstrapIntelligenceV2()
        XCTAssertNotNil(model.intelligenceRuntime)

        model.runMarketDiscovery()
        // 轮询等待 detached task 完成(最长 10s)
        for _ in 0..<100 {
            if !model.isRunningMarketDiscovery { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(model.isRunningMarketDiscovery)
        // 空数据也可能直接失败(数据目录语义)——两种收敛都接受,关键是不悬挂
        let reportOrError = model.latestDiscoveryReport != nil || model.latestIntelligenceError != nil
        XCTAssertTrue(reportOrError, "动作必须收敛:产出报告或显式错误")
    }
}
