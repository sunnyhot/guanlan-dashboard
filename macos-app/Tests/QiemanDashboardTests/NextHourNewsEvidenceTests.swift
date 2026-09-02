import XCTest
@testable import QiemanDashboard

/// 2026-09-02:本地财经热榜(NewsNow)注入盘中链路,取代已下线联网搜索的新闻面。
/// 锚定三件事:组装器行为(稳定 ID/实体匹配/分层)、热榜证据可通过买卖门禁的
/// 外部事件校验、与标的无关的热榜条目不解锁买卖。
final class NextHourNewsEvidenceTests: XCTestCase {
    private func feedItem(_ title: String, sourceID: String = "cls-hot") -> NewsFeedItem {
        NewsFeedItem(
            itemID: "rank-\(title.hashValue)",
            title: title,
            url: "https://example.com/\(abs(title.hashValue % 1000))",
            sourceID: sourceID,
            sourceName: sourceID == "cls-hot" ? "财联社热榜" : "雪球热门股票"
        )
    }

    // MARK: - 组装器

    func testAssemblerBuildsStableIDsAndEntityMatching() {
        let feeds: [(sourceID: String, items: [NewsFeedItem])] = [
            ("cls-hot", [
                feedItem("中际旭创中标海外大单，光模块板块走高"),
                feedItem("央行开展1000亿元逆回购操作"),
            ]),
            ("xueqiu-hotstock", [
                feedItem("中际旭创"),
            ]),
        ]
        let assetNames = ["中际旭创", "易方达科技创新混合A"]

        let items = NextHourGuidanceNewsAssembler.items(feeds: feeds, assetNames: assetNames)

        XCTAssertEqual(items.count, 3, "去重后保留全部不同标题")
        // 稳定 ID：同输入两次组装结果一致（当日跨请求可复现）
        let again = NextHourGuidanceNewsAssembler.items(feeds: feeds, assetNames: assetNames)
        XCTAssertEqual(items.map(\.evidenceID), again.map(\.evidenceID))

        XCTAssertTrue(items[0].evidenceID.hasPrefix("news:newsnow:cls-hot:"), "实际：\(items[0].evidenceID)")
        XCTAssertEqual(items[0].entityNames, ["中际旭创"], "标题含标的名 → 关联")
        XCTAssertEqual(items[1].entityNames, [], "宏观条目与标的无关 → 不关联")
        XCTAssertEqual(NextHourGuidanceNewsAssembler.tier(forSourceID: "cls-hot"), .authoritative)
        XCTAssertEqual(NextHourGuidanceNewsAssembler.tier(forSourceID: "xueqiu-hotstock"), .secondary)
    }

    func testAssemblerCapsTotalItems() {
        let many = (1...60).map { feedItem("热榜条目\($0)号，板块异动") }
        let items = NextHourGuidanceNewsAssembler.items(
            feeds: [("cls-hot", many)],
            assetNames: []
        )
        XCTAssertEqual(items.count, NextHourGuidanceNewsAssembler.maxItems, "上下文规模有上限")
    }

    // MARK: - 买卖门禁

    private func makeFreshAssessment() -> TrendQuoteAssessment {
        TrendQuoteAssessment(
            quoteType: .lastTrade, freshnessStatus: .fresh,
            asOf: "2026-09-02 14:30:00", receivedAt: "2026-09-02 14:30:00",
            ageSeconds: 10, marketSession: .trading
        )
    }

    private func newsEvidence(
        id: String,
        publisher: String,
        tier: TrendEvidenceSourceTier,
        entityNames: [String]
    ) -> TrendEvidence {
        TrendEvidence(
            id: id,
            sourceName: "\(publisher)（NewsNow 热榜）",
            title: "热榜条目",
            url: nil,
            publishedAt: nil,
            retrievedAt: "2026-09-02 14:30:00",
            summary: "热榜条目",
            metadata: TrendEvidenceMetadata(
                sourceKind: .webSearch,
                sourceTier: tier,
                publisherKey: publisher,
                requestedTopicKeys: ["财经热榜"],
                entityNames: entityNames,
                metadataConfidence: .deterministic
            )
        )
    }

    private func localFact(targetName: String) -> TrendEvidence {
        TrendEvidence(
            id: "local:next-hour:asset:stock-1",
            sourceName: "本地持仓行情",
            title: "\(targetName) 行情与持仓快照",
            url: nil,
            publishedAt: nil,
            retrievedAt: "2026-09-02 14:30:00",
            summary: "快照",
            metadata: TrendEvidenceMetadata(
                sourceKind: .portfolioSnapshot,
                sourceTier: .primary,
                entityNames: [targetName],
                metadataConfidence: .deterministic
            )
        )
    }

    func testBuyPassesExternalGateWithIndependentAssociatedNews() {
        let policy = TrendClaimEvidencePolicy()
        let local = localFact(targetName: "中际旭创")
        let newsA = newsEvidence(id: "news:newsnow:cls-hot:aaa", publisher: "cls-hot", tier: .authoritative, entityNames: ["中际旭创"])
        let newsB = newsEvidence(id: "news:newsnow:wallstreetcn-quick:bbb", publisher: "wallstreetcn-quick", tier: .authoritative, entityNames: ["中际旭创"])
        let evidenceByID = [local.id: local, newsA.id: newsA, newsB.id: newsB]

        let errors = policy.validateExecution(
            actionKind: .buy,
            targetName: "中际旭创",
            targetCode: nil,
            instruction: "小仓分批买入，不超过一成",
            trigger: "站稳分时均线",
            invalidation: "跌破昨日低点",
            quoteAssessment: makeFreshAssessment(),
            marketDataIsFresh: true,
            evidenceIDs: [local.id, newsA.id, newsB.id],
            evidenceByID: evidenceByID,
            relatedEntityCodes: [],
            relatedEntityNames: [],
            relatedSectorKeys: [],
            requiresFundDisclosure: false,
            fundDisclosureEvidencePrefix: nil
        )
        XCTAssertTrue(errors.isEmpty, "本地行情+两条独立关联热榜证据应通过买卖门禁，实际：\(errors)")
    }

    func testBuyRejectedWhenNewsNotAssociatedWithTarget() {
        let policy = TrendClaimEvidencePolicy()
        let local = localFact(targetName: "中际旭创")
        // 两条热榜都是宏观条目（entityNames 空）——数量与独立性够，但不关联标的
        let newsA = newsEvidence(id: "news:newsnow:cls-hot:aaa", publisher: "cls-hot", tier: .authoritative, entityNames: [])
        let newsB = newsEvidence(id: "news:newsnow:xueqiu-hotstock:bbb", publisher: "xueqiu-hotstock", tier: .secondary, entityNames: [])
        let evidenceByID = [local.id: local, newsA.id: newsA, newsB.id: newsB]

        let errors = policy.validateExecution(
            actionKind: .buy,
            targetName: "中际旭创",
            targetCode: nil,
            instruction: "小仓分批买入，不超过一成",
            trigger: "站稳分时均线",
            invalidation: "跌破昨日低点",
            quoteAssessment: makeFreshAssessment(),
            marketDataIsFresh: true,
            evidenceIDs: [local.id, newsA.id, newsB.id],
            evidenceByID: evidenceByID,
            relatedEntityCodes: [],
            relatedEntityNames: [],
            relatedSectorKeys: [],
            requiresFundDisclosure: false,
            fundDisclosureEvidencePrefix: nil
        )
        XCTAssertTrue(
            errors.contains { $0.contains("未匹配标的") },
            "与标的无关的热榜不得解锁买卖，实际：\(errors)"
        )
    }
}
