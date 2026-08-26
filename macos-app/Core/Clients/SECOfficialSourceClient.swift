import Foundation

struct SECRequestDescriptor: Hashable, Sendable {
    let url: URL
    let cacheTTL: TimeInterval
}

protocol SECOfficialSourceClientProtocol: Sendable {
    func fetch(
        _ descriptor: SECRequestDescriptor,
        settings: OfficialSourceSettings,
        timeoutSeconds: Double
    ) async throws -> Data
}

enum SECOfficialSourceClientError: Error, LocalizedError {
    case missingContact
    case timedOut(Double)
    case invalidResponse(String)
    case requestFailed(statusCode: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .missingContact:
            return "SEC 官方源需要联系邮箱。请在研究的官方数据源配置中填写，以符合 EDGAR 自动访问规范。"
        case .timedOut(let seconds):
            return "SEC EDGAR 请求超时：\(Int(seconds)) 秒内未返回。"
        case .invalidResponse(let detail):
            return "SEC EDGAR 返回格式无效：\(detail)"
        case .requestFailed(let statusCode, let detail):
            let suffix = detail.isEmpty ? "" : " \(detail)"
            switch statusCode {
            case 403:
                return "SEC EDGAR 拒绝了自动访问，请检查联系邮箱和访问频率。\(suffix)"
            case 429:
                return "SEC EDGAR 公平访问限流，请稍后重试。\(suffix)"
            default:
                return "SEC EDGAR 请求失败：HTTP \(statusCode)。\(suffix)"
            }
        }
    }
}

actor SECFairAccessLimiter {
    static let shared = SECFairAccessLimiter()

    /// SEC 当前上限是 10 requests/s。这里主动限制为约 5 requests/s，并在所有
    /// App 内 SEC 请求之间共享节流器，给同一出口上的其它客户端留出余量。
    private let minimumInterval: TimeInterval = 0.2
    private var lastRequestAt: Date?

    func acquire() async throws {
        if let lastRequestAt {
            let remaining = minimumInterval - Date().timeIntervalSince(lastRequestAt)
            if remaining > 0 {
                try await Task.sleep(
                    nanoseconds: UInt64(remaining * 1_000_000_000)
                )
            }
        }
        try Task.checkCancellation()
        lastRequestAt = Date()
    }
}

struct SECOfficialSourceClient: SECOfficialSourceClientProtocol, Sendable {
    let session: URLSession
    let limiter: SECFairAccessLimiter

    init(
        session: URLSession = .shared,
        limiter: SECFairAccessLimiter = .shared
    ) {
        self.session = session
        self.limiter = limiter
    }

    func fetch(
        _ descriptor: SECRequestDescriptor,
        settings: OfficialSourceSettings,
        timeoutSeconds: Double = 20
    ) async throws -> Data {
        guard settings.isSECConfigured else {
            throw SECOfficialSourceClientError.missingContact
        }

        try await limiter.acquire()
        var request = URLRequest(url: descriptor.url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutSeconds
        request.setValue(settings.secUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw SECOfficialSourceClientError.timedOut(timeoutSeconds)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SECOfficialSourceClientError.invalidResponse("缺少 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SECOfficialSourceClientError.requestFailed(
                statusCode: http.statusCode,
                detail: Self.errorMessage(from: data)
            )
        }
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw SECOfficialSourceClientError.invalidResponse("响应不是合法 JSON")
        }
        return data
    }

    private static func errorMessage(from data: Data) -> String {
        String(data: Data(data.prefix(500)), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }
}

struct SECOfficialSourceCacheOutcome: Sendable {
    let data: Data
    let cacheHit: Bool
}

actor SECOfficialSourceCache {
    static let shared = SECOfficialSourceCache()

    private struct Entry {
        let data: Data
        let expiresAt: Date
    }

    private var entries: [URL: Entry] = [:]

    func fetch(
        _ descriptor: SECRequestDescriptor,
        settings: OfficialSourceSettings,
        client: any SECOfficialSourceClientProtocol
    ) async throws -> SECOfficialSourceCacheOutcome {
        let now = Date()
        if let cached = entries[descriptor.url], cached.expiresAt > now {
            return SECOfficialSourceCacheOutcome(data: cached.data, cacheHit: true)
        }
        entries = entries.filter { $0.value.expiresAt > now }
        let data = try await client.fetch(
            descriptor,
            settings: settings,
            timeoutSeconds: 20
        )
        entries[descriptor.url] = Entry(
            data: data,
            expiresAt: now.addingTimeInterval(max(1, descriptor.cacheTTL))
        )
        return SECOfficialSourceCacheOutcome(data: data, cacheHit: false)
    }
}
