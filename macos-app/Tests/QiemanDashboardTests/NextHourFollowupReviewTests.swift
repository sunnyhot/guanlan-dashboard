import XCTest
@testable import QiemanDashboard

// MARK: - P5「昨日关注回指」测试
//
// 契约:docs/2026-08-19-p5-followup-review-contract-change.md
// 核心:confirmed 必须挂当日有效证据(缺证据/昨日证据→强制降级 inconclusive);
// 越界/重复丢弃;回指问题不影响主流程;无昨晚复盘时行为与旧版一致。

@MainActor
final class NextHourFollowupReviewTests: XCTestCase {
    // MARK: - 夹具

    private func context(
        watch: [String]? = ["红利能否放量", "成长跌幅是否收敛", "黄金是否快速回落"]
    ) -> NextHourGuidanceContext {
        NextHourGuidanceContext(
            generatedAt: "2026-08-19 14:00:00",
            slot: NextHourGuidanceSlot(
                day: "2026-08-19",
                timeString: "14:00",
                validUntil: "2026-08-19 15:00",
                scope: .marketTrading
            ),
            assets: [],
            market: [],
            marketDataIsFresh: true,
            marketDataWarnings: [],
            latestTrendGeneratedAt: nil,
            latestTrendHeadline: nil,
            latestTrendActions: [],
            latestAssetConclusions: [],
            dataRules: [],
            lastCloseReview: watch.map {
                LastCloseReviewContext(generatedAt: "2026-08-18 21:03:00", tomorrowWatch: $0)
            }
        )
    }

    private func evidence(id: String, publishedAt: String?) -> TrendEvidence {
        TrendEvidence(
            id: id,
            sourceName: "测试源",
            title: "测试证据",
            url: nil,
            publishedAt: publishedAt,
            retrievedAt: "2026-08-19 13:50:00",
            summary: "摘要",
            metadata: .unknown
        )
    }

    /// 经 JSON 构造提交(顺带锁定 snake_case 解码)。
    private func submissions(_ json: String) throws -> [NextHourGuidanceAgent.FollowupReviewSubmission] {
        try JSONDecoder().decode([NextHourGuidanceAgent.FollowupReviewSubmission].self, from: Data(json.utf8))
    }

    // MARK: - 净化规则

