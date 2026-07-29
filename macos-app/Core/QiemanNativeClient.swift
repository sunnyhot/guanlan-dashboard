import CryptoKit
import Foundation

enum NativeQiemanError: LocalizedError {
    case unsupportedMode(String)
    case missingGroup
    case noResults(String)
    case invalidResponse
    case api(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedMode(let mode):
            return "原生抓取暂不支持当前模式：\(mode)"
        case .missingGroup:
            return "无法解析主理人所在小组"
        case .noResults(let message):
            return message
        case .invalidResponse:
            return "且慢接口返回了无法识别的数据。"
        case .api(let message):
            return message
        }
    }
}

final class QiemanNativeClient {
    private let baseURL = URL(string: "https://qieman.com")!
    private let apiBase = "/pmdj/v2"
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    private let snapshotStore = NativeSnapshotStore()
    private let anonymousID: String

    init() {
        let seed = "\(Date().timeIntervalSince1970)-\(UUID().uuidString)"
        self.anonymousID = "anon-\(Self.sha256Hex(seed).prefix(16))"
    }

    func fetchSnapshot(form: QueryFormState, persist: Bool, outputDirectory: URL?) async throws -> SnapshotPayload {
        switch form.mode {
        case .groupManager:
            return try await fetchGroupManagerSnapshot(form: form, persist: persist, outputDirectory: outputDirectory)
        }
    }


    func fetchComments(
        postID: Int,
        sortType: String,
        pageNum: Int,
        pageSize: Int,
        managerBrokerUserID: String
    ) async throws -> CommentsPayload {
        var params: [String: String] = [
            "pageNum": String(max(1, pageNum)),
            "pageSize": String(max(1, pageSize)),
            "postId": String(postID),
        ]
        if sortType.lowercased() == "hot" {
            params["sortType"] = "HOT"
        }

        let payload = try await requestJSON(path: "/community/comment/list", params: params, cookie: nil)
        guard let items = payload as? [[String: Any]] else {
            throw NativeQiemanError.invalidResponse
        }

        var comments = items.map(normalizeComment)
        let targetBrokerUserID = managerBrokerUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !targetBrokerUserID.isEmpty {
            comments = comments.filter { commentThreadHasBrokerUser($0, target: targetBrokerUserID) }
        }

        return CommentsPayload(
            postId: postID,
            pageNum: max(1, pageNum),
            pageSize: max(1, pageSize),
            sortType: sortType.lowercased(),
            hasMore: items.count >= max(1, pageSize),
            comments: comments
        )
    }

