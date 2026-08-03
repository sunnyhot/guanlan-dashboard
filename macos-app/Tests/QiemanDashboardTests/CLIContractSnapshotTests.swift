import Foundation
import XCTest
@testable import QiemanDashboard

/// CLI 输出契约快照测试：锁住 snake_case 字段、null 语义、递归结构和占位对象。
///
/// 这些测试通过直接序列化 DTO 验证契约稳定性，不依赖网络/Cookie；
/// 真正的命令执行测试见 `QiemanCommandLineTests`。
final class CLIContractSnapshotTests: XCTestCase {

    // MARK: - snake_case key strategy

    func testSnakeCaseConversionPreservesExistingKeys() throws {
        let output = CLISnapshotGroupRow(
            groupId: 1001,
            groupName: "长赢计划投资",
            managerName: "ETF拯救世界",
            managerBrokerUserId: "B-100"
        )
        let json = try decodeJSON(QiemanCLI.encodeJSON(output))

        // camelCase 属性 → snake_case 键
        XCTAssertEqual(json["group_id"] as? Int, 1001)
        XCTAssertEqual(json["group_name"] as? String, "长赢计划投资")
        XCTAssertEqual(json["manager_name"] as? String, "ETF拯救世界")
        XCTAssertEqual(json["manager_broker_user_id"] as? String, "B-100")
    }

    func testActionRowUsesCliContractKeys() throws {
        let row = CLIActionRow(
            uid: "uid-1",
            date: "2026-07-20",
            adjustmentId: 42,
            action: "buy",
            actionTitle: "买入",
            side: "buy",
            fundCode: "021550",
            fundName: "长赢",
            tradeUnit: 100,
            tradeValuation: 1.234,
            tradeValuationDate: "2026-07-19",
            currentValuation: 1.3,
            currentValuationSource: "官方净值",
            currentValuationTime: "2026-07-20 09:30",
            valuationChangePct: 5.4,
            articleUrl: "https://example.invalid/article"
        )
        let json = try decodeJSON(QiemanCLI.encodeJSON(row))

        // 多词 snake_case 键
        XCTAssertEqual(json["adjustment_id"] as? Int, 42)
        XCTAssertEqual(json["action_title"] as? String, "买入")
        XCTAssertEqual(json["fund_code"] as? String, "021550")
        XCTAssertEqual(json["trade_unit"] as? Int, 100)
        XCTAssertEqual(json["trade_valuation"] as? Double, 1.234)
        XCTAssertEqual(json["trade_valuation_date"] as? String, "2026-07-19")
        XCTAssertEqual(json["current_valuation"] as? Double, 1.3)
        XCTAssertEqual(json["current_valuation_source"] as? String, "官方净值")
        XCTAssertEqual(json["current_valuation_time"] as? String, "2026-07-20 09:30")
        XCTAssertEqual(json["valuation_change_pct"] as? Double, 5.4)
        XCTAssertEqual(json["article_url"] as? String, "https://example.invalid/article")
        // 单词键不变形
        XCTAssertEqual(json["uid"] as? String, "uid-1")
        XCTAssertEqual(json["date"] as? String, "2026-07-20")
        XCTAssertEqual(json["action"] as? String, "buy")
        XCTAssertEqual(json["side"] as? String, "buy")
    }

    // MARK: - Recursive comments

    func testCommentRowSerializesNestedChildren() throws {
        let leaf1 = CLICommentRow(id: 2, postId: 1, userName: "u2", brokerUserId: "b2",
                                   content: "reply", createdAt: "2026-07-20", likeCount: 0,
                                   replyCount: 0, ipLocation: "", toUserName: "u1", children: [])
        let leaf2 = CLICommentRow(id: 3, postId: 1, userName: "u3", brokerUserId: "b3",
                                   content: "reply2", createdAt: "2026-07-20", likeCount: 1,
                                   replyCount: 0, ipLocation: "", toUserName: "u1",
                                   children: [CLICommentRow(id: 4, postId: 1, userName: "u4",
                                                             brokerUserId: "b4", content: "deep",
                                                             createdAt: "2026-07-20", likeCount: 0,
                                                             replyCount: 0, ipLocation: "",
                                                             toUserName: "u3", children: [])])
        let root = CLICommentRow(id: 1, postId: 1, userName: "u1", brokerUserId: "b1",
                                  content: "root", createdAt: "2026-07-20", likeCount: 5,
                                  replyCount: 2, ipLocation: "北京", toUserName: "",
                                  children: [leaf1, leaf2])
        let json = try decodeJSON(QiemanCLI.encodeJSON(root))

        XCTAssertEqual(json["id"] as? Int, 1)
        XCTAssertEqual(json["user_name"] as? String, "u1")
        XCTAssertEqual(json["ip_location"] as? String, "北京")

        let children = try XCTUnwrap(json["children"] as? [[String: Any]])
        XCTAssertEqual(children.count, 2)
        let deepChildren = try XCTUnwrap(children[1]["children"] as? [[String: Any]])
        XCTAssertEqual(deepChildren.count, 1)
        XCTAssertEqual(deepChildren[0]["id"] as? Int, 4)
        XCTAssertEqual(deepChildren[0]["to_user_name"] as? String, "u3")
    }

    // MARK: - NullDouble null-vs-zero semantics

    func testNullDoublePreservesNullVsZero() throws {
        let rowWithValue = CLIValuationRow(
            fundCode: "X", fundName: "X",
            currentValuation: NullDouble(1.5),
            currentSource: "src", currentTime: "t",
            changePct: NullDouble(2.5)
        )
        let json = try decodeJSON(QiemanCLI.encodeJSON(rowWithValue))

        // 数值正常输出
        XCTAssertEqual(json["current_valuation"] as? Double, 1.5)
        XCTAssertEqual(json["change_pct"] as? Double, 2.5)
        // nil → 显式 null（键存在、值为 NSNull，不是缺失键，也不是 0）
        XCTAssertTrue(json.keys.contains("current_valuation"))
        XCTAssertTrue(json["current_valuation"] is NSNull || json["current_valuation"] != nil)
    }

