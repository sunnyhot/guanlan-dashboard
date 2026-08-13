import CryptoKit
import Foundation

enum AlphaVantageFunction: String, Codable, Hashable, Sendable {
    case etfProfile = "ETF_PROFILE"
    case earningsCalendar = "EARNINGS_CALENDAR"
    case timeSeriesDaily = "TIME_SERIES_DAILY"
}

struct AlphaVantageRequestDescriptor: Hashable, Sendable {
    let function: AlphaVantageFunction
    let symbol: String
    let parameters: [String: String]
    let cacheTTL: TimeInterval

    init(
        function: AlphaVantageFunction,
        symbol: String,
        parameters: [String: String] = [:],
        cacheTTL: TimeInterval
    ) {
        self.function = function
        self.symbol = symbol
        self.parameters = parameters
        self.cacheTTL = cacheTTL
    }

    var cacheKey: String {
        let raw = (
            [("function", function.rawValue), ("symbol", symbol)]
                + parameters.sorted { $0.key < $1.key }
        )
        .map { "\($0.0)=\($0.1)" }
        .joined(separator: "&")
        return SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum AlphaVantageClientError: LocalizedError, Equatable {
    case invalidURL
    case invalidHTTPStatus(Int)
    case serviceMessage(String)
    case invalidResponse(String)
    case dailyBudgetExceeded(limit: Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Alpha Vantage 请求地址无效"
        case .invalidHTTPStatus(let status):
            return "Alpha Vantage 返回 HTTP \(status)"
        case .serviceMessage(let message):
            return "Alpha Vantage：\(message)"
        case .invalidResponse(let message):
            return "Alpha Vantage 数据结构无效：\(message)"
        case .dailyBudgetExceeded(let limit):
            return "Alpha Vantage 今日联网额度已用完（\(limit) 次）；缓存仍可继续使用"
        }
    }
}

protocol AlphaVantageClientProtocol: Sendable {
    func fetch(
        _ descriptor: AlphaVantageRequestDescriptor,
        settings: AlphaVantageSettings
    ) async throws -> Data
}

struct AlphaVantageClient: AlphaVantageClientProtocol, Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch(
        _ descriptor: AlphaVantageRequestDescriptor,
        settings: AlphaVantageSettings
    ) async throws -> Data {
        var components = URLComponents(string: "https://www.alphavantage.co/query")
        var queryItems = [
            URLQueryItem(name: "function", value: descriptor.function.rawValue),
            URLQueryItem(name: "symbol", value: descriptor.symbol),
            URLQueryItem(name: "apikey", value: settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        ]
        queryItems.append(contentsOf: descriptor.parameters.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        })
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw AlphaVantageClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json,text/csv;q=0.9", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AlphaVantageClientError.invalidResponse("缺少 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AlphaVantageClientError.invalidHTTPStatus(http.statusCode)
        }
        try Self.validateServiceResponse(data)
        return data
    }

    private static func validateServiceResponse(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // CSV 是 EARNINGS_CALENDAR 的正常返回格式。
            guard !data.isEmpty else {
                throw AlphaVantageClientError.invalidResponse("响应为空")
            }
            return
        }
        for key in ["Error Message", "Information", "Note"] {
            if let message = object[key] as? String, !message.isEmpty {
                throw AlphaVantageClientError.serviceMessage(message)
            }
        }
    }
}

protocol AlphaVantageDailyBudgetProtocol: Sendable {
    func consume(limit: Int, now: Date) async throws
    func remaining(limit: Int, now: Date) async -> Int
}

actor AlphaVantageDailyBudget: AlphaVantageDailyBudgetProtocol {
    private struct State: Codable {
        let day: String
        let count: Int
    }

    static let shared = AlphaVantageDailyBudget()

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "qieman.dashboard.alphaVantageDailyBudget"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func consume(limit: Int, now: Date = Date()) throws {
        let normalizedLimit = max(1, limit)
        let day = Self.dayFormatter.string(from: now)
        let state = load()
        let count = state?.day == day ? state?.count ?? 0 : 0
        guard count < normalizedLimit else {
            throw AlphaVantageClientError.dailyBudgetExceeded(limit: normalizedLimit)
        }
        save(State(day: day, count: count + 1))
    }

    func remaining(limit: Int, now: Date = Date()) -> Int {
        let normalizedLimit = max(1, limit)
        let day = Self.dayFormatter.string(from: now)
        let state = load()
        let count = state?.day == day ? state?.count ?? 0 : 0
        return max(0, normalizedLimit - count)
    }

    private func load() -> State? {
        defaults.data(forKey: storageKey).flatMap {
            try? JSONDecoder().decode(State.self, from: $0)
        }
    }

    private func save(_ state: State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

struct AlphaVantageCacheOutcome: Sendable {
    let data: Data
    let cacheHit: Bool
}

actor AlphaVantageResponseCache {
    static let shared = AlphaVantageResponseCache()

    private let directory: URL
    private let budget: any AlphaVantageDailyBudgetProtocol
    private let fileManager: FileManager

    init(
        directory: URL? = nil,
        budget: any AlphaVantageDailyBudgetProtocol = AlphaVantageDailyBudget.shared,
        fileManager: FileManager = .default
    ) {
        self.directory = directory ?? Self.defaultDirectory(fileManager: fileManager)
        self.budget = budget
        self.fileManager = fileManager
    }

    func fetch(
        _ descriptor: AlphaVantageRequestDescriptor,
        settings: AlphaVantageSettings,
        client: any AlphaVantageClientProtocol,
        now: Date = Date()
    ) async throws -> AlphaVantageCacheOutcome {
        let fileURL = directory
            .appendingPathComponent(descriptor.cacheKey, isDirectory: false)
            .appendingPathExtension("cache")
        if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
           let modifiedAt = attributes[.modificationDate] as? Date,
           now.timeIntervalSince(modifiedAt) <= descriptor.cacheTTL,
           let data = try? Data(contentsOf: fileURL),
           !data.isEmpty {
            return AlphaVantageCacheOutcome(data: data, cacheHit: true)
        }

        try await budget.consume(
            limit: settings.normalizedDailyRequestLimit,
            now: now
        )
        let data = try await client.fetch(descriptor, settings: settings)
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try data.write(to: fileURL, options: .atomic)
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            // 缓存写入失败不应让已经成功的网络响应失效。
        }
        return AlphaVantageCacheOutcome(data: data, cacheHit: false)
    }

    func remainingBudget(
        settings: AlphaVantageSettings,
        now: Date = Date()
    ) async -> Int {
        await budget.remaining(
            limit: settings.normalizedDailyRequestLimit,
            now: now
        )
    }

    private static func defaultDirectory(fileManager: FileManager) -> URL {
        let base: URL
        if let customPath = UserDefaults.standard.string(
            forKey: AppStorageKey.customDataDirectory
        ), !customPath.isEmpty {
            base = URL(fileURLWithPath: customPath, isDirectory: true)
        } else {
            base = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first?.appendingPathComponent("QiemanDashboard", isDirectory: true)
                ?? fileManager.temporaryDirectory
        }
        return base.appendingPathComponent(
            "alpha-vantage-cache",
            isDirectory: true
        )
    }
}
