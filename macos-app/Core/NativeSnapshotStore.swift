import Foundation

struct NativeSnapshotStore {
    func snapshot(from raw: Any, fileURL: URL, createdAt: String? = nil, includeRecords: Bool) -> SnapshotPayload {
        normalizeSnapshot(raw: raw, fileURL: fileURL, createdAt: createdAt ?? formatNow(), includeRecords: includeRecords)
    }

    private func normalizeSnapshot(raw: Any, fileURL: URL, createdAt: String, includeRecords: Bool) -> SnapshotPayload {
        if let object = raw as? [String: Any], let posts = object["posts"] as? [[String: Any]] {
            let records = normalizePostRecords(posts)
            let groupObject = object["group"] as? [String: Any] ?? [:]
            let metaObject = object["meta"] as? [String: Any] ?? [:]
            let authUser = metaObject["auth_user"] as? [String: Any] ?? [:]
            let filters = (object["filters"] as? [String: Any]) ?? (metaObject["filters"] as? [String: Any]) ?? [:]
            let firstRecord = records.first
            let mode = normalizedString(metaObject["mode"]).isEmpty ? "group-manager" : normalizedString(metaObject["mode"])

            let titleCandidates = [
                normalizedString((metaObject["space_user"] as? [String: Any])?["user_name"]),
                normalizedString(groupObject["manager_name"]),
                normalizedString(filters["user_name"]),
                firstRecord?.userName ?? "",
                normalizedString(authUser["user_name"]),
                normalizedString(authUser["broker_user_id"]),
                normalizedString(groupObject["group_name"]),
                inferTitle(from: fileURL),
            ]
            let subtitleCandidates = [
                normalizedString(groupObject["group_name"]),
                firstRecord?.groupName ?? "",
                normalizedString(metaObject["mode"]),
                "帖子流",
            ]

            return SnapshotPayload(
                fileName: fileURL.lastPathComponent,
                filePath: fileURL.path,
                snapshotType: "posts",
                kindLabel: "帖子",
                mode: mode,
                title: firstNonEmpty(titleCandidates) ?? inferTitle(from: fileURL),
                subtitle: firstNonEmpty(subtitleCandidates) ?? "帖子流",
                createdAt: createdAt,
                count: records.count,
                filters: normalizeStringMap(filters),
                group: normalizeGroup(groupObject),
                meta: SnapshotMetaPayload(mode: mode),
                stats: buildPostStats(records),
                records: includeRecords ? records : []
            )
        }

        return SnapshotPayload(
            fileName: fileURL.lastPathComponent,
            filePath: fileURL.path,
            snapshotType: "unknown",
            kindLabel: "未知",
            mode: "unknown",
            title: inferTitle(from: fileURL),
            subtitle: "未识别结构",
            createdAt: createdAt,
            count: 0,
            filters: [:],
            group: nil,
            meta: SnapshotMetaPayload(mode: "unknown"),
            stats: SnapshotStatsPayload(
                count: 0,
                latestCreatedAt: nil,
                oldestCreatedAt: nil,
                uniqueUsers: nil,
                uniqueGroups: nil,
                totalLikes: nil,
                totalComments: nil,
                byDay: nil
            ),
            records: []
        )
    }

    private func normalizePostRecords(_ records: [[String: Any]]) -> [SnapshotRecordPayload] {
        records.map(buildRecord).sorted {
            normalizedString($0.createdAt) > normalizedString($1.createdAt)
        }
    }

    private func buildRecord(_ object: [String: Any]) -> SnapshotRecordPayload {
        SnapshotRecordPayload(
            groupId: intValue(object["group_id"]),
            groupName: optionalString(object["group_name"]),
            postId: intValue(object["post_id"]),
            brokerUserId: optionalString(object["broker_user_id"]),
            spaceUserId: optionalString(object["space_user_id"]),
            userName: firstNonEmpty([
                normalizedString(object["user_name"]),
                normalizedString(object["author"]),
            ]),
            userLabel: optionalString(object["user_label"]),
            userDesc: optionalString(object["user_desc"]),
            createdAt: firstNonEmpty([
                normalizedString(object["created_at"]),
                normalizedString(object["publish_date"]),
            ]),
            managerName: optionalString(object["manager_name"]),
            managerLabel: optionalString(object["manager_label"]),
            groupDesc: optionalString(object["group_desc"]),
            title: optionalString(object["title"]),
            intro: firstNonEmpty([
                normalizedString(object["intro"]),
                normalizedString(object["snippet"]),
            ]),
            contentText: firstNonEmpty([
                normalizedString(object["content_text"]),
                normalizedString(object["content"]),
            ]),
            likeCount: intValue(firstNonNil(object["like_count"], object["likes"])),
            commentCount: intValue(firstNonNil(object["comment_count"], object["comments"])),
            collectionCount: intValue(object["collection_count"]),
            detailUrl: firstNonEmpty([
                normalizedString(object["detail_url"]),
                normalizedString(object["url"]),
            ])
        )
    }

