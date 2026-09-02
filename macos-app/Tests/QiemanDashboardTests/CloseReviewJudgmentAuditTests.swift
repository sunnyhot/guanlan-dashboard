import XCTest
@testable import QiemanDashboard

// 2026-09-02 昨日判断验证（收盘复盘对账切片）的行为冻结。
final class CloseReviewJudgmentAuditTests: XCTestCase {

    private func pulse(
        _ name: String,
        _ direction: TrendDirection
    ) -> MarketCloseReviewSnapshot.PulseItem {
        MarketCloseReviewSnapshot.PulseItem(
            id: name,
            name: name,
            category: "index",
            direction: direction,
            confidenceText: "中",
            rationale: "测试判断。"
        )
    }

    private func quote(
        _ name: String,
        _ changePct: Double?
    ) -> MarketIndexQuote {
        MarketIndexQuote(
            kind: .sseComposite,
            name: name,
            price: 3000,
            previousClose: 3000,
            changeAmount: nil,
            changePct: changePct,
            quotedAt: "2026-09-02 15:00:00",
            sourceLabel: "测试"
        )
    }

    func testDirectionVersusTodayChangeOutcomes() {
        let entries = CloseReviewJudgmentAudit.audit(
            pulse: [
                pulse("上证指数", .bullish),       // 今日跌 → 失误
                pulse("创业板指", .bearish),       // 今日跌 → 印证
                pulse("沪深300", .neutralPositive), // 微涨 0.1%（阈值内）→ 无结论
                pulse("恒生指数", .neutral),        // 中性判断 → 无法验证
            ],
            indexQuotes: [
                .sseComposite: quote("上证指数", -1.32),
                .csi300: quote("创业板指", -2.10),
                .chinext: quote("沪深300", 0.10),
                // 恒生指数无行情
            ]
        )

        XCTAssertEqual(entries.map(\.outcome), [.miss, .hit, .inconclusive, .inconclusive])
        XCTAssertTrue(entries[0].verdictText.contains("判断失误"))
        XCTAssertTrue(entries[1].verdictText.contains("印证"))
        XCTAssertTrue(entries[3].verdictText.contains("行情缺失"))
    }

    func testNameMatchingFallsBackToContains() {
        // 模型写「上证指数」、行情源叫「上证综指」这类简称差异由包含匹配兜底。
        let entries = CloseReviewJudgmentAudit.audit(
            pulse: [pulse("上证指数", .bullish)],
            indexQuotes: [.sseComposite: quote("上证", 1.5)]
        )
        XCTAssertEqual(entries.first?.outcome, .hit)
        XCTAssertEqual(entries.first?.changePct, 1.5)
    }

    func testSummaryTextCountsOutcomes() {
        let entries = CloseReviewJudgmentAudit.audit(
            pulse: [
                pulse("上证指数", .bullish),
                pulse("创业板指", .bearish),
                pulse("沪深300", .neutral),
            ],
            indexQuotes: [
                .sseComposite: quote("上证指数", -1.0),
                .csi300: quote("创业板指", -1.0),
            ]
        )
        XCTAssertEqual(
            CloseReviewJudgmentAudit.summaryText(entries),
            "昨日判断验证：1 印证 · 1 失误 · 1 无结论"
        )
        XCTAssertNil(CloseReviewJudgmentAudit.summaryText([]), "空对账不产出摘要")
    }

    func testArchiveDecodingWithoutAuditFieldStaysCompatible() throws {
        // 旧冻结快照没有 yesterdayJudgmentAudit 键——解码必须宽容为 nil。
        let legacyJSON = """
        {"schemaVersion":3,"generatedAt":"2026-08-29 21:36:24",
         "snapshot":{"state":"ready","subtitle":"","eyebrow":"","headline":"h","summary":"s",
         "marketPulse":[],"strongThemes":[],"weakThemes":[],"portfolioReview":null,
         "tomorrowWatch":[],"evidenceText":null,"dataBoundary":""}}
        """
        let archive = try JSONDecoder().decode(
            MarketCloseReviewArchive.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertNil(archive.snapshot.yesterdayJudgmentAudit)

        // 写入后 round-trip 保持。
        var snapshot = archive.snapshot
        snapshot.yesterdayJudgmentAudit = [YesterdayJudgmentAuditEntry(
            name: "上证指数",
            direction: .bullish,
            changePct: -1.0,
            outcome: .miss,
            verdictText: "昨日偏强 · 今日 -1.00% · 判断失误"
        )]
        let reencoded = try JSONEncoder().encode(
            MarketCloseReviewArchive(generatedAt: archive.generatedAt, snapshot: snapshot)
        )
        let decoded = try JSONDecoder().decode(MarketCloseReviewArchive.self, from: reencoded)
        XCTAssertEqual(decoded.snapshot.yesterdayJudgmentAudit?.first?.outcome, .miss)
    }
}