    private func fetchGroupManagerSnapshot(form: QueryFormState, persist: Bool, outputDirectory: URL?) async throws -> SnapshotPayload {
        let groupID = try await resolveGroupID(form: form)
        let group = try await fetchGroupInfo(groupID: groupID, source: resolvedGroupSource(form: form, groupID: groupID))
        let pageSize = positiveInt(form.pageSize, fallback: 50)
        let pageLimit = optionalPositiveInt(form.pages)
        let targetUserID = group.managerBrokerUserId

        var posts: [[String: Any]] = []
        var pageNum = 1
        while true {
            let payload = try await requestJSON(
                path: "/community/post/list",
                params: [
                    "pageNum": String(pageNum),
                    "pageSize": String(pageSize),
                    "groupId": String(groupID),
                    "postType": "1",
                    "queryStrategy": "ONLY_GROUP_POST",
                    "orderBy": "TIME",
                ],
                cookie: nil
            )
            let items = extractItemsFromGroupList(payload)
            if items.isEmpty {
                break
            }
            for item in items {
                let post = parsePostItem(item, defaultGroup: group)
                if !targetUserID.isEmpty, normalizedString(post["broker_user_id"]) != targetUserID {
                    continue
                }
                if !postMatchesFilters(post: post, keyword: form.keyword, since: form.since, until: form.until, userName: form.managerName.isEmpty ? nil : form.managerName) {
                    continue
                }
                posts.append(post)
            }
            guard Self.shouldContinueForumPagination(
                itemCount: items.count,
                pageSize: pageSize,
                currentPage: pageNum,
                pageLimit: pageLimit
            ) else { break }
            pageNum += 1
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        if posts.isEmpty {
            throw NativeQiemanError.noResults("没有抓到符合条件的主理人发言。")
        }

        let filters = stringMap(
            ("prod_code", nonEmptyOrNil(form.prodCode)),
            ("group_id", String(groupID)),
            ("manager_name", nonEmptyOrNil(form.managerName)),
            ("keyword", nonEmptyOrNil(form.keyword)),
            ("since", nonEmptyOrNil(form.since)),
            ("until", nonEmptyOrNil(form.until))
        )

        let raw: [String: Any] = [
            "group": groupDictionary(group),
            "filters": filters,
            "posts": posts,
        ]

        let fileStem = safeFileStem(firstNonEmpty([
            group.managerName,
            form.managerName,
            form.prodCode,
            group.groupName,
        ]))
        return try buildSnapshot(raw: raw, fileStem: fileStem, suffix: "community", persist: persist, outputDirectory: outputDirectory)
    }

    /// 未设置页数上限时，只要接口仍返回完整一页，就继续拉取下一页。
    static func shouldContinueForumPagination(
        itemCount: Int,
        pageSize: Int,
        currentPage: Int,
        pageLimit: Int?
    ) -> Bool {
        guard itemCount >= pageSize else { return false }
        guard let pageLimit else { return true }
        return currentPage < pageLimit
    }

    private func buildSnapshot(raw: [String: Any], fileStem: String, suffix: String, persist _: Bool, outputDirectory _: URL?) throws -> SnapshotPayload {
        let timestamp = timestampString()
        let fileName = "\(fileStem)-\(suffix)-\(timestamp).json"
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName, isDirectory: false)

        return snapshotStore.snapshot(
            from: raw,
            fileURL: fileURL,
            createdAt: isoTimestampNow(),
            includeRecords: true,
            persisted: false
        )
    }

    private func fetchGroupInfo(groupID: Int, source: String) async throws -> NativeGroupInfo {
        async let summaryPayload = requestJSON(path: "/community/group/summary", params: ["groupId": String(groupID)], cookie: nil)
        async let managerPayload = requestJSON(path: "/community/group/manager-info", params: ["groupId": String(groupID)], cookie: nil)

        let summaryAny = try await summaryPayload
        let managerAny = try await managerPayload
        let summary = summaryAny as? [String: Any] ?? [:]
        let managerInfo = managerAny as? [String: Any] ?? [:]
        let leader = ((managerInfo["groupLeaderInfo"] as? [String: Any])?["leader"] as? [String: Any]) ?? [:]

        return NativeGroupInfo(
            groupID: groupID,
            groupName: nonEmptyOrNil(summary["groupName"]) ?? "",
            groupDesc: nonEmptyOrNil(summary["groupDesc"]) ?? "",
            groupRule: nonEmptyOrNil(summary["groupRule"]) ?? "",
            managerName: nonEmptyOrNil(leader["userName"]) ?? "",
            managerLabel: nonEmptyOrNil(leader["userLabel"]) ?? "",
            managerBrokerUserId: nonEmptyOrNil(leader["brokerUserId"]) ?? "",
            managerAvatarURL: nonEmptyOrNil(leader["userAvatarUrl"]) ?? "",
            source: source
        )
    }