    func testNullDoubleZeroIsNotDropped() throws {
        let rowWithZero = CLIValuationRow(
            fundCode: "X", fundName: "X",
            currentValuation: NullDouble(0),
            currentSource: "src", currentTime: "t",
            changePct: NullDouble(0)
        )
        let json = try decodeJSON(QiemanCLI.encodeJSON(rowWithZero))

        // 0 必须真实输出，不能被 null 吃掉
        XCTAssertEqual(json["current_valuation"] as? Double, 0)
        XCTAssertEqual(json["change_pct"] as? Double, 0)
    }

    func testValuationRowRoundTripPreservesNull() throws {
        let original = CLIValuationRow(
            fundCode: "001102", fundName: "前海开源",
            currentValuation: NullDouble(nil),
            currentSource: "未知", currentTime: "",
            changePct: NullDouble(nil)
        )
        let data = try QiemanCLI.encodeJSON(original)
        let decoded = try QiemanCLI.decodeJSON(CLIValuationRow.self, from: data)

        XCTAssertNil(decoded.currentValuation.value)
        XCTAssertNil(decoded.changePct.value)
    }

    // MARK: - Empty placeholders

    func testSignalExtractEmptyArraysArePresent() throws {
        let output = CLISignalExtractOutput(
            source: "/tmp/x.json",
            recordCount: 0,
            signalCount: 0,
            eventCount: 0,
            counts: ["buy": 0, "sell": 0, "hold": 0],
            topActions: [],
            latest: .empty,
            items: []
        )
        let json = try decodeJSON(QiemanCLI.encodeJSON(output))

        // latest 是空对象（不是 null）
        let latest = try XCTUnwrap(json["latest"] as? [String: Any])
        XCTAssertEqual(latest["action"] as? String, "")
        XCTAssertEqual(latest["title"] as? String, "")
    }

    // MARK: - Watch state file round-trip

    func testWatchStateRoundTripsPreservingSnakeCaseKeys() throws {
        let original = CLIWatchState(
            updatedAt: "2026-07-20T10:00:00Z",
            forumSource: "public-group",
            seenTradeIds: ["t1", "t2"],
            seenPostIds: ["p1"],
            prodCode: "LONG_WIN",
            managerName: "ETF拯救世界"
        )
        let data = try CLIWatchState.encoder.encode(original)

        // 直接验证磁盘 JSON 字面 key（保持向后兼容的关键）
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["updated_at"] as? String, "2026-07-20T10:00:00Z")
        XCTAssertEqual(json["forum_source"] as? String, "public-group")
        XCTAssertEqual(json["seen_trade_ids"] as? [String], ["t1", "t2"])
        XCTAssertEqual(json["seen_post_ids"] as? [String], ["p1"])
        XCTAssertEqual(json["prod_code"] as? String, "LONG_WIN")
        XCTAssertEqual(json["manager_name"] as? String, "ETF拯救世界")

        // 解码回去字段值不丢
        let decoded = try CLIWatchState.decoder.decode(CLIWatchState.self, from: data)
        XCTAssertEqual(decoded.updatedAt, original.updatedAt)
        XCTAssertEqual(decoded.forumSource, original.forumSource)
        XCTAssertEqual(decoded.seenTradeIds, original.seenTradeIds)
        XCTAssertEqual(decoded.seenPostIds, original.seenPostIds)
        XCTAssertEqual(decoded.prodCode, original.prodCode)
        XCTAssertEqual(decoded.managerName, original.managerName)
    }

    func testWatchStateDecodesLegacyEmptyFile() throws {
        // 历史无内容 / 损坏文件应能优雅解码为全空对象（与原 loadJSONObject 兜底等价）
        let empty = CLIWatchState(
            updatedAt: "", forumSource: "",
            seenTradeIds: [], seenPostIds: [],
            prodCode: "", managerName: ""
        )
        let data = try CLIWatchState.encoder.encode(empty)
        let decoded = try CLIWatchState.decoder.decode(CLIWatchState.self, from: data)
        XCTAssertEqual(decoded.seenTradeIds, [])
        XCTAssertEqual(decoded.seenPostIds, [])
    }

    // MARK: - Snapshot record optional content_text

    func testSnapshotRecordRowOmitsContentTextWhenExcluded() throws {
        let row = CLISnapshotRecordRow(
            postId: 1, groupId: 0, groupName: "", brokerUserId: "", spaceUserId: "",
            userName: "", userLabel: "", createdAt: "", title: "t",
            likeCount: 0, commentCount: 0, detailUrl: "",
            contentText: nil
        )
        let json = try decodeJSON(QiemanCLI.encodeJSON(row))
        XCTAssertFalse(json.keys.contains("content_text"),
                       "includeContent=false 时 content_text 应被省略，保持与原实现一致")
    }

    func testSnapshotRecordRowIncludesContentTextWhenIncluded() throws {
        let row = CLISnapshotRecordRow(
            postId: 1, groupId: 0, groupName: "", brokerUserId: "", spaceUserId: "",
            userName: "", userLabel: "", createdAt: "", title: "t",
            likeCount: 0, commentCount: 0, detailUrl: "",
            contentText: "正文内容"
        )
        let json = try decodeJSON(QiemanCLI.encodeJSON(row))
        XCTAssertEqual(json["content_text"] as? String, "正文内容")
    }

    // MARK: - Helpers

    private func decodeJSON(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
