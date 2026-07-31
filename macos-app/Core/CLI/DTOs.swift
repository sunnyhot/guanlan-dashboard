import Foundation

// MARK: - Common output DTOs

struct CLIVersionOutput: Codable {
    let version: String
    let runtime: String
    let platform: String
}

struct CLIAppOpenOutput: Codable {
    let opened: Bool
    let appPath: String
}

// MARK: - Snapshot group lookup

struct CLISnapshotGroupRow: Codable, Equatable {
    let groupId: Int
    let groupName: String
    let managerName: String
    let managerBrokerUserId: String
}

struct CLIGroupLookupOutput: Codable {
    let groupId: Int
    let source: String
    let group: CLISnapshotGroupRow?
}

// MARK: - Snapshot / forum records

struct CLISnapshotRecordRow: Codable, Equatable {
    let postId: Int
    let groupId: Int
    let groupName: String
    let brokerUserId: String
    let spaceUserId: String
    let userName: String
    let userLabel: String
    let createdAt: String
    let title: String
    let likeCount: Int
    let commentCount: Int
    let detailUrl: String
    let contentText: String?
}

struct CLISnapshotOutput: Codable {
    let count: Int
    let items: [CLISnapshotRecordRow]
    let group: CLISnapshotGroupRow?
}

struct CLIPublicItemRow: Codable, Equatable {
    let query: String
    let title: String
    let author: String
    let publishDate: String
    let url: String
    let source: String
    let snippet: String
    let content: String
}

struct CLIPublicItemsOutput: Codable {
    let count: Int
    let items: [CLIPublicItemRow]
}

// MARK: - Comments (recursive)

struct CLICommentRow: Codable, Equatable {
    let id: Int
    let postId: Int
    let userName: String
    let brokerUserId: String
    let content: String
    let createdAt: String
    let likeCount: Int
    let replyCount: Int
    let ipLocation: String
    let toUserName: String
    let children: [CLICommentRow]
}

struct CLICommentsOutput: Codable {
    let postId: Int
    let pageNum: Int
    let pageSize: Int
    let sortType: String
    let hasMore: Bool
    let comments: [CLICommentRow]
}

// MARK: - Platform actions

struct CLIActionRow: Codable, Equatable {
    let uid: String
    let date: String
    let adjustmentId: Int
    let action: String
    let actionTitle: String
    let side: String
    let fundCode: String
    let fundName: String
    let tradeUnit: Int
    let tradeValuation: Double
    let tradeValuationDate: String
    let currentValuation: Double
    let currentValuationSource: String
    let currentValuationTime: String
    let valuationChangePct: Double
    let articleUrl: String
}

struct CLIPlatformActionsOutput: Codable {
    let prodCode: String
    let side: String
    let since: String
    let until: String
    let count: Int
    let items: [CLIActionRow]
}

// MARK: - Platform holdings

struct CLIHoldingRow: Codable, Equatable {
    let label: String
    let fundName: String
    let fundCode: String
    let category: String
    let currentUnits: Int
    let avgCost: Double
    let currentPrice: Double
    let priceSourceLabel: String
    let priceTime: String
    let positionValue: Double
    let profitAmount: Double
    let profitRatio: Double
    let latestActionTitle: String
    let latestTime: String
}

struct CLIPlatformHoldingsOutput: Codable {
    let prodCode: String
    let assetCount: Int
    let totalUnits: Int
    let count: Int
    let items: [CLIHoldingRow]
}

// MARK: - Platform timeline

struct CLITimelineEntry: Codable {
    let label: String
    let eventCount: Int
    let buyCount: Int
    let sellCount: Int
    let latestTime: String
    let entries: [CLIActionRow]
}

struct CLIPlatformTimelineOutput: Codable {
    let prodCode: String
    let side: String
    let since: String
    let until: String
    let count: Int
    let items: [CLITimelineEntry]
}

// MARK: - Platform monthly

struct CLIMonthSummary: Codable, Equatable {
    let month: String
    let totalCount: Int
    let buyCount: Int
    let sellCount: Int
    let activeDayCount: Int
    let tradesPerActiveDay: Double
}

struct CLIMonthlySummary: Codable, Equatable {
    let monthCount: Int
    let totalCount: Int
    let buyCount: Int
    let sellCount: Int
    let avgTotalPerMonth: Double
    let avgBuyPerMonth: Double
    let avgSellPerMonth: Double
}

struct CLIPlatformMonthlyOutput: Codable {
    let prodCode: String
    let side: String
    let since: String
    let until: String
    let months: Int
    let summary: CLIMonthlySummary
    let items: [CLIMonthSummary]
}

// MARK: - Valuation (null-vs-zero)

struct CLIValuationRow: Codable, Equatable {
    let fundCode: String
    let fundName: String
    /// nil → JSON `null`（保留原 `JSONValue` 语义），非 0。
    let currentValuation: NullDouble
    let currentSource: String
    let currentTime: String
    /// nil → JSON `null`（原 `JSONValue`）。
    let changePct: NullDouble
}

struct CLIValuationOutput: Codable {
    let count: Int
    let items: [CLIValuationRow]
}

// MARK: - Updates watch

struct CLIUpdatesWatchOutput: Codable {
    let checkedAt: String
    let stateFile: String
    let forumSource: String
    let forumNote: String
    let initialized: Bool
    let emitInitial: Bool
    let hasUpdates: Bool
    let tradeTotal: Int
    let postTotal: Int
    let newTradeCount: Int
    let newPostCount: Int
    let newTrades: [CLIActionRow]
    let newPosts: [CLISnapshotRecordRow]
}

/// `updates-watch` 落地状态文件。键名保持 snake_case 字面量——这是磁盘格式，
/// **不**走 `convertToSnakeCase`，避免迁移期间文件名漂移。
struct CLIWatchState: Codable {
    let updatedAt: String
    let forumSource: String
    let seenTradeIds: [String]
    let seenPostIds: [String]
    let prodCode: String
    let managerName: String

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case forumSource = "forum_source"
        case seenTradeIds = "seen_trade_ids"
        case seenPostIds = "seen_post_ids"
        case prodCode = "prod_code"
        case managerName = "manager_name"
    }

    /// 状态文件输出格式与命令输出略有差异：不需要 pretty/sorted 也能稳定，
    /// 但沿用 QiemanCLI.encoder 的格式便于 diff。
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

// MARK: - Signal extract (dynamic JSON input → typed output)

struct CLISignalItem: Codable {
    let action: String
    let title: String
    let createdAt: String
    let detailUrl: String

    /// 用于 `latest` 字段的空对象占位（原 `limited.first ?? [:]` 的等价表达）。
    static let empty = CLISignalItem(action: "", title: "", createdAt: "", detailUrl: "")
}

struct CLISignalActionCount: Codable {
    let action: String
    let count: Int
}

struct CLISignalExtractOutput: Codable {
    let source: String
    let recordCount: Int
    let signalCount: Int
    let eventCount: Int
    let counts: [String: Int]
    let topActions: [CLISignalActionCount]
    /// 最新一条信号项；若无信号则输出空对象 `{}`（原 `limited.first ?? [:]`）。
    let latest: CLISignalItem
    let items: [CLISignalItem]
}