    private func resolveGroupID(form: QueryFormState) async throws -> Int {
        if let groupID = Int(form.groupID.trimmingCharacters(in: .whitespacesAndNewlines)), groupID > 0 {
            return groupID
        }
        if let groupID = groupIDFromURL(form.groupURL) {
            return groupID
        }
        if !form.prodCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let payload = try await requestJSON(path: "/community/config", params: ["prodCode": form.prodCode], cookie: nil)
            if let config = payload as? [String: Any],
               let entrance = config["caAssetDetailEntrance"] as? [String: Any],
               let groupID = groupIDFromURL(normalizedString(entrance["communityUrl"])) {
                return groupID
            }
        }
        if !form.managerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let target = form.managerName.lowercased()
            for page in 1...10 {
                let payload = try await requestJSON(path: "/community/group/awesome-list", params: ["page": String(page), "size": "50"], cookie: nil)
                guard let object = payload as? [String: Any], let groups = object["data"] as? [[String: Any]], !groups.isEmpty else {
                    break
                }
                for group in groups {
                    let groupID = positiveInt(group["groupId"], fallback: 0)
                    guard groupID > 0 else { continue }
                    let managerPayload = try await requestJSON(path: "/community/group/manager-info", params: ["groupId": String(groupID)], cookie: nil)
                    let leader = (((managerPayload as? [String: Any])?["groupLeaderInfo"] as? [String: Any])?["leader"] as? [String: Any]) ?? [:]
                    if normalizedString(leader["userName"]).lowercased().contains(target) {
                        return groupID
                    }
                }
            }
        }
        throw NativeQiemanError.missingGroup
    }

    private func resolvedGroupSource(form: QueryFormState, groupID: Int) -> String {
        if Int(form.groupID.trimmingCharacters(in: .whitespacesAndNewlines)) == groupID {
            return "group-id"
        }
        if groupIDFromURL(form.groupURL) == groupID {
            return "group-url"
        }
        if !form.prodCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "prod-code:\(form.prodCode)"
        }
        if !form.managerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "manager-name:\(form.managerName)"
        }
        return "native"
    }

    private func requestJSON(path: String, params: [String: String], cookie: String?) async throws -> Any {
        try await requestJSONInternal(path: path, params: params, cookie: cookie)
    }

    private func requestJSONInternal(path: String, params: [String: String], cookie: String?) async throws -> Any {
        let queryItems = params.compactMap { key, value -> URLQueryItem? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : URLQueryItem(name: key, value: trimmed)
        }
        var components = URLComponents(url: baseURL.appendingPathComponent(apiBase + path), resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else {
            throw NativeQiemanError.invalidResponse
        }

        let pathWithQuery = apiBase + path + (components?.percentEncodedQuery.map { "?\($0)" } ?? "")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(makeXSign(), forHTTPHeaderField: "x-sign")
        request.setValue(makeXRequestID(pathWithQuery: pathWithQuery), forHTTPHeaderField: "x-request-id")
        request.setValue(anonymousID, forHTTPHeaderField: "sensors-anonymous-id")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NativeQiemanError.invalidResponse
        }
        let payload = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
        if !(200..<300).contains(http.statusCode) {
            throw NativeQiemanError.api(buildErrorMessage(from: payload, statusCode: http.statusCode))
        }
        if let object = payload as? [String: Any] {
            let code = normalizedString(object["code"])
            if !code.isEmpty, code != "0", code != "200" {
                throw NativeQiemanError.api(buildErrorMessage(from: payload, statusCode: http.statusCode))
            }
        }
        return payload
    }

    private func buildErrorMessage(from payload: Any, statusCode: Int) -> String {
        if let object = payload as? [String: Any] {
            let detail = object["detail"] as? [String: Any]
            let detailMessage = normalizedString(detail?["msg"]) + normalizedString(detail?["message"])
            let message = firstNonEmpty([
                normalizedString(object["msg"]),
                normalizedString(object["message"]),
                detailMessage,
            ])
            return "HTTP \(statusCode) | \(message)"
        }
        return "HTTP \(statusCode)"
    }

    private func makeXSign() -> String {
        QiemanRequestSigning.makeXSign()
    }

    private func makeXRequestID(pathWithQuery: String) -> String {
        QiemanRequestSigning.makeXRequestID(prefix: "albus.", pathWithQuery: pathWithQuery, anonymousID: anonymousID)
    }

    private func extractItemsFromGroupList(_ payload: Any) -> [[String: Any]] {
        if let object = payload as? [String: Any], let items = object["data"] as? [[String: Any]] {
            return items
        }
        if let list = payload as? [[String: Any]] {
            return list
        }
        return []
    }

    private func extractItems(_ payload: Any) -> [[String: Any]] {
        if let list = payload as? [[String: Any]] {
            return list
        }
        guard let object = payload as? [String: Any] else {
            return []
        }
        for key in ["data", "content", "items", "list", "records", "rows", "recommendUserList", "result"] {
            if let list = object[key] as? [[String: Any]] {
                return list
            }
            if let nested = object[key] {
                let items = extractItems(nested)
                if !items.isEmpty {
                    return items
                }
            }
        }
        return []
    }

    private func extractCursor(_ payload: Any) -> String? {
        guard let object = payload as? [String: Any] else {
            return nil
        }
        for key in ["pageId", "nextPageId", "nextCursor", "cursor"] {
            let value = normalizedString(object[key])
            if !value.isEmpty {
                return value
            }
        }
        for key in ["data", "content", "result"] {
            if let nested = object[key], let value = extractCursor(nested) {
                return value
            }
        }
        return nil
    }

    private func parsePostItem(_ item: [String: Any], defaultGroup: NativeGroupInfo?) -> [String: Any] {
        let content = item["content"] as? [String: Any] ?? [:]
        let groupInfo = item["groupInfo"] as? [String: Any] ?? [:]
        let contents = content["contents"] as? [[String: Any]] ?? []
        let postID = positiveInt(firstNonNil(item["id"], item["postId"]), fallback: 0)
        let brokerUserID = normalizedString(item["brokerUserId"])
        let defaultGroupID = defaultGroup?.groupID ?? 0
        let defaultGroupName = defaultGroup?.groupName ?? ""
        let defaultManagerName = defaultGroup?.managerName ?? ""
        let defaultManagerID = defaultGroup?.managerBrokerUserId ?? ""

        return [
            "group_id": positiveInt(groupInfo["groupId"], fallback: defaultGroupID),
            "group_name": firstNonEmpty([
                normalizedString(groupInfo["groupName"]),
                defaultGroupName,
            ]),
            "post_id": postID,
            "broker_user_id": brokerUserID,
            "user_name": firstNonEmpty([
                normalizedString(item["userName"]),
                brokerUserID == defaultManagerID ? defaultManagerName : "",
            ]),
            "user_label": normalizedString(item["userLabel"]),
            "created_at": normalizedString(item["createdAt"]),
            "title": firstNonEmpty([
                normalizedString(content["title"]),
                normalizedString(item["title"]),
            ]),
            "intro": firstNonEmpty([
                normalizedString(content["intro"]),
                normalizedString(item["intro"]),
            ]),
            "content_text": firstNonEmpty([
                stripPostContent(contents),
                normalizedString(item["richContent"]),
            ]),
            "like_count": positiveInt(item["likeNum"], fallback: 0),
            "comment_count": positiveInt(item["commentNum"], fallback: 0),
            "collection_count": positiveInt(item["collectionCount"], fallback: 0),
            "post_type": positiveInt(firstNonNil(item["type"], item["postType"]), fallback: 0),
            "detail_url": firstNonEmpty([
                normalizedString(item["url"]),
                "https://qieman.com/content/post-detail/\(postID)",
            ]),
        ]
    }

    private func unwrapUserPayload(_ payload: Any) -> [String: Any] {
        guard let object = payload as? [String: Any] else {
            return [:]
        }
        for key in ["data", "userInfo", "user"] {
            if let nested = object[key] as? [String: Any] {
                return nested
            }
        }
        return object
    }

    private func unwrapFirstObject(_ payload: Any, keys: [String]) -> [String: Any] {
        guard let object = payload as? [String: Any] else {
            return [:]
        }
        for key in keys {
            if let nested = object[key] as? [String: Any] {
                return nested
            }
        }
        return object
    }

    private func groupDictionary(_ group: NativeGroupInfo) -> [String: Any] {
        [
            "group_id": group.groupID,
            "group_name": group.groupName,
            "group_desc": group.groupDesc,
            "group_rule": group.groupRule,
            "manager_name": group.managerName,
            "manager_label": group.managerLabel,
            "manager_broker_user_id": group.managerBrokerUserId,
            "manager_avatar_url": group.managerAvatarURL,
            "source": group.source,
        ]
    }

    private func stripPostContent(_ contents: [[String: Any]]) -> String {
        contents.compactMap { item in
            let detail = normalizedString(item["detail"])
            return detail.isEmpty ? nil : detail
        }.joined(separator: "\n\n")
    }

    private func normalizeComment(_ item: [String: Any]) -> CommentPayload {
        let children = (item["children"] as? [[String: Any]] ?? []).map(normalizeComment)
        return CommentPayload(
            id: positiveInt(item["id"], fallback: 0),
            postId: optionalPositiveInt(item["postId"]),
            userName: firstNonEmpty([
                normalizedString(item["userName"]),
                normalizedString(item["brokerUserId"]),
            ]),
            userAvatarUrl: nonEmptyOrNil(item["userAvatarUrl"]),
            brokerUserId: nonEmptyOrNil(item["brokerUserId"]),
            content: nonEmptyOrNil(item["content"]),
            createdAt: nonEmptyOrNil(item["createdAt"]),
            likeCount: optionalPositiveInt(item["likeNum"]) ?? 0,
            replyCount: optionalPositiveInt(item["commentNum"]) ?? 0,
            ipLocation: nonEmptyOrNil(item["ipLocation"]),
            toUserName: nonEmptyOrNil(item["toUserName"]),
            children: children
        )
    }

    private func commentThreadHasBrokerUser(_ comment: CommentPayload, target: String) -> Bool {
        if normalizedString(comment.brokerUserId) == target {
            return true
        }
        return comment.children.contains { commentThreadHasBrokerUser($0, target: target) }
    }

    private func postMatchesFilters(post: [String: Any], keyword: String, since: String, until: String, userName: String?) -> Bool {
        let keywordFilter = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !keywordFilter.isEmpty {
            let haystack = [
                normalizedString(post["title"]),
                normalizedString(post["intro"]),
                normalizedString(post["content_text"]),
            ].joined(separator: "\n").lowercased()
            if !haystack.contains(keywordFilter) {
                return false
            }
        }

        if let userName, !userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !normalizedString(post["user_name"]).lowercased().contains(userName.lowercased()) {
                return false
            }
        }

        let createdAt = normalizedString(post["created_at"])
        if let sinceKey = parseDateKey(since), let createdKey = parseDateKey(createdAt), createdKey < sinceKey {
            return false
        }
        if let untilKey = parseDateKey(until), let createdKey = parseDateKey(createdAt), createdKey > untilKey {
            return false
        }
        return true
    }

    private func parseDateKey(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let text = trimmed.count >= 10 ? String(trimmed.prefix(10)) : trimmed
        let digits = text.replacingOccurrences(of: "-", with: "")
        return Int(digits)
    }

    private static let fileStemFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd-HHmmss-SSSSSS"
        return f
    }()

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    private func timestampString() -> String {
        Self.fileStemFormatter.string(from: Date())
    }

    private func isoTimestampNow() -> String {
        Self.isoFormatter.string(from: Date())
    }

    private func groupIDFromURL(_ value: String) -> Int? {
        let pattern = #"group-detail/(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(location: 0, length: value.utf16.count)
        guard let match = regex.firstMatch(in: value, range: range), match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return Int(value[swiftRange])
    }

    private func safeFileStem(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "qieman-native" }
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = trimmed.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.replacingOccurrences(of: "\n", with: "-")
    }

    private func positiveInt(_ value: Any?, fallback: Int) -> Int {
        if let number = value as? NSNumber {
            return number.intValue > 0 ? number.intValue : fallback
        }
        if let string = value as? String, let intValue = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return intValue > 0 ? intValue : fallback
        }
        return fallback
    }

    private func optionalPositiveInt(_ value: Any?) -> Int? {
        let number = positiveInt(value, fallback: 0)
        return number > 0 ? number : nil
    }

    private func normalizedString(_ value: Any?) -> String {
        QiemanText.normalizedString(value)
    }

    private func nonEmptyOrNil(_ value: Any?) -> String? {
        let text = normalizedString(value)
        return text.isEmpty ? nil : text
    }

    private func firstNonEmpty(_ values: [String]) -> String {
        values.first(where: { !$0.isEmpty }) ?? ""
    }

    private func firstNonNil(_ values: Any?...) -> Any? {
        values.first { $0 != nil && !($0 is NSNull) } ?? nil
    }

    private func stringMap(_ pairs: (String, String?)...) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in pairs {
            guard let value, !value.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    private func stringAnyMap(_ pairs: (String, Any?)...) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in pairs {
            guard let value else { continue }
            if let text = value as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    result[key] = trimmed
                }
            } else {
                result[key] = value
            }
        }
        return result
    }

    private static func sha256Hex(_ value: String) -> String {
        QiemanRequestSigning.sha256Hex(value)
    }
}

private struct NativeGroupInfo {
    let groupID: Int
    let groupName: String
    let groupDesc: String
    let groupRule: String
    let managerName: String
    let managerLabel: String
    let managerBrokerUserId: String
    let managerAvatarURL: String
    let source: String
}
