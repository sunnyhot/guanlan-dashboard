import Foundation

struct SnapshotPayload: Decodable, Identifiable, Hashable {
    let fileName: String?
    let filePath: String?
    let snapshotType: String
    let kindLabel: String?
    let mode: String
    let title: String
    let subtitle: String
    let createdAt: String
    let count: Int
    let filters: [String: String]?
    let group: GroupPayload?
    let meta: SnapshotMetaPayload?
    let stats: SnapshotStatsPayload?
    let records: [SnapshotRecordPayload]

    var id: String {
        fileName ?? "\(title)-\(createdAt)"
    }

    var displayTitle: String {
        title.isEmpty ? "未命名结果" : title
    }
}

struct GroupPayload: Decodable, Hashable {
    let groupId: Int?
    let groupName: String?
    let managerName: String?
    let managerBrokerUserId: String?
}

struct SnapshotMetaPayload: Decodable, Hashable {
    let mode: String?
}

struct SnapshotStatsPayload: Decodable, Hashable {
    let count: Int?
    let latestCreatedAt: String?
    let oldestCreatedAt: String?
    let uniqueUsers: Int?
    let uniqueGroups: Int?
    let totalLikes: Int?
    let totalComments: Int?
    let byDay: [DayBucketPayload]?
}

struct DayBucketPayload: Decodable, Hashable, Identifiable {
    let date: String
    let count: Int

    var id: String { date }
}

struct SnapshotRecordPayload: Decodable, Hashable, Identifiable {
    let groupId: Int?
    let groupName: String?
    let postId: Int?
    let brokerUserId: String?
    let spaceUserId: String?
    let userName: String?
    let userLabel: String?
    let userDesc: String?
    let createdAt: String?
    let managerName: String?
    let managerLabel: String?
    let groupDesc: String?
    let title: String?
    let intro: String?
    let contentText: String?
    let likeCount: Int?
    let commentCount: Int?
    let collectionCount: Int?
    let detailUrl: String?

    var id: String {
        if let postId, postId > 0 {
            return String(postId)
        }
        return firstNonEmpty([spaceUserId, brokerUserId, groupName, titleText, createdAt]) ?? "snapshot-record"
    }

    var titleText: String {
        let text = firstNonEmpty([
            plainText(title),
            plainText(intro),
            headlineText(from: plainText(contentText)),
            plainText(userName),
            plainText(groupName),
            plainText(managerName),
            plainText(brokerUserId),
        ]) ?? "未命名记录"
        return text.replacingOccurrences(of: "\n", with: " ")
    }

    var bodyText: String {
        firstNonEmpty([
            plainText(contentText),
            plainText(intro),
            plainText(userDesc),
            plainText(groupDesc),
            plainText(userLabel),
            plainText(managerLabel),
        ]) ?? "无正文"
    }

    var metaText: String? {
        let value = [
            createdAt,
            userLabel,
            managerName.map { "主理人 \($0)" },
            groupName,
            brokerUserId.map { "broker \($0)" },
            spaceUserId.map { "space \($0)" },
        ]
        .compactMap { item -> String? in
            guard let item = item?.trimmingCharacters(in: .whitespacesAndNewlines), !item.isEmpty else {
                return nil
            }
            return item
        }
        .joined(separator: " · ")
        return value.isEmpty ? nil : value
    }

    var interactionText: String? {
        let parts = [
            likeCount.map { "赞 \($0)" },
            commentCount.map { "评 \($0)" },
            collectionCount.map { "藏 \($0)" },
        ]
        .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func firstNonEmpty(_ values: [String?]) -> String? {
        values.first(where: { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) ?? nil
    }

    private func headlineText(from value: String?) -> String? {
        guard let value else { return nil }
        let firstLine = value
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
        guard !firstLine.isEmpty else { return nil }

        let sentenceEnders: [Character] = ["。", "！", "？", "；"]
        if let endIndex = firstLine.firstIndex(where: { sentenceEnders.contains($0) }) {
            return String(firstLine[...endIndex])
        }
        if firstLine.count > 56 {
            return String(firstLine.prefix(56)) + "..."
        }
        return firstLine
    }

    private func plainText(_ value: String?) -> String? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }

        text = decodeCommonHTMLEntities(text)
        text = text
            .replacingOccurrences(of: #"(?i)<\s*br\s*/?\s*>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</\s*(p|div|li|h[1-6]|blockquote)\s*>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<\s*(p|div|li|h[1-6]|blockquote)[^>]*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<img[^>]*>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)

        text = decodeCommonHTMLEntities(text)
            .replacingOccurrences(of: "\u{00a0}", with: " ")

        let lines = text
            .components(separatedBy: .newlines)
            .map {
                $0
                    .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        let cleaned = lines.joined(separator: "\n\n")
        return cleaned.isEmpty ? nil : cleaned
    }

    private func decodeCommonHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}
