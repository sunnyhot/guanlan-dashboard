import XCTest
@testable import QiemanDashboard

final class EastmoneyHistoricalHoldingProviderTests: XCTestCase {

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.startOfDay(
            for: calendar.date(from: DateComponents(year: year, month: month, day: day))!
        )
    }

    func testHistoricalAdapterUsesAnnouncementAPIAndTargetQuarterArchive() async throws {
        let reportDate = date(2024, 6, 30)
        let archive = """
        var apidata={ content:"<h4>易方达消费行业股票 2024年2季度股票投资明细 截止至：<font class='px12'>2024-06-30</font></h4><table><tbody><tr><td>1</td><td>600519</td><td>贵州茅台</td><td>行情</td><td>8.71%</td><td>119.19</td></tr></tbody></table>"};
        """
        let announcements = #"{"ErrCode":0,"Data":[{"TITLE":"易方达消费行业股票型证券投资基金2024年第2季度报告","PUBLISHDATEDesc":"2024-07-18","ID":"AN202407181638017119"}]}"#
        let fetcher = StaticResponseFetcher([
            .eastmoneyHoldingArchive(
                fundCode: "110022",
                kind: .stocks,
                reportDate: "2024-06-30"
            ): archive,
            .eastmoneyHoldingArchive(
                fundCode: "110022",
                kind: .bonds,
                reportDate: "2024-06-30"
            ): archive,
            .eastmoneyFundAnnouncements(fundCode: "110022", reportType: 3): announcements
        ])
        let adapter = EastmoneyHistoricalHoldingProviderAdapter(
            fetcher: fetcher,
            reportDate: reportDate,
            ingestedAt: { self.date(2024, 7, 22) }
        )

        let records = try await adapter.fetch(
            code: ProviderCode(scheme: "fund_code", value: "110022"),
            from: reportDate,
            to: reportDate
        )
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.effectiveAt, reportDate)
        XCTAssertEqual(record.publishedAt, date(2024, 7, 18))
        XCTAssertEqual(record.ingestedAt, date(2024, 7, 22))

        let payload = try JSONDecoder().decode(FundHoldingPayload.self, from: record.rawPayload)
        XCTAssertEqual(payload.positions.count, 2, "stock and bond archive rows use the same parser contract")
        XCTAssertEqual(payload.positions.first?.providerCode.value, "600519")
        XCTAssertEqual(payload.positions.first?.weight.value, Decimal(string: "0.0871"))
    }

    func testAnnouncementParserRejectsMalformedResponse() {
        XCTAssertThrowsError(try EastmoneyFundAnnouncementParser().parse("not-json"))
    }
}
