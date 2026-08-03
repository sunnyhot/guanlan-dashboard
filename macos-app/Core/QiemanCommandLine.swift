import Foundation

enum QiemanCommandLineError: LocalizedError {
    case usage(String)
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .usage(let message): return message
        case .invalidJSON: return "无法生成 JSON 输出。"
        }
    }
}

struct QiemanCommandArguments {
    let command: String
    private let values: [String: [String]]
    private let flags: Set<String>

    init(_ arguments: [String]) throws {
        guard let command = arguments.first, !command.hasPrefix("-") else {
            throw QiemanCommandLineError.usage(QiemanCommandLine.helpText)
        }
        self.command = command

        var parsedValues: [String: [String]] = [:]
        var parsedFlags: Set<String> = []
        var index = 1
        while index < arguments.count {
            let token = arguments[index]
            guard token.hasPrefix("--") else {
                throw QiemanCommandLineError.usage("无法识别参数：\(token)")
            }
            let key = String(token.dropFirst(2))
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                parsedValues[key, default: []].append(arguments[index + 1])
                index += 2
            } else {
                parsedFlags.insert(key)
                index += 1
            }
        }
        values = parsedValues
        flags = parsedFlags
    }

    func string(_ key: String, default fallback: String = "") -> String {
        values[key]?.last ?? fallback
    }

    func strings(_ key: String) -> [String] {
        values[key] ?? []
    }

    func int(_ key: String, default fallback: Int) -> Int {
        Int(string(key)) ?? fallback
    }

    func bool(_ key: String) -> Bool {
        flags.contains(key)
    }
}

struct QiemanCommandLine {
    static let helpText = """
    qieman-cli — 且慢原生命令行工具（macOS）

    用法：qieman-cli <command> [options]

      group-lookup         解析小组
      group-posts          查询公开小组动态
      public-items         查询公开主理人动态（原生小组源）
      post-comments        查询帖子评论
      platform-actions     查询平台调仓
      platform-holdings    查询平台持仓
      platform-timeline    查询标的调仓时间线
      platform-monthly     查询月度调仓汇总
      alfa-actions         查询投顾组合调仓（alfa 线）
      valuation            查询基金实时估值
      updates-watch        增量巡检调仓与动态
      signal-extract       从 JSON 文件提取交易关键词
      app-open             打开原生 macOS App

    所有数据命令默认输出 JSON。
    """

    private let arguments: QiemanCommandArguments

    init(arguments: [String]) throws {
        self.arguments = try QiemanCommandArguments(arguments)
    }

    /// 执行命令并返回写入 stdout 的字节。
    /// - Returns: `Data`：UTF-8 文本（help）或 JSON 编码字节（其它命令）。
    func run() async throws -> Data {
        switch arguments.command {
        case "help", "--help", "-h":
            return Data(Self.helpText.utf8)
        case "version":
            return try QiemanCLI.encodeJSON(
                CLIVersionOutput(version: "1", runtime: "swift", platform: "macos")
            )
        case "group-lookup":
            return try await groupLookup()
        case "group-posts":
            return try await snapshot(mode: .groupManager)
        case "public-items":
            return try await publicItems()
        case "post-comments":
            return try await comments()
        case "platform-actions":
            return try await platformActions()
        case "platform-holdings":
            return try await platformHoldings()
        case "platform-timeline":
            return try await platformTimeline()
        case "platform-monthly":
            return try await platformMonthly()
        case "alfa-actions":
            return try await alfaActions()
        case "valuation":
            return try await valuation()
        case "updates-watch":
            return try await updatesWatch()
        case "signal-extract":
            return try signalExtract()
        case "app-open":
            return try await openApp()
        default:
            throw QiemanCommandLineError.usage("未知命令：\(arguments.command)\n\n\(Self.helpText)")
        }
    }

    // MARK: - Handlers

