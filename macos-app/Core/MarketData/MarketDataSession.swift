import Foundation

/// 市场数据 HTTP 会话：按 host 串行限速（最小间隔+抖动）、超时、随机 UA、GBK 解码、429/5xx 有限重试。
///
/// 限速口径参考 daily_stock_analysis（MIT）`screening/snapshot.py`：东财 dataapi 类接口
/// 必须全局串行且 ≥1s 间隔（+0.3s 抖动），腾讯/新浪类轻接口 0.3s 级即可。
/// 重试仅在超时/429/5xx 时进行（total=2, backoff 0.5s 起步），4xx 直接抛错。
actor MarketDataSession {
    struct HostPolicy: Sendable {
        var minInterval: TimeInterval
        var jitter: TimeInterval
        var retryCount: Int
    }

    static let defaultPolicies: [String: HostPolicy] = [
        "qt.gtimg.cn": HostPolicy(minInterval: 0.3, jitter: 0.05, retryCount: 1),
        "web.ifzq.gtimg.cn": HostPolicy(minInterval: 0.3, jitter: 0.05, retryCount: 1),
        "hq.sinajs.cn": HostPolicy(minInterval: 0.3, jitter: 0.05, retryCount: 1),
        "vip.stock.finance.sina.com.cn": HostPolicy(minInterval: 0.35, jitter: 0.1, retryCount: 1),
        "data.eastmoney.com": HostPolicy(minInterval: 1.0, jitter: 0.3, retryCount: 2),
        "push2.eastmoney.com": HostPolicy(minInterval: 0.5, jitter: 0.1, retryCount: 1),
        "push2his.eastmoney.com": HostPolicy(minInterval: 0.5, jitter: 0.1, retryCount: 1),
    ]

    static let fallbackPolicy = HostPolicy(minInterval: 0.5, jitter: 0.1, retryCount: 1)

    static let userAgents: [String] = [
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1",
    ]

    private let urlSession: URLSession
    private let policies: [String: HostPolicy]
    private var lastRequestAt: [String: Date] = [:]
    private let now: () -> Date

    init(
        policies: [String: HostPolicy] = MarketDataSession.defaultPolicies,
        urlSession: URLSession = URLSession(configuration: .ephemeral),
        now: @escaping () -> Date = { Date() }
    ) {
        self.policies = policies
        self.urlSession = urlSession
        self.now = now
    }

    // MARK: - 公开请求入口

    /// GET 并返回解码后的文本（自动 UTF-8 → GB18030 兜底）。
    func text(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 8) async throws -> String {
        let data = try await data(url, headers: headers, timeout: timeout)
        return Self.decodeText(data)
    }

    /// GET 并返回 JSON 解析结果（JSONSerialization）。
    func json(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 8) async throws -> Any {
        let data = try await data(url, headers: headers, timeout: timeout)
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MarketDataError.invalidResponse
        }
    }

    func data(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 8) async throws -> Data {
        let host = url.host ?? ""
        let policy = policies[host] ?? Self.fallbackPolicy
        await waitTurn(host: host, policy: policy)

        var lastError: Error = MarketDataError.invalidResponse
        for attempt in 0...policy.retryCount {
            do {
                return try await performOnce(url, headers: headers, timeout: timeout)
            } catch {
                lastError = error
                guard Self.isRetriable(error), attempt < policy.retryCount else { throw error }
                try? await Task.sleep(nanoseconds: UInt64((0.5 * Double(attempt + 1)) * 1_000_000_000))
                await waitTurn(host: host, policy: policy)
            }
        }
        throw lastError
    }

    // MARK: - 内部

    private func performOnce(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(Self.userAgents.randomElement() ?? Self.userAgents[0], forHTTPHeaderField: "User-Agent")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MarketDataError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 {
                throw MarketDataError.rateLimited(status: 429)
            }
            let snippet = String(Self.decodeText(data).prefix(120))
            throw MarketDataError.badStatus(status: http.statusCode, snippet: snippet)
        }
        guard !data.isEmpty else { throw MarketDataError.emptyResponse }
        return data
    }

    /// 串行限速：距上次请求不足 minInterval（+抖动）时等待。
    private func waitTurn(host: String, policy: HostPolicy) async {
        let jitter = policy.jitter > 0 ? Double.random(in: 0...policy.jitter) : 0
        let minimum = policy.minInterval + jitter
        if let last = lastRequestAt[host] {
            let elapsed = now().timeIntervalSince(last)
            if elapsed < minimum, minimum - elapsed > 0 {
                try? await Task.sleep(nanoseconds: UInt64((minimum - elapsed) * 1_000_000_000))
            }
        }
        lastRequestAt[host] = now()
    }

    private static func isRetriable(_ error: Error) -> Bool {
        if case MarketDataError.rateLimited = error { return true }
        if case MarketDataError.badStatus(let status, _) = error {
            return [429, 500, 502, 503, 504].contains(status)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// UTF-8 优先，GB18030 兜底（腾讯/新浪行情接口为 GBK 编码）。
    static func decodeText(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        if let text = String(data: data, encoding: gb18030) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }
}
