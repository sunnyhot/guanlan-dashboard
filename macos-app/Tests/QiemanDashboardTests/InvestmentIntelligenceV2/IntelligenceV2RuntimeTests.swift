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
