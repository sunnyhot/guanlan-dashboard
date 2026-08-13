import Foundation

protocol TavilySearchClientProtocol: Sendable {
    func search(
        _ searchRequest: TavilySearchRequest,
        apiKey: String,
        timeoutSeconds: Double
    ) async throws -> TavilySearchResponse
}

struct TavilySearchRequest: Encodable, Hashable, Sendable {
    let query: String
    let topic: String
    let searchDepth: String
    let maxResults: Int
    let timeRange: String?
    let includeDomains: [String]?
    let includeAnswer: Bool
    let includeRawContent: Bool
    let includeImages: Bool

    enum CodingKeys: String, CodingKey {
        case query
        case topic
        case searchDepth = "search_depth"
        case maxResults = "max_results"
        case timeRange = "time_range"
        case includeDomains = "include_domains"
        case includeAnswer = "include_answer"
        case includeRawContent = "include_raw_content"
        case includeImages = "include_images"
    }
}

struct TavilySearchResponse: Codable, Hashable, Sendable {
    let query: String?
    let results: [TavilySearchResult]
    let responseTime: String?
    let requestID: String?

    enum CodingKeys: String, CodingKey {
        case query
        case results
        case responseTime = "response_time"
        case requestID = "request_id"
    }

    init(
        query: String?,
        results: [TavilySearchResult],
        responseTime: String?,
        requestID: String?
    ) {
        self.query = query
        self.results = results
        self.responseTime = responseTime
        self.requestID = requestID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        query = try container.decodeIfPresent(String.self, forKey: .query)
        results = try container.decode([TavilySearchResult].self, forKey: .results)
        responseTime = try container.decodeStringOrNumberIfPresent(forKey: .responseTime)
        requestID = try container.decodeStringOrNumberIfPresent(forKey: .requestID)
    }
}

struct TavilySearchResult: Codable, Hashable, Sendable {
    let title: String
    let url: String
    let content: String
    let score: Double?
    let publishedDate: String?

    enum CodingKeys: String, CodingKey {
        case title
        case url
        case content
        case score
        case publishedDate = "published_date"
    }

    init(
        title: String,
        url: String,
        content: String,
        score: Double?,
        publishedDate: String?
    ) {
        self.title = title
        self.url = url
        self.content = content
        self.score = score
        self.publishedDate = publishedDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 单条结果字段异常不应让整次搜索失败；下游会过滤空标题、空正文和非法 URL。
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? ""
        url = (try? container.decodeIfPresent(String.self, forKey: .url)) ?? ""
        content = (try? container.decodeIfPresent(String.self, forKey: .content)) ?? ""
        score = try container.decodeDoubleOrStringIfPresent(forKey: .score)
        publishedDate = (try? container.decodeIfPresent(String.self, forKey: .publishedDate)) ?? nil
    }
}

enum TavilySearchClientError: Error, LocalizedError, Sendable {
    case missingAPIKey
    case invalidResponse(String)
    case requestFailed(statusCode: Int, detail: String?)
    case timedOut(Double)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "尚未配置 Tavily API Key。请在「设置 > AI 研判 > 联网搜索」中填写。"
        case .invalidResponse(let detail):
            return "Tavily 返回格式无效：\(detail)"
        case .requestFailed(let statusCode, let detail):
            let suffix = detail.map { " \($0)" } ?? ""
            if statusCode == 401 {
                return "Tavily API Key 无效或无权访问搜索服务。\(suffix)"
            }
            if [429, 432, 433].contains(statusCode) {
                return "Tavily 搜索额度或请求频率已达上限，请稍后重试。\(suffix)"
            }
            return "Tavily 搜索失败：HTTP \(statusCode)。\(suffix)"
        case .timedOut(let seconds):
            return "Tavily 搜索超时：\(Int(seconds)) 秒内未返回。"
        }
    }

    var toolErrorCode: String {
        switch self {
        case .missingAPIKey:
            return "web_search_not_configured"
        case .requestFailed(let statusCode, _):
            if statusCode == 401 { return "web_search_auth_failed" }
            if [429, 432, 433].contains(statusCode) {
                return "web_search_quota_exhausted"
            }
            return "web_search_failed"
        case .invalidResponse:
            return "web_search_invalid_response"
        case .timedOut:
            return "web_search_timed_out"
        }
    }

    var userFacingToolMessage: String {
        switch self {
        case .missingAPIKey:
            return "尚未配置 Tavily API Key，请先在 AI 研判设置中完成配置。"
        case .requestFailed(let statusCode, _):
            if statusCode == 401 {
                return "Tavily API Key 无效或无权访问；本次已停止继续搜索。"
            }
            if [429, 432, 433].contains(statusCode) {
                return "Tavily 套餐额度已用尽或达到请求限制；本次已停止继续搜索。请升级套餐、更换 API Key，或等待额度恢复。"
            }
            return "Tavily 服务暂不可用（HTTP \(statusCode)），本次已停止继续搜索。"
        case .invalidResponse:
            return "Tavily 返回数据异常，本次已停止继续搜索。"
        case .timedOut:
            return "Tavily 搜索超时，本次已停止继续搜索。"
        }
    }

    var availabilityBlockReason: TrendWebSearchAvailabilityBlockReason? {
        switch self {
        case .missingAPIKey:
            return .authentication
        case .requestFailed(let statusCode, _):
            if statusCode == 401 { return .authentication }
            if [429, 432, 433].contains(statusCode) { return .quotaOrRateLimit }
            return nil
        case .invalidResponse, .timedOut:
            return nil
        }
    }
}