    private func buildPostStats(_ records: [SnapshotRecordPayload]) -> SnapshotStatsPayload {
        let byDay = buildByDay(records)
        let users: Set<String> = Set(records.compactMap { record in
            guard let value = record.userName?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            return value
        })
        let groups: Set<String> = Set(records.compactMap { record in
            guard let value = record.groupName?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            return value
        })
        let latestCreatedAt = records.first?.createdAt
        let oldestCreatedAt = records.last?.createdAt

        return SnapshotStatsPayload(
            count: records.count,
            latestCreatedAt: latestCreatedAt,
            oldestCreatedAt: oldestCreatedAt,
            uniqueUsers: users.count,
            uniqueGroups: groups.count,
            totalLikes: records.compactMap(\.likeCount).reduce(0, +),
            totalComments: records.compactMap(\.commentCount).reduce(0, +),
            byDay: byDay.isEmpty ? nil : byDay
        )
    }

    private func buildByDay(_ records: [SnapshotRecordPayload]) -> [DayBucketPayload] {
        var buckets: [String: Int] = [:]
        for record in records {
            let date = normalizedDay(record.createdAt)
            guard !date.isEmpty else { continue }
            buckets[date, default: 0] += 1
        }
        return buckets.keys.sorted(by: >).map { key in
            DayBucketPayload(date: key, count: buckets[key] ?? 0)
        }
    }

    private func normalizeGroup(_ object: [String: Any]) -> GroupPayload? {
        if object.isEmpty {
            return nil
        }
        return GroupPayload(
            groupId: intValue(object["group_id"]),
            groupName: optionalString(object["group_name"]),
            managerName: optionalString(object["manager_name"]),
            managerBrokerUserId: optionalString(object["manager_broker_user_id"])
        )
    }

    private func inferTitle(from fileURL: URL) -> String {
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let parts = stem.split(separator: "-").map(String.init)
        if parts.count >= 3, Int(parts.last ?? "") != nil {
            return parts.dropLast(2).joined(separator: "-").isEmpty ? stem : parts.dropLast(2).joined(separator: "-")
        }
        if parts.count >= 2, Int(parts.last ?? "") != nil {
            return parts.dropLast(1).joined(separator: "-").isEmpty ? stem : parts.dropLast(1).joined(separator: "-")
        }
        return stem
    }

    private func formatNow() -> String {
        Self.isoDateTimeFormatter.string(from: Date())
    }

    private static let isoDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    private func normalizedDay(_ value: String?) -> String {
        let text = normalizedString(value)
        return text.count >= 10 ? String(text.prefix(10)) : text
    }

    private func normalizeStringMap(_ object: [String: Any]) -> [String: String] {
        object.reduce(into: [:]) { partialResult, item in
            let value = normalizedString(item.value)
            if !value.isEmpty {
                partialResult[item.key] = value
            }
        }
    }

    private func normalizedString(_ value: Any?) -> String {
        QiemanText.normalizedString(value)
    }

    private func optionalString(_ value: Any?) -> String? {
        let text = normalizedString(value)
        return text.isEmpty ? nil : text
    }

    private func intValue(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if value is NSNull {
            return nil
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String, let number = Int(text) {
            return number
        }
        return nil
    }

    private func firstNonEmpty(_ values: [String]) -> String? {
        values.first(where: { !$0.isEmpty })
    }

    private func firstNonNil(_ values: Any?...) -> Any? {
        values.first { $0 != nil && !($0 is NSNull) } ?? nil
    }
}
