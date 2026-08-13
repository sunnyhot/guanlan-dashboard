import XCTest
@testable import QiemanDashboard

/// REPO-7 持仓链路测试：现有 FundLookThroughClient 的 typed disclosure →
/// FundHoldingPayload → ProviderRecord → staging/schema。
final class EastmoneyHoldingProviderTests: XCTestCase {

    private struct StubHoldingClient: FundLookThroughClientProtocol {
        let disclosures: [String: FundLookThroughDisclosure]

        func fetchDisclosures(fundCodes: [String]) async -> FundLookThroughBatchResult {
            FundLookThroughBatchResult(disclosures: disclosures, warnings: [])
        }
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.startOfDay(
            for: calendar.date(from: DateComponents(year: year, month: month, day: day))!
        )
    }

    private func disclosure(
        code: String = "110022",
        asOf: String = "2024-06-30",
        holdings: [FundUnderlyingHolding] = [
            FundUnderlyingHolding(
                code: "600519", name: "贵州茅台", kind: .stock,
                weightPct: 8.0, disclosureDate: "2024-06-30"
            ),
            FundUnderlyingHolding(
                code: "019827", name: "26国债01", kind: .bond,
                weightPct: 7.05, disclosureDate: "2024-06-30"
            )
        ]
    ) -> FundLookThroughDisclosure {
        FundLookThroughDisclosure(
            fundCode: code,
            fundName: "易方达消费行业股票",
            asOf: asOf,
            holdings: holdings,
            industries: [],
            assetAllocation: nil,
            sourceLabel: "天天基金 · 基金定期报告",
            sourceURL: "https://fundf10.eastmoney.com/ccmx_(code).html",
            warnings: []
        )
    }

    func testBuilder_convertsTypedDisclosureToHoldingRecord() throws {
        let record = try XCTUnwrap(
            EastmoneyHoldingRecordBuilder.makeRecord(
                from: disclosure(),
                reliabilityClass: .communityAggregated,
                jurisdiction: .chinaMainland,
                ingestedAt: date(2024, 8, 1)
            )
        )

        XCTAssertEqual(record.providerID, .eastmoney)
        XCTAssertEqual(record.providerCode, ProviderCode(scheme: "fund_code", value: "110022"))
        XCTAssertEqual(record.kind, .fundHoldingSnapshot)
        XCTAssertEqual(record.effectiveAt, date(2024, 6, 30))
        XCTAssertEqual(record.publishedAt, date(2024, 6, 30))
        XCTAssertEqual(record.ingestedAt, date(2024, 8, 1))

        let payload = try JSONDecoder().decode(FundHoldingPayload.self, from: record.rawPayload)
        XCTAssertEqual(payload.reportPeriod, .q2)
        XCTAssertEqual(payload.positions.count, 2)
        XCTAssertEqual(payload.disclosedWeightTotal.value, Decimal(string: "0.1505"))
        XCTAssertEqual(payload.positions[0].providerCode, ProviderCode(scheme: "stock_symbol", value: "600519"))
        XCTAssertEqual(payload.positions[1].providerCode, ProviderCode(scheme: "bond_symbol", value: "019827"))
        XCTAssertEqual(payload.positions[0].weight.value, Decimal(string: "0.08"))
        XCTAssertEqual(payload.positions[1].weight.value, Decimal(string: "0.0705"))
        XCTAssertNil(payload.positions[0].shares)
        XCTAssertNil(payload.positions[0].marketValue)
        XCTAssertTrue(payload.positions.allSatisfy(\.isDisclosed))
    }

    func testBuilder_rejectsDisclosureWithoutReportDate() {
        XCTAssertNil(
            EastmoneyHoldingRecordBuilder.makeRecord(
                from: disclosure(asOf: "not-a-date", holdings: []),
                reliabilityClass: .communityAggregated,
                jurisdiction: .chinaMainland,
                ingestedAt: date(2024, 8, 1)
            )
        )
    }

    func testAdapter_fetchesNAVAndHoldingsAndWritesBothToStaging() async throws {
        let bundle = Bundle.module
        let pingzhongBody = try String(
            contentsOf: bundle.url(
                forResource: "v2-eastmoney-pingzhongdata-110022",
                withExtension: "json.txt",
                subdirectory: "Fixtures"
            )!,
            encoding: .utf8
        )
        let lsjzBody = try String(
            contentsOf: bundle.url(
                forResource: "v2-eastmoney-lsjz-110022",
                withExtension: "json",
                subdirectory: "Fixtures"
            )!,
            encoding: .utf8
        )
        let adapter = EastmoneyProviderAdapter(
            fetcher: StaticResponseFetcher([
                .pingzhongdata(fundCode: "110022"): pingzhongBody,
                .lsjz(fundCode: "110022"): lsjzBody
            ]),
            holdingClient: StubHoldingClient(disclosures: ["110022": disclosure()]),
            ingestedAt: { self.date(2024, 8, 1) }
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eastmoney-v2-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await adapter.fetchAndStage(
            code: ProviderCode(scheme: "fund_code", value: "110022"),
            from: date(2024, 6, 1),
            to: date(2024, 8, 31),
            to: url
        )
        XCTAssertEqual(result.records.filter { $0.kind == .navObservation }.count, 3)
        let holdingRecords = result.records.filter { $0.kind == .fundHoldingSnapshot }
        XCTAssertEqual(holdingRecords.count, 1)

        let holdingPayload = try JSONDecoder().decode(
            FundHoldingPayload.self,
            from: try XCTUnwrap(holdingRecords.first).rawPayload
        )
        XCTAssertEqual(holdingPayload.positions.count, 2)

        let staged = try ProviderStagingReader().read(from: url)
        XCTAssertEqual(staged, result.records)
        XCTAssertEqual(ProviderRecordSchemaValidator().partition(staged).invalid.count, 0)
    }
}
