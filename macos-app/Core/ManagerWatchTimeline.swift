import Foundation

enum ManagerWatchTimelineEventKind: String, Codable, CaseIterable, Hashable {
    case pollStarted
    case forumHit
    case platformHit
    case duplicateSuppressed
    case noUpdates
    case failed
    case recovered
}

enum ManagerWatchTimelineTone: String, Codable, Hashable {
    case info
    case positive
    case warning
}

struct ManagerWatchTimelineEvent: Codable, Identifiable, Hashable {
    let id: UUID
    let kind: ManagerWatchTimelineEventKind
    let occurredAt: Date
    let prodCode: String
    let managerName: String
    let title: String
    let detail: String
    let targetID: String?
    let errorMessage: String?

    init(
        id: UUID = UUID(),
        kind: ManagerWatchTimelineEventKind,
        occurredAt: Date = Date(),
        prodCode: String,
        managerName: String,
        title: String,
        detail: String,
        targetID: String? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.occurredAt = occurredAt
        self.prodCode = prodCode
        self.managerName = managerName
        self.title = title
        self.detail = detail
        self.targetID = targetID
        self.errorMessage = errorMessage
    }

    var tone: ManagerWatchTimelineTone {
        switch kind {
        case .forumHit, .platformHit, .recovered:
            return .positive
        case .failed:
            return .warning
        case .pollStarted, .duplicateSuppressed, .noUpdates:
            return .info
        }
    }
}

struct ManagerWatchTimelineSummary: Hashable {
    let events: [ManagerWatchTimelineEvent]
    let latestStatusText: String
    let failureCount: Int

    static func make(events: [ManagerWatchTimelineEvent]) -> ManagerWatchTimelineSummary {
        let sorted = events.sorted { left, right in
            if left.occurredAt != right.occurredAt {
                return left.occurredAt > right.occurredAt
            }
            return left.title.localizedStandardCompare(right.title) == .orderedAscending
        }
        return ManagerWatchTimelineSummary(
            events: sorted,
            latestStatusText: sorted.first?.title ?? "暂无巡检记录",
            failureCount: sorted.filter { $0.kind == .failed }.count
        )
    }
}

struct ManagerWatchTimelineStore {
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    func load(from fileURL: URL) throws -> [ManagerWatchTimelineEvent] {
        try JSONFilePersistence.load(
            [ManagerWatchTimelineEvent].self,
            from: fileURL,
            defaultValue: [],
            decoder: decoder
        )
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    func save(_ events: [ManagerWatchTimelineEvent], to fileURL: URL, now: Date = Date()) throws {
        try JSONFilePersistence.save(
            Self.pruned(events, now: now),
            to: fileURL,
            encoder: encoder
        )
    }

    func append(_ event: ManagerWatchTimelineEvent, to fileURL: URL, now: Date = Date()) throws {
        let nextEvents = try load(from: fileURL) + [event]
        try save(nextEvents, to: fileURL, now: now)
    }

    static func pruned(
        _ events: [ManagerWatchTimelineEvent],
        now: Date = Date(),
        maxCount: Int = 200,
        maxAgeDays: Int = 90
    ) -> [ManagerWatchTimelineEvent] {
        let ageLimit = now.addingTimeInterval(TimeInterval(-maxAgeDays * 24 * 60 * 60))
        return events
            .filter { $0.occurredAt >= ageLimit }
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(maxCount)
            .map { $0 }
    }
}