    private func snapshot(mode: QueryMode) async throws -> Data {
        let payload = try await fetchSnapshot(mode: mode)
        let limit = max(1, arguments.int("limit", default: 100))
        let includeContent = arguments.bool("include-content")
        let records = payload.records.prefix(limit).map { recordRow($0, includeContent: includeContent) }
        let output = CLISnapshotOutput(
            count: records.count,
            items: Array(records),
            group: payload.group.map(groupRow)
        )
        return try QiemanCLI.encodeJSON(output)
    }

    private func publicItems() async throws -> Data {
        let payload = try await fetchSnapshot(mode: .groupManager, keywordOverride: arguments.string("query"))
        let limit = max(1, arguments.int("preview", default: arguments.int("limit", default: 40)))
        let queryText = arguments.string("query")
        let includeContent = arguments.bool("include-content")
        let rows = payload.records.prefix(limit).map { record -> CLIPublicItemRow in
            CLIPublicItemRow(
                query: queryText,
                title: record.title ?? record.intro ?? "",
                author: record.userName ?? record.managerName ?? "",
                publishDate: record.createdAt ?? "",
                url: record.detailUrl ?? "",
                source: "qieman-native-group",
                snippet: record.intro ?? record.contentText ?? "",
                content: includeContent ? (record.contentText ?? "") : ""
            )
        }
        return try QiemanCLI.encodeJSON(CLIPublicItemsOutput(count: rows.count, items: Array(rows)))
    }

    private func groupLookup() async throws -> Data {
        let payload = try await fetchSnapshot(mode: .groupManager)
        guard let group = payload.group, let groupID = group.groupId else {
            throw QiemanCommandLineError.usage("无法解析 groupId")
        }
        let source: String
        if !arguments.string("group-id").isEmpty { source = "group-id" }
        else if !arguments.string("group-url").isEmpty { source = "group-url" }
        else if !arguments.string("manager-name").isEmpty { source = "manager-name" }
        else { source = "prod-code" }
        let groupRowValue: CLISnapshotGroupRow? = arguments.bool("with-group-info") ? groupRow(group) : nil
        return try QiemanCLI.encodeJSON(
            CLIGroupLookupOutput(groupId: groupID, source: source, group: groupRowValue)
        )
    }

    private func comments() async throws -> Data {
        let postID = arguments.int("post-id", default: 0)
        guard postID > 0 else { throw QiemanCommandLineError.usage("请提供 --post-id") }
        let payload = try await nativeClient().fetchComments(
            postID: postID,
            sortType: arguments.string("sort-type", default: "hot"),
            pageNum: max(1, arguments.int("page-num", default: 1)),
            pageSize: max(1, arguments.int("page-size", default: 10)),
            managerBrokerUserID: arguments.string("manager-broker-user-id")
        )
        return try QiemanCLI.encodeJSON(
            CLICommentsOutput(
                postId: payload.postId,
                pageNum: payload.pageNum,
                pageSize: payload.pageSize,
                sortType: payload.sortType,
                hasMore: payload.hasMore,
                comments: payload.comments.map(commentRow)
            )
        )
    }

    private func platformActions() async throws -> Data {
        let prodCode = arguments.string("prod-code", default: "LONG_WIN")
        let payload = try await QiemanPlatformNativeClient().fetchPlatformPayload(prodCode: prodCode)
        let rows = Array(filteredActions(payload.actions ?? [])
            .prefix(max(1, arguments.int("limit", default: 20)))
            .map(actionRow))
        return try QiemanCLI.encodeJSON(
            CLIPlatformActionsOutput(
                prodCode: prodCode,
                side: arguments.string("side", default: "all"),
                since: arguments.string("since"),
                until: arguments.string("until"),
                count: rows.count,
                items: rows
            )
        )
    }