struct TavilySearchClient: TavilySearchClientProtocol, Sendable {
    static let endpoint = URL(string: "https://api.tavily.com/search")!

    let session: URLSession
    private let encoder = JSONEncoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(
        _ searchRequest: TavilySearchRequest,
        apiKey: String,
        timeoutSeconds: Double = 30
    ) async throws -> TavilySearchResponse {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw TavilySearchClientError.missingAPIKey
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(searchRequest)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw TavilySearchClientError.timedOut(timeoutSeconds)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TavilySearchClientError.invalidResponse("缺少 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TavilySearchClientError.requestFailed(
                statusCode: http.statusCode,
                detail: Self.errorMessage(from: data)
            )
        }

        do {
            return try JSONDecoder().decode(TavilySearchResponse.self, from: data)
        } catch {
            throw TavilySearchClientError.invalidResponse(
                Self.decodingErrorDetail(
                    error,
                    data: data,
                    contentType: http.value(forHTTPHeaderField: "Content-Type")
                )
            )
        }
    }

    private static func decodingErrorDetail(
        _ error: Error,
        data: Data,
        contentType: String?
    ) -> String {
        let detail: String
        switch error {
        case DecodingError.typeMismatch(let type, let context):
            detail = "\(codingPath(context.codingPath)) 类型不匹配，期望 \(type)：\(context.debugDescription)"
        case DecodingError.valueNotFound(let type, let context):
            detail = "\(codingPath(context.codingPath)) 缺少 \(type) 值：\(context.debugDescription)"
        case DecodingError.keyNotFound(let key, let context):
            detail = "\(codingPath(context.codingPath + [key])) 缺少必需字段：\(context.debugDescription)"
        case DecodingError.dataCorrupted(let context):
            detail = "\(codingPath(context.codingPath)) 数据损坏：\(context.debugDescription)"
        default:
            detail = error.localizedDescription
        }

        var metadata = ["\(data.count) 字节"]
        if let contentType, !contentType.isEmpty {
            metadata.append("Content-Type=\(contentType)")
        }
        if let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any] {
            let shape = dictionary.keys.sorted().map {
                "\($0)=\(jsonTypeName(dictionary[$0]))"
            }.joined(separator: ", ")
            metadata.append("顶层字段：\(shape)")
        }
        return "\(detail)（\(metadata.joined(separator: "；"))）"
    }

    private static func codingPath(_ path: [any CodingKey]) -> String {
        guard !path.isEmpty else { return "响应根节点" }
        return path.reduce(into: "$") { value, key in
            if let index = key.intValue {
                value += "[\(index)]"
            } else {
                value += ".\(key.stringValue)"
            }
        }
    }

    private static func jsonTypeName(_ value: Any?) -> String {
        switch value {
        case nil:
            return "missing"
        case is NSNull:
            return "null"
        case is String:
            return "string"
        case is NSNumber:
            return "number"
        case is [Any]:
            return "array"
        case is [String: Any]:
            return "object"
        default:
            return String(describing: type(of: value as Any))
        }
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8).map { String($0.prefix(220)) }
        }
        if let detail = object["detail"] as? String { return detail }
        if let detail = object["detail"] as? [String: Any],
           let error = detail["error"] as? String {
            return error
        }
        if let message = object["message"] as? String { return message }
        return nil
    }
}

private extension KeyedDecodingContainer {
    func decodeStringOrNumberIfPresent(forKey key: Key) throws -> String? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let value = try? decode(String.self, forKey: key) {
            return value
        }
        if let value = try? decode(Double.self, forKey: key) {
            return String(value)
        }
        throw DecodingError.typeMismatch(
            String.self,
            DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "应为字符串或数字"
            )
        )
    }

    func decodeDoubleOrStringIfPresent(forKey key: Key) throws -> Double? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let value = try? decode(Double.self, forKey: key) {
            return value
        }
        if let value = try? decode(String.self, forKey: key),
           let number = Double(value) {
            return number
        }
        return nil
    }
}
