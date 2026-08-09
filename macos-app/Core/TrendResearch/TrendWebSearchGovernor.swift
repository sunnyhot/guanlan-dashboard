import CryptoKit
import Foundation

/// 单次 web_search 的执行结果。`cacheHit` 用于区分模型工具调用与真实 Tavily 请求，
/// 只有后者消耗本次运行的联网搜索预算。
struct TrendWebSearchOutcome: Sendable {
    let response: TavilySearchResponse
    let cacheHit: Bool
    let remainingNetworkSearches: Int
}

struct TrendWebSearchGovernorStatus: Sendable, Equatable {
    let networkSearchesUsed: Int
    let cacheHits: Int
    let maxNetworkSearches: Int

    var remainingNetworkSearches: Int {
        max(0, maxNetworkSearches - networkSearchesUsed)
    }
}

enum TrendWebSearchGovernorError: Error, LocalizedError {
    case budgetExhausted(limit: Int)

    var errorDescription: String? {
        switch self {
        case .budgetExhausted(let limit):
            return "本次分析的 Tavily 实际请求已达到 \(limit) 次上限。已有证据应优先用于形成结论；如仍缺少本地数据，可继续调用持仓或行情工具，随后提交报告。"
        }
    }
}

/// App 生命周期内共享的 Tavily 响应缓存。
///
/// Key 会规范化查询文本、域名顺序和 API Key 指纹；不持久化 API Key，也不把它写入日志。
/// 缓存只减少重复请求，不替代 Agent 对搜索主题和后续工具的自主选择。
actor TrendWebSearchResponseCache {
    static let shared = TrendWebSearchResponseCache(
        storageDirectory: defaultStorageDirectory()
    )

    private struct Key: Codable, Hashable, Sendable {
        let apiKeyDigest: String
        let query: String
        let topic: String
        let searchDepth: String
        let maxResults: Int
        let timeRange: String?
        let includeDomains: [String]
        let includeAnswer: Bool
        let includeRawContent: Bool
        let includeImages: Bool
    }

    private struct Entry: Codable, Sendable {
        let response: TavilySearchResponse
        let expiresAt: Date
        let insertedAt: Date
    }

    private struct CacheDocument: Codable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let key: Key
        let entry: Entry
    }

    private var entries: [Key: Entry]
    private let ttlSeconds: TimeInterval
    private let maxEntries: Int
    private let storageDirectory: URL?
    private let fileManager: FileManager

    init(
        ttlSeconds: TimeInterval = 6 * 60 * 60,
        maxEntries: Int = 64,
        storageDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.ttlSeconds = max(60, ttlSeconds)
        self.maxEntries = max(8, maxEntries)
        self.storageDirectory = storageDirectory
        self.fileManager = fileManager
        self.entries = Self.loadEntries(
            from: storageDirectory,
            maxEntries: max(8, maxEntries),
            now: Date(),
            fileManager: fileManager
        )
    }

    func value(
        for request: TavilySearchRequest,
        apiKey: String,
        maxAgeSeconds: TimeInterval? = nil,
        now: Date = Date()
    ) -> TavilySearchResponse? {
        pruneExpired(now: now)
        guard let entry = entries[Self.key(for: request, apiKey: apiKey)] else {
            return nil
        }
        let allowedAge = max(60, maxAgeSeconds ?? ttlSeconds)
        guard now.timeIntervalSince(entry.insertedAt) <= allowedAge else {
            return nil
        }
        return entry.response
    }

    func store(
        _ response: TavilySearchResponse,
        for request: TavilySearchRequest,
        apiKey: String,
        ttlSeconds entryTTLSeconds: TimeInterval? = nil,
        now: Date = Date()
    ) {
        pruneExpired(now: now)
        let key = Self.key(for: request, apiKey: apiKey)
        if entries[key] == nil,
           entries.count >= maxEntries,
           let oldest = entries.min(by: { $0.value.insertedAt < $1.value.insertedAt })?.key {
            entries.removeValue(forKey: oldest)
            removePersistedEntry(for: oldest)
        }
        let entry = Entry(
            response: response,
            expiresAt: now.addingTimeInterval(max(60, entryTTLSeconds ?? ttlSeconds)),
            insertedAt: now
        )
        entries[key] = entry
        persist(entry, for: key)
    }

    private func pruneExpired(now: Date) {
        let expiredKeys = entries.compactMap { key, entry in
            entry.expiresAt <= now ? key : nil
        }
        for key in expiredKeys {
            entries.removeValue(forKey: key)
            removePersistedEntry(for: key)
        }
    }

    private func persist(_ entry: Entry, for key: Key) {
        guard let fileURL = Self.fileURL(for: key, in: storageDirectory) else { return }
        let document = CacheDocument(
            schemaVersion: CacheDocument.currentSchemaVersion,
            key: key,
            entry: entry
        )
        try? JSONFilePersistence.save(
            document,
            to: fileURL,
            fileManager: fileManager
        )
    }

    private func removePersistedEntry(for key: Key) {
        guard let fileURL = Self.fileURL(for: key, in: storageDirectory) else { return }
        try? JSONFilePersistence.delete(at: fileURL, fileManager: fileManager)
    }

    private static func key(for request: TavilySearchRequest, apiKey: String) -> Key {
        Key(
            apiKeyDigest: digest(apiKey),
            query: normalizedText(request.query),
            topic: request.topic.lowercased(),
            searchDepth: request.searchDepth.lowercased(),
            maxResults: request.maxResults,
            timeRange: request.timeRange?.lowercased(),
            includeDomains: (request.includeDomains ?? [])
                .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                .sorted(),
            includeAnswer: request.includeAnswer,
            includeRawContent: request.includeRawContent,
            includeImages: request.includeImages
        )
    }

    private static func normalizedText(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "zh_CN")
        )
        let allowed = CharacterSet.alphanumerics
        let separated = folded.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : " "
        }.joined()
        return separated
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func loadEntries(
        from directory: URL?,
        maxEntries: Int,
        now: Date,
        fileManager: FileManager
    ) -> [Key: Entry] {
        guard let directory,
              let fileURLs = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              )
        else {
            return [:]
        }

        var loaded: [Key: Entry] = [:]
        for fileURL in fileURLs where fileURL.pathExtension == "json" {
            let document: CacheDocument
            do {
                guard let cached = try JSONFilePersistence.load(
                    CacheDocument.self,
                    from: fileURL,
                    fileManager: fileManager
                ) else {
                    continue
                }
                document = cached
            } catch {
                try? fileManager.removeItem(at: fileURL)
                continue
            }
            guard document.schemaVersion == CacheDocument.currentSchemaVersion,
                  document.entry.expiresAt > now else {
                try? fileManager.removeItem(at: fileURL)
                continue
            }
            if let existing = loaded[document.key],
               existing.insertedAt >= document.entry.insertedAt {
                continue
            }
            loaded[document.key] = document.entry
        }

        let retained = loaded
            .sorted { $0.value.insertedAt > $1.value.insertedAt }
            .prefix(maxEntries)
        let retainedKeys = Set(retained.map(\.key))
        for key in loaded.keys where !retainedKeys.contains(key) {
            if let fileURL = fileURL(for: key, in: directory) {
                try? fileManager.removeItem(at: fileURL)
            }
        }
        return Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
    }

    private static func fileURL(for key: Key, in directory: URL?) -> URL? {
        guard let directory else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(key) else { return nil }
        let filename = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent(filename).appendingPathExtension("json")
    }

    private static func defaultStorageDirectory(
        fileManager: FileManager = .default
    ) -> URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("QiemanDashboard", isDirectory: true)
            .appendingPathComponent("AIResearch", isDirectory: true)
            .appendingPathComponent("Tavily", isDirectory: true)
    }
}

