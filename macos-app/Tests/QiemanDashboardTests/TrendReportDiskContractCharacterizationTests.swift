import Foundation
import XCTest
@testable import QiemanDashboard

// 趋势报告磁盘契约冻结测试。
//
// 冻结 TrendAnalysisReportStore 的当前行为(见 docs/ai-pipeline-baseline.md 第 5 节):
//   - 单文件覆盖写,无历史目录
//   - 文件权限不收紧(默认,非 0o600)——这是一个已知不一致,改造时收紧需主动更新本测试
//   - 旧 schemaVersion=1 报告能被解码(向后兼容)
//   - 当前 schema 往返一致
final class TrendReportDiskContractCharacterizationTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trend-disk-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    private func fileURL(_ name: String) -> URL {
        tempDir.appendingPathComponent(name, isDirectory: false)
    }

    // MARK: - 测试 9:单文件覆盖写,无历史

    func testReportStoreOverwritesSingleFileWithoutHistory() throws {
        let url = fileURL("trend-analysis-report.json")
        let store = TrendAnalysisReportStore()

        let report1 = TrendAnalysisReport.fixture(
            generatedAt: "2026-07-24 10:00:00", externalSignalStatus: .unavailable
        )
        let report2 = TrendAnalysisReport.fixture(
            generatedAt: "2026-07-25 10:00:00", externalSignalStatus: .available
        )

        try store.save(report1, to: url)
        try store.save(report2, to: url)

        // 目录下应只有 1 个文件(覆盖写,不保留历史)
        let files = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1, "ReportStore 必须单文件覆盖写,不保留历史副本")

        let loaded = try store.load(from: url)
        XCTAssertEqual(loaded?.generatedAt, "2026-07-25 10:00:00", "应只保留最后一次写入的报告")
    }

    // MARK: - 测试 10:文件权限不收紧(冻结当前不一致现状)

    func testReportStoreDoesNotRestrictFilePermissions() throws {
        // 这个测试显式记录:trend-analysis-report.json 当前没有 0o600 权限收紧,
        // 而 trend-analysis-settings.json 有。这是已知不一致。
        // 投资智能改造若收紧权限,需同步更新本测试。
        let url = fileURL("trend-analysis-report.json")
        let store = TrendAnalysisReportStore()
        let report = TrendAnalysisReport.fixture(
            generatedAt: "2026-07-24 10:00:00", externalSignalStatus: .unavailable
        )

        try store.save(report, to: url)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attrs[.posixPermissions] as? NSNumber
        XCTAssertNotNil(permissions, "应能读取文件权限")
        // 0o600 = 384。当前 ReportStore 不收紧,权限应不等于 0o600。
        // (默认权限由 umask 决定,通常是 0o644 = 420)
        XCTAssertNotEqual(permissions?.int16Value, 0o600,
                          "当前 ReportStore 不收紧权限;若此断言失败说明已收紧,需更新本测试注释")
    }

    // MARK: - 测试 11:旧 v1 报告解码向后兼容

    func testLegacyV1ReportDecodesWithDefaults() throws {
        // 最小 v1 报告:缺 schemaVersion(默认 1)、缺新增集合字段(默认空数组)
        let legacyJSON = """
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "generatedAt": "2025-01-01 09:00:00",
          "dataAsOf": "2025-01-01 09:00:00",
          "disposition": "analysisOnly",
          "privacyMode": "脱敏摘要",
          "externalSignalStatus": "unavailable",
          "portfolio": {
            "headline": "旧报告",
            "riskLevel": "unknown",
            "summary": "历史遗留报告。"
          },
          "horizons": [
            {"horizon": "short", "direction": "neutral", "confidence": {"score": 50, "label": "中"},
             "rationale": "短期", "counterSignals": ["反证"]}
          ],
          "sectors": [],
          "keyAssets": [],
          "assetTrends": [],
          "actions": [],
          "evidence": [],
          "warnings": [],
          "disclaimer": "本内容非投资建议，仅供参考。"
        }
        """
        let report = try JSONDecoder().decode(TrendAnalysisReport.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(report.schemaVersion, 1, "无 schemaVersion 字段时应默认为 1")
        XCTAssertTrue(report.marketOutlook.isEmpty, "缺 marketOutlook 应默认空数组")
        XCTAssertTrue(report.opportunities.isEmpty, "缺 opportunities 应默认空数组")
        XCTAssertTrue(report.sourceStatuses.isEmpty, "缺 sourceStatuses 应默认空数组")
        XCTAssertEqual(report.id, UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
    }

    // MARK: - 测试 12:当前 schema 往返一致

    func testReportRoundTripsThroughCurrentSchema() throws {
        let original = TrendAnalysisReport.fixture(
            generatedAt: "2026-07-24 10:00:00", externalSignalStatus: .partial
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(TrendAnalysisReport.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.generatedAt, original.generatedAt)
        XCTAssertEqual(decoded.disposition, original.disposition)
        XCTAssertEqual(decoded.privacyMode, original.privacyMode)
        XCTAssertEqual(decoded.externalSignalStatus, original.externalSignalStatus)
        XCTAssertEqual(decoded.horizons.count, original.horizons.count)
        XCTAssertEqual(decoded.evidence.count, original.evidence.count)
        XCTAssertEqual(decoded.disclaimer, original.disclaimer)
    }
}