    func testNoLastReviewYieldsEmptyResult() {
        let result = NextHourGuidanceAgent.sanitizeFollowupReviews(
            try! submissions(#"[{"item_index":0,"status":"confirmed","note":"x","evidence_ids":["e1"]}]"#),
            context: context(watch: nil),
            evidence: [evidence(id: "e1", publishedAt: nil)],
            currentTimestamp: "2026-08-19 14:00:00"
        )
        XCTAssertTrue(result.reviews.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testConfirmedWithoutEvidenceIsDowngraded() throws {
        let result = NextHourGuidanceAgent.sanitizeFollowupReviews(
            try submissions(#"[{"item_index":0,"status":"confirmed","note":"放量了"}]"#),
            context: context(),
            evidence: [],
            currentTimestamp: "2026-08-19 14:00:00"
        )
        XCTAssertEqual(result.reviews.first?.status, .inconclusive)
        XCTAssertTrue(result.warnings.contains { $0.contains("降级") })
    }

    func testConfirmedWithYesterdayPublishedEvidenceIsDowngraded() throws {
        let result = NextHourGuidanceAgent.sanitizeFollowupReviews(
            try submissions(#"[{"item_index":1,"status":"confirmed","note":"ok","evidence_ids":["e-old"]}]"#),
            context: context(),
            evidence: [evidence(id: "e-old", publishedAt: "2026-08-17 09:00:00")],
            currentTimestamp: "2026-08-19 14:00:00"
        )
        XCTAssertEqual(result.reviews.first?.status, .inconclusive, "昨日发布的外部证据不能证明今日出现")
    }

    func testConfirmedWithTodayOrLocalEvidenceIsKept() throws {
        let json = #"[{"item_index":0,"status":"confirmed","note":"ok","evidence_ids":["e-today","e-local"]}]"#
        let result = NextHourGuidanceAgent.sanitizeFollowupReviews(
            try submissions(json),
            context: context(),
            evidence: [
                evidence(id: "e-today", publishedAt: "2026-08-19 08:00:00"),
                evidence(id: "e-local", publishedAt: nil)  // 本地行情/三方结论,采集即当日
            ],
            currentTimestamp: "2026-08-19 14:00:00"
        )
        XCTAssertEqual(result.reviews.first?.status, .confirmed)
        XCTAssertEqual(result.reviews.first?.itemText, "红利能否放量")
        XCTAssertEqual(result.reviews.first?.evidenceIDs, ["e-today", "e-local"])
    }

    func testOutOfRangeDuplicateAndUnknownStatusAreHandled() throws {
        let json = #"""
        [
          {"item_index":5,"status":"confirmed","note":"越界"},
          {"item_index":0,"status":"confirmed","note":"重复1"},
          {"item_index":0,"status":"not_seen","note":"重复2"},
          {"item_index":2,"status":"weird_status","note":"未知状态"}
        ]
        """#
        let result = NextHourGuidanceAgent.sanitizeFollowupReviews(
            try submissions(json),
            context: context(),
            evidence: [],
            currentTimestamp: "2026-08-19 14:00:00"
        )
        XCTAssertEqual(result.reviews.count, 2, "越界丢弃;重复保留先到;未知状态容错")
        XCTAssertEqual(result.reviews[0].itemIndex, 0)
        XCTAssertEqual(result.reviews[0].status, .inconclusive, "重复的第一条 confirmed 无证据被降级")
        XCTAssertEqual(result.reviews[1].itemIndex, 2)
        XCTAssertEqual(result.reviews[1].status, .inconclusive, "未知状态容错为无法确认")
        XCTAssertFalse(result.warnings.isEmpty)
    }

    // MARK: - 注入窗口

    private func archive(generatedAt: String, watch: [String] = ["关注一"]) -> MarketCloseReviewArchive {
        MarketCloseReviewArchive(
            generatedAt: generatedAt,
            snapshot: MarketCloseReviewSnapshot(
                state: .ready,
                subtitle: "",
                eyebrow: "",
                headline: "标题",
                summary: "",
                marketPulse: [],
                strongThemes: [],
                weakThemes: [],
                portfolioReview: nil,
                tomorrowWatch: watch,
                evidenceText: nil,
                dataBoundary: ""
            )
        )
    }

    func testInjectionWindowAcceptsYesterdayAndWeekendSpanOnly() {
        let model = AppModel()
        let now = "2026-08-19 14:00:00"  // 周三

        model.marketCloseReviewArchive = archive(generatedAt: "2026-08-18 21:03:00")
        XCTAssertEqual(model.makeLastCloseReviewContext(generatedAt: now)?.tomorrowWatch, ["关注一"], "昨天注入")

        model.marketCloseReviewArchive = archive(generatedAt: "2026-08-14 21:03:00")  // 上周五
        XCTAssertNotNil(
            model.makeLastCloseReviewContext(generatedAt: "2026-08-17 14:00:00"),
            "周五复盘在下一交易日(周一)仍可注入"
        )

        model.marketCloseReviewArchive = archive(generatedAt: "2026-08-13 21:03:00")  // 四天前,节假日跨度
        XCTAssertNil(model.makeLastCloseReviewContext(generatedAt: now), "陈旧复盘不注入")

        model.marketCloseReviewArchive = archive(generatedAt: "2026-08-19 21:03:00")
        XCTAssertNil(
            model.makeLastCloseReviewContext(generatedAt: now),
            "当日(今晚)复盘的明日关注是给明天的,不注入"
        )

        model.marketCloseReviewArchive = archive(generatedAt: "2026-08-18 21:03:00", watch: ["  ", ""])
        XCTAssertNil(model.makeLastCloseReviewContext(generatedAt: now), "空关注不注入")

        model.marketCloseReviewArchive = nil
        XCTAssertNil(model.makeLastCloseReviewContext(generatedAt: now))
    }

    // MARK: - 旧存档兼容

    func testOldReportJSONWithoutFollowupReviewsDecodesAsEmpty() throws {
        let report = NextHourGuidanceReport(
            generatedAt: "2026-08-18 14:50:00",
            validUntil: "2026-08-18 15:00",
            slotKey: "2026-08-18 14:50",
            scope: .closingWindow,
            headline: "收盘前以复核为主",
            posture: .balanced,
            summary: "场外基金只在此窗口参与。",
            actions: [],
            riskChecks: ["确认估值时间"],
            assetCount: 1
        )
        var object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(report)
        ) as! [String: Any]
        object.removeValue(forKey: "followupReviews")  // 模拟旧版本存档
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(NextHourGuidanceReport.self, from: legacyData)
        XCTAssertEqual(decoded.followupReviews, [])
    }
}