    private func platformHoldings() async throws -> Data {
        let prodCode = arguments.string("prod-code", default: "LONG_WIN")
        let payload = try await QiemanPlatformNativeClient().fetchPlatformPayload(prodCode: prodCode)
        let requestedCode = arguments.string("fund-code")
        let minUnits = max(0, arguments.int("min-units", default: 1))
        let limit = max(1, arguments.int("limit", default: 100))
        let items = (payload.holdings?.items ?? []).filter {
            ($0.currentUnits ?? 0) >= minUnits && (requestedCode.isEmpty || $0.fundCode == requestedCode)
        }.prefix(limit).map(holdingRow)
        return try QiemanCLI.encodeJSON(
            CLIPlatformHoldingsOutput(
                prodCode: prodCode,
                assetCount: payload.holdings?.assetCount ?? 0,
                totalUnits: payload.holdings?.totalUnits ?? 0,
                count: items.count,
                items: Array(items)
            )
        )
    }

    private func platformTimeline() async throws -> Data {
        let prodCode = arguments.string("prod-code", default: "LONG_WIN")
        let payload = try await QiemanPlatformNativeClient().fetchPlatformPayload(prodCode: prodCode)
        let actions = filteredActions(payload.actions ?? [])
        let assetFilter = arguments.string("asset").lowercased()
        let perAssetLimit = max(1, arguments.int("limit-entries", default: 10))
        let assetLimit = max(1, arguments.int("limit-assets", default: 20))
        let groups = Dictionary(grouping: actions) { $0.fundName ?? $0.fundCode ?? "未知标的" }
        var rows: [CLITimelineEntry] = groups.map { label, entries in
            let sorted = entries.sorted { actionDate($0) > actionDate($1) }
            return CLITimelineEntry(
                label: label,
                eventCount: entries.count,
                buyCount: entries.filter { normalizedSide($0) == "buy" }.count,
                sellCount: entries.filter { normalizedSide($0) == "sell" }.count,
                latestTime: sorted.first.map(actionDate) ?? "",
                entries: sorted.prefix(perAssetLimit).map(actionRow)
            )
        }
        if !assetFilter.isEmpty {
            rows = rows.filter { $0.label.lowercased().contains(assetFilter) }
        }
        rows.sort { $0.latestTime > $1.latestTime }
        let trimmed = Array(rows.prefix(assetLimit))
        return try QiemanCLI.encodeJSON(
            CLIPlatformTimelineOutput(
                prodCode: prodCode,
                side: arguments.string("side", default: "all"),
                since: arguments.string("since"),
                until: arguments.string("until"),
                count: trimmed.count,
                items: trimmed
            )
        )
    }

    private func platformMonthly() async throws -> Data {
        let prodCode = arguments.string("prod-code", default: "LONG_WIN")
        let payload = try await QiemanPlatformNativeClient().fetchPlatformPayload(prodCode: prodCode)
        let actions = filteredActions(payload.actions ?? [])
        let groups = Dictionary(grouping: actions) { String(actionDate($0).prefix(7)) }
        let monthLimit = max(1, arguments.int("months", default: 12))
        let items: [CLIMonthSummary] = groups.keys.sorted(by: >).prefix(monthLimit).map { month in
            let rows = groups[month] ?? []
            let days = Set(rows.map { String(actionDate($0).prefix(10)) })
            return CLIMonthSummary(
                month: month,
                totalCount: rows.count,
                buyCount: rows.filter { normalizedSide($0) == "buy" }.count,
                sellCount: rows.filter { normalizedSide($0) == "sell" }.count,
                activeDayCount: days.count,
                tradesPerActiveDay: days.isEmpty ? 0 : Double(rows.count) / Double(days.count)
            )
        }
        let buyCount = actions.filter { normalizedSide($0) == "buy" }.count
        let sellCount = actions.filter { normalizedSide($0) == "sell" }.count
        let monthCount = items.count
        return try QiemanCLI.encodeJSON(
            CLIPlatformMonthlyOutput(
                prodCode: prodCode,
                side: arguments.string("side", default: "all"),
                since: arguments.string("since"),
                until: arguments.string("until"),
                months: monthLimit,
                summary: CLIMonthlySummary(
                    monthCount: monthCount,
                    totalCount: actions.count,
                    buyCount: buyCount,
                    sellCount: sellCount,
                    avgTotalPerMonth: monthCount == 0 ? 0 : Double(actions.count) / Double(monthCount),
                    avgBuyPerMonth: monthCount == 0 ? 0 : Double(buyCount) / Double(monthCount),
                    avgSellPerMonth: monthCount == 0 ? 0 : Double(sellCount) / Double(monthCount)
                ),
                items: items
            )
        )
    }