/// 单次 Agent 运行的 Tavily 治理器：共享缓存，但独立统计真实网络请求额度。
actor TrendWebSearchGovernor {
    private let maxNetworkSearches: Int
    private let cache: TrendWebSearchResponseCache
    private let cacheMaxAgeSeconds: TimeInterval?
    private var networkSearchesUsed = 0
    private var cacheHits = 0

    init(
        maxNetworkSearches: Int,
        cache: TrendWebSearchResponseCache = .shared,
        cacheMaxAgeSeconds: TimeInterval? = nil
    ) {
        self.maxNetworkSearches = max(1, maxNetworkSearches)
        self.cache = cache
        self.cacheMaxAgeSeconds = cacheMaxAgeSeconds
    }

    func search(
        _ request: TavilySearchRequest,
        apiKey: String,
        timeoutSeconds: Double,
        client: any TavilySearchClientProtocol
    ) async throws -> TrendWebSearchOutcome {
        if let response = await cache.value(
            for: request,
            apiKey: apiKey,
            maxAgeSeconds: cacheMaxAgeSeconds
        ) {
            cacheHits += 1
            return TrendWebSearchOutcome(
                response: response,
                cacheHit: true,
                remainingNetworkSearches: max(0, maxNetworkSearches - networkSearchesUsed)
            )
        }

        guard networkSearchesUsed < maxNetworkSearches else {
            throw TrendWebSearchGovernorError.budgetExhausted(limit: maxNetworkSearches)
        }

        // 发起请求即计入预算；网络失败也会消耗一次实际尝试，防止故障时无限重试。
        networkSearchesUsed += 1
        let response = try await client.search(
            request,
            apiKey: apiKey,
            timeoutSeconds: timeoutSeconds
        )
        await cache.store(
            response,
            for: request,
            apiKey: apiKey
        )
        return TrendWebSearchOutcome(
            response: response,
            cacheHit: false,
            remainingNetworkSearches: max(0, maxNetworkSearches - networkSearchesUsed)
        )
    }

    func status() -> TrendWebSearchGovernorStatus {
        TrendWebSearchGovernorStatus(
            networkSearchesUsed: networkSearchesUsed,
            cacheHits: cacheHits,
            maxNetworkSearches: maxNetworkSearches
        )
    }
}