    private func alfaActions() async throws -> Data {
        let poCode = arguments.string("po-code", default: "ZH157591")
        let payload = try await QiemanAlfaClient().fetchAlfaPayload(poCode: poCode)
        let rows = Array((payload.actions ?? [])
            .prefix(max(1, arguments.int("limit", default: 20)))
            .map(actionRow))
        return try QiemanCLI.encodeJSON(
            CLIPlatformActionsOutput(
                prodCode: poCode,
                side: arguments.string("side", default: "all"),
                since: arguments.string("since"),
                until: arguments.string("until"),
                count: rows.count,
                items: rows
            )
        )
    }

    private func valuation() async throws -> Data {
        guard arguments.string("at-date").isEmpty else {
            throw QiemanCommandLineError.usage("--at-date 历史日期估值已移除；valuation 仅返回当前实时估值或官方净值。")
        }
        var codes = arguments.strings("fund-code")
        codes += arguments.string("fund-codes").split(separator: ",").map(String.init)
        codes = Array(Set(codes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        guard !codes.isEmpty else { throw QiemanCommandLineError.usage("请提供 --fund-code 或 --fund-codes") }
        let holdings = codes.map { UserPortfolioHolding(fundCode: $0, units: 1, costPrice: nil, displayName: nil) }
        let snapshot = try await QiemanPlatformNativeClient().fetchUserPortfolioSnapshot(holdings: holdings, forceQuoteRefresh: true)
        let rows = snapshot.rows.map { row in
            CLIValuationRow(
                fundCode: row.holding.normalizedFundCode,
                fundName: row.fundName,
                currentValuation: NullDouble(row.currentPrice ?? row.officialNav),
                currentSource: row.priceSource ?? "未知",
                currentTime: row.priceTime ?? row.officialNavDate ?? "",
                changePct: NullDouble(row.estimateChangePct)
            )
        }
        return try QiemanCLI.encodeJSON(CLIValuationOutput(count: rows.count, items: rows))
    }

    private func updatesWatch() async throws -> Data {
        let prodCode = arguments.string("prod-code", default: "LONG_WIN")
        let managerName = arguments.string("manager-name", default: "ETF拯救世界")
        async let platformTask = QiemanPlatformNativeClient().fetchPlatformPayload(prodCode: prodCode)
        let forumResult = try await watchForumSnapshot()
        let platform = try await platformTask
        let forum = forumResult.payload
        let trades = Array((platform.actions ?? []).prefix(max(1, arguments.int("max-trades", default: 120)))).map(actionRow)
        let posts = Array(forum.records.prefix(max(1, arguments.int("max-posts", default: 120)))).map { recordRow($0, includeContent: false) }
        let stateURL = watchStateURL(prodCode: prodCode, managerName: managerName)
        let (previous, firstRun) = loadWatchState(at: stateURL)
        let seenTrades = Set(previous.seenTradeIds)
        let seenPosts = Set(previous.seenPostIds)
        let tradeIDs = trades.map(tradeID)
        let postIDs = posts.map(postID)
        let emitInitial = arguments.bool("emit-initial")
        let preview = max(1, arguments.int("preview", default: 8))
        let newTrades: [CLIActionRow] = firstRun && !emitInitial ? [] : Array(trades.filter { !seenTrades.contains(tradeID($0)) }.prefix(preview))
        let newPosts: [CLISnapshotRecordRow] = firstRun && !emitInitial ? [] : Array(posts.filter { !seenPosts.contains(postID($0)) }.prefix(preview))
        let checkedAt = ISO8601DateFormatter().string(from: Date())
        let watchState = CLIWatchState(
            updatedAt: checkedAt,
            forumSource: forumResult.source,
            seenTradeIds: Array(tradeIDs.prefix(2000)),
            seenPostIds: Array(postIDs.prefix(2000)),
            prodCode: prodCode,
            managerName: managerName
        )
        try saveWatchState(watchState, at: stateURL)
        return try QiemanCLI.encodeJSON(
            CLIUpdatesWatchOutput(
                checkedAt: checkedAt,
                stateFile: stateURL.path,
                forumSource: forumResult.source,
                forumNote: forumResult.note,
                initialized: firstRun && !emitInitial,
                emitInitial: emitInitial,
                hasUpdates: !newTrades.isEmpty || !newPosts.isEmpty,
                tradeTotal: trades.count,
                postTotal: posts.count,
                newTradeCount: newTrades.count,
                newPostCount: newPosts.count,
                newTrades: newTrades,
                newPosts: newPosts
            )
        )
    }

    private func signalExtract() throws -> Data {
        let path = arguments.string("json-path")
        guard !path.isEmpty else { throw QiemanCommandLineError.usage("请提供 --json-path") }
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let rawItems: [[String: Any]]
        if let payload = object as? [String: Any], let items = payload["posts"] as? [[String: Any]] { rawItems = items }
        else if let items = object as? [[String: Any]] { rawItems = items }
        else { throw QiemanCommandLineError.usage("JSON 需要是数组或包含 posts 数组") }
        let limit = max(1, arguments.int("limit-items", default: 20))
        let keywords: [(String, [String])] = [
            ("buy", ["买入", "加仓", "申购", "定投", "发车"]),
            ("sell", ["卖出", "减仓", "赎回", "止盈"]),
            ("hold", ["持有", "观望", "不动"]),
        ]
        var counts = ["buy": 0, "sell": 0, "hold": 0]
        var items: [CLISignalItem] = []
        for row in rawItems {
            let text = [row["title"], row["intro"], row["content_text"], row["content"], row["snippet"]]
                .compactMap { $0 as? String }.joined(separator: " ")
            for (action, words) in keywords where words.contains(where: text.contains) {
                counts[action, default: 0] += 1
                items.append(CLISignalItem(
                    action: action,
                    title: row["title"] as? String ?? row["intro"] as? String ?? "",
                    createdAt: row["created_at"] as? String ?? row["publish_date"] as? String ?? "",
                    detailUrl: row["detail_url"] as? String ?? row["url"] as? String ?? ""
                ))
                break
            }
        }
        let limited = Array(items.prefix(limit))
        let topActions = counts
            .map { CLISignalActionCount(action: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
        return try QiemanCLI.encodeJSON(
            CLISignalExtractOutput(
                source: url.path,
                recordCount: rawItems.count,
                signalCount: items.count,
                eventCount: items.count,
                counts: counts,
                topActions: topActions,
                latest: limited.first ?? .empty,
                items: limited
            )
        )
    }

    private func openApp() async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        let appPath = arguments.string("app-path")
        process.arguments = appPath.isEmpty ? ["-a", "且慢主理人"] : [appPath]
        try process.run()
        process.waitUntilExit()
        return try QiemanCLI.encodeJSON(
            CLIAppOpenOutput(opened: process.terminationStatus == 0, appPath: appPath)
        )
    }

    // MARK: - Support

    private func nativeClient() -> QiemanNativeClient {
        QiemanNativeClient()
    }

    private func fetchSnapshot(
        mode: QueryMode,
        keywordOverride: String? = nil,
        userNameOverride: String? = nil
    ) async throws -> SnapshotPayload {
        var form = QueryFormState()
        form.mode = mode
        form.prodCode = arguments.string("prod-code", default: "LONG_WIN")
        let managerName = arguments.string("manager-name")
        form.managerName = managerName.isEmpty ? arguments.string("author") : managerName
        form.groupURL = arguments.string("group-url")
        form.groupID = arguments.string("group-id")
        form.userName = userNameOverride ?? arguments.string("user-name")
        form.keyword = keywordOverride ?? arguments.string("keyword")
        form.since = arguments.string("since")
        form.until = arguments.string("until")
        form.pages = String(max(1, arguments.int("pages", default: 5)))
        form.pageSize = String(max(1, arguments.int("page-size", default: 20)))
        return try await nativeClient().fetchSnapshot(form: form)
    }

    private func watchForumSnapshot() async throws -> (payload: SnapshotPayload, source: String, note: String) {
        (
            try await fetchSnapshot(mode: .groupManager, userNameOverride: nil),
            "public-group",
            ""
        )
    }

    private func filteredActions(_ actions: [PlatformActionPayload]) -> [PlatformActionPayload] {
        let side = arguments.string("side", default: "all")
        let since = arguments.string("since")
        let until = arguments.string("until")
        return actions.filter { action in
            let currentSide = normalizedSide(action)
            let date = actionDate(action)
            if side != "all" && side != currentSide { return false }
            if !since.isEmpty && date < since { return false }
            if !until.isEmpty && date > until + "T99" { return false }
            return true
        }
    }

    private func actionDate(_ action: PlatformActionPayload) -> String {
        action.txnDate ?? action.createdAt ?? ""
    }

    private func normalizedSide(_ action: PlatformActionPayload) -> String {
        let raw = (action.side ?? action.action ?? "").lowercased()
        if raw.contains("buy") || raw.contains("买") || raw.contains("加") { return "buy" }
        if raw.contains("sell") || raw.contains("卖") || raw.contains("减") { return "sell" }
        return raw
    }

    // MARK: - Row builders (App model → DTO)

    private func recordRow(_ record: SnapshotRecordPayload, includeContent: Bool) -> CLISnapshotRecordRow {
        CLISnapshotRecordRow(
            postId: record.postId ?? 0,
            groupId: record.groupId ?? 0,
            groupName: record.groupName ?? "",
            brokerUserId: record.brokerUserId ?? "",
            spaceUserId: record.spaceUserId ?? "",
            userName: record.userName ?? "",
            userLabel: record.userLabel ?? "",
            createdAt: record.createdAt ?? "",
            title: record.title ?? record.intro ?? "",
            likeCount: record.likeCount ?? 0,
            commentCount: record.commentCount ?? 0,
            detailUrl: record.detailUrl ?? "",
            contentText: includeContent ? (record.contentText ?? "") : nil
        )
    }

    private func groupRow(_ group: GroupPayload) -> CLISnapshotGroupRow {
        CLISnapshotGroupRow(
            groupId: group.groupId ?? 0,
            groupName: group.groupName ?? "",
            managerName: group.managerName ?? "",
            managerBrokerUserId: group.managerBrokerUserId ?? ""
        )
    }

    private func commentRow(_ comment: CommentPayload) -> CLICommentRow {
        CLICommentRow(
            id: comment.id,
            postId: comment.postId ?? 0,
            userName: comment.userName ?? "",
            brokerUserId: comment.brokerUserId ?? "",
            content: comment.content ?? "",
            createdAt: comment.createdAt ?? "",
            likeCount: comment.likeCount ?? 0,
            replyCount: comment.replyCount ?? 0,
            ipLocation: comment.ipLocation ?? "",
            toUserName: comment.toUserName ?? "",
            children: comment.children.map(commentRow)
        )
    }

    private func actionRow(_ action: PlatformActionPayload) -> CLIActionRow {
        CLIActionRow(
            uid: action.actionKey ?? action.id,
            date: actionDate(action),
            adjustmentId: action.adjustmentId ?? 0,
            action: action.action ?? "",
            actionTitle: action.actionTitle ?? action.displayTitle,
            side: normalizedSide(action),
            fundCode: action.fundCode ?? "",
            fundName: action.fundName ?? "",
            tradeUnit: action.tradeUnit ?? 0,
            tradeValuation: action.tradeValuation ?? 0,
            tradeValuationDate: action.tradeValuationDate ?? "",
            currentValuation: action.currentValuation ?? 0,
            currentValuationSource: action.currentValuationSource ?? "",
            currentValuationTime: action.currentValuationTime ?? "",
            valuationChangePct: action.valuationChangePct ?? 0,
            articleUrl: action.articleUrl ?? ""
        )
    }

    private func holdingRow(_ holding: HoldingItemPayload) -> CLIHoldingRow {
        CLIHoldingRow(
            label: holding.label ?? holding.fundName ?? "",
            fundName: holding.fundName ?? "",
            fundCode: holding.fundCode ?? "",
            category: holding.largeClass ?? "未分类",
            currentUnits: holding.currentUnits ?? 0,
            avgCost: holding.avgCost ?? 0,
            currentPrice: holding.currentPrice ?? 0,
            priceSourceLabel: holding.priceSourceLabel ?? holding.priceSource ?? "",
            priceTime: holding.priceTime ?? "",
            positionValue: holding.positionValue ?? holding.estimatedValue ?? 0,
            profitAmount: holding.profitAmount ?? 0,
            profitRatio: holding.profitRatio ?? holding.profitPct ?? 0,
            latestActionTitle: holding.latestActionTitle ?? holding.latestAction ?? "",
            latestTime: holding.latestTime ?? ""
        )
    }

    // MARK: - Watch state file (snake_case disk format)

    private func watchStateURL(prodCode: String, managerName: String) -> URL {
        let explicit = arguments.string("state-file")
        if !explicit.isEmpty { return URL(fileURLWithPath: NSString(string: explicit).expandingTildeInPath) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("QiemanDashboard/output", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let slug = (prodCode + "-" + managerName).replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "-", options: .regularExpression)
        return base.appendingPathComponent("watch-state-\(slug).json")
    }

    private func loadWatchState(at url: URL) -> (state: CLIWatchState, isFirstRun: Bool) {
        guard let data = try? Data(contentsOf: url),
              let state = try? CLIWatchState.decoder.decode(CLIWatchState.self, from: data) else {
            // 状态文件不存在或解码失败：视为首次运行（等价于原 previous.isEmpty）。
            return (
                CLIWatchState(
                    updatedAt: "",
                    forumSource: "",
                    seenTradeIds: [],
                    seenPostIds: [],
                    prodCode: "",
                    managerName: ""
                ),
                true
            )
        }
        return (state, false)
    }

    private func saveWatchState(_ state: CLIWatchState, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try CLIWatchState.encoder.encode(state)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - ID extraction from DTO rows

    private func tradeID(_ row: CLIActionRow) -> String {
        // uid 已是字符串主键，回退到复合键以兼容历史 uid 缺失的样本
        let composite = ["\(row.adjustmentId)", row.side, row.fundCode, row.date, "\(row.tradeUnit)"]
            .joined(separator: "|")
        return row.uid.isEmpty ? composite : row.uid
    }

    private func postID(_ row: CLISnapshotRecordRow) -> String {
        if row.postId > 0 { return "post:\(row.postId)" }
        return "url:\(row.detailUrl)"
    }
}

extension CLIWatchState {
    /// 状态文件读取用的解码器：键名通过显式 CodingKeys 映射回 snake_case。
    static let decoder: JSONDecoder = JSONDecoder()
}
