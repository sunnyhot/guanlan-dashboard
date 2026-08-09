import CryptoKit
import Foundation

// MARK: - HTTP 请求与响应解析工具
//
// 从 QiemanPlatformNativeClient 主体抽出，集中托管所有数据源（基金估值 / 股票指数 /
// 平台持仓）共用的 HTTP 请求构造、请求签名、JSON/文本解析、时间格式化与数值归一化逻辑。
// 主体文件因此只保留各业务入口与平台数据装配，单文件认知负荷显著降低。
extension QiemanPlatformNativeClient {

    func requestJSON(hostURL: URL, path: String, params: [String: String], headers: [String: String]) async throws -> Any {
        var components = URLComponents(url: hostURL.appendingPathComponent(apiBase + path), resolvingAgainstBaseURL: false)
        components?.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }.sorted(by: { $0.name < $1.name })
        guard let url = components?.url else {
            throw NativePlatformError.invalidResponse
        }
        let query = components?.percentEncodedQuery.map { "?\($0)" } ?? ""
        let pathWithQuery = apiBase + path + query

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(makeXSign(), forHTTPHeaderField: "x-sign")
        request.setValue(makeXRequestID(pathWithQuery: pathWithQuery), forHTTPHeaderField: "x-request-id")
        request.setValue(anonymousID, forHTTPHeaderField: "sensors-anonymous-id")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NativePlatformError.invalidResponse
        }
        let payload = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
        if !(200..<300).contains(http.statusCode) {
            throw NativePlatformError.api(buildErrorMessage(payload, statusCode: http.statusCode))
        }
        if let object = payload as? [String: Any] {
            let code = normalizedString(object["code"])
            if !code.isEmpty, code != "0", code != "200" {
                throw NativePlatformError.api(buildErrorMessage(payload, statusCode: http.statusCode))
            }
        }
        return payload
    }

    func requestText(absoluteURL: URL, headers: [String: String]) async throws -> String {
        var request = URLRequest(url: absoluteURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NativePlatformError.invalidResponse
        }
        return decodeResponseText(data)
    }

    func buildErrorMessage(_ payload: Any, statusCode: Int) -> String {
        if let object = payload as? [String: Any] {
            let detail = object["detail"] as? [String: Any]
            let detailMessage = firstNonEmpty([normalizedString(detail?["msg"]), normalizedString(detail?["message"])])
            let message = firstNonEmpty([normalizedString(object["msg"]), normalizedString(object["message"]), detailMessage, "请求失败"])
            return "HTTP \(statusCode) | \(message)"
        }
        return "HTTP \(statusCode)"
    }

    func makeXSign() -> String {
        QiemanRequestSigning.makeXSign()
    }

    func makeXRequestID(pathWithQuery: String) -> String {
        QiemanRequestSigning.makeXRequestID(prefix: "albus.", pathWithQuery: pathWithQuery, anonymousID: anonymousID)
    }

    static func sha256Hex(_ value: String) -> String {
        QiemanRequestSigning.sha256Hex(value)
    }

    func normalizedString(_ value: Any?) -> String {
        QiemanText.normalizedString(value)
    }

    func firstNonEmpty(_ values: [String]) -> String {
        values.first(where: { !$0.isEmpty }) ?? ""
    }

    func intValue(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    func doubleValue(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    func scaledQuoteValue(_ value: Any?, scale: Double) -> Double? {
        guard let raw = doubleValue(value), scale > 0 else { return nil }
        return raw / scale
    }

    func stockSecID(for stockCode: String, market: StockMarket? = nil) -> String? {
        let code = stockCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMarket = market ?? UserPortfolioHolding.detectStockMarket(from: code)
        guard resolvedMarket == nil || resolvedMarket == .aShare else { return nil }
        guard code.count == 6, CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: code)) else {
            return nil
        }
        if code.hasPrefix("5") || code.hasPrefix("6") || code.hasPrefix("9") {
            return "1.\(code)"
        }
        return "0.\(code)"
    }

    func tencentStockSymbol(for stockCode: String, market: StockMarket? = nil) -> String? {
        let code = stockCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMarket = market ?? UserPortfolioHolding.detectStockMarket(from: code)

        switch resolvedMarket {
        case .aShare:
            guard code.count == 6, code.allSatisfy(\.isNumber) else { return nil }
            if code.hasPrefix("5") || code.hasPrefix("6") || code.hasPrefix("9") {
                return "sh\(code)"
            }
            if code.hasPrefix("4") || code.hasPrefix("8") {
                return "bj\(code)"
            }
            return "sz\(code)"
        case .hk:
            return "hk\(code)"
        case .us:
            return "us\(code.uppercased())"
        case nil:
            return nil
        }
    }

    func formattedTencentQuoteTime(_ value: String?) -> String {
        let raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.count >= 10, raw.dropFirst(4).first == "-" {
            return String(raw.prefix(19))
        }
        guard raw.count >= 14 else { return raw }
        let year = raw.prefix(4)
        let month = raw.dropFirst(4).prefix(2)
        let day = raw.dropFirst(6).prefix(2)
        let hour = raw.dropFirst(8).prefix(2)
        let minute = raw.dropFirst(10).prefix(2)
        let second = raw.dropFirst(12).prefix(2)
        return "\(year)-\(month)-\(day) \(hour):\(minute):\(second)"
    }

    func decodeResponseText(_ data: Data) -> String {
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

    func actionTimestamp(_ txnTs: Int?, createdTs: Int?) -> Int {
        (txnTs ?? 0) > 0 ? (txnTs ?? 0) : (createdTs ?? 0)
    }

    func formatTimestampMs(_ value: Any?) -> String {
        guard let ms = intValue(value), ms > 0 else { return "" }
        return isoDateTime(Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let isoDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    static let displayTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    func dateTextFromTimestampMs(_ value: Int) -> String {
        Self.dateOnlyFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(value) / 1000))
    }

    func isoDateTime(_ date: Date) -> String {
        Self.isoDateTimeFormatter.string(from: date)
    }

    func formatTime(_ value: String) -> String {
        let text = normalizedString(value)
        guard !text.isEmpty else { return "未记录" }
        return text.replacingOccurrences(of: "T", with: " ").prefixString(19)
    }

    func normalizeDateText(_ value: String) -> String {
        let text = normalizedString(value)
        return text.count >= 10 ? String(text.prefix(10)) : text
    }

    func currentMarketDateText() -> String {
        Self.dateOnlyFormatter.string(from: now())
    }

    func isCurrentMarketDate(_ dateText: String) -> Bool {
        normalizeDateText(dateText) == currentMarketDateText()
    }

    func resolvedChangePct(reported: Double?, latest: Double?, previous: Double?) -> Double? {
        if let reported, reported.isFinite {
            return reported
        }
        guard let latest, latest > 0, let previous, previous > 0 else { return nil }
        return (latest / previous - 1) * 100
    }

    func dateKey(_ value: String) -> Int {
        let text = normalizeDateText(value)
        guard !text.isEmpty else { return 0 }
        return Int(text.replacingOccurrences(of: "-", with: "")) ?? 0
    }

    func round(_ value: Double, digits: Int) -> Double {
        let base = pow(10.0, Double(digits))
        return (value * base).rounded() / base
    }

    func isoTimestampNow() -> String {
        Self.displayTimeFormatter.string(from: now())
    }

    func zipOptional(_ lhs: Double?, _ rhs: Double?) -> (Double, Double)? {
        guard let lhs, let rhs else { return nil }
        return (lhs, rhs)
    }

    static let regexCache: [String: NSRegularExpression] = {
        let patterns = [
            #"var\s+fS_name\s*=\s*"([^"]*)";"#,
            #"var\s+Data_netWorthTrend\s*=\s*(\[[\s\S]*?\]);"#,
            #"jsonpgz\((\{[\s\S]*\})\);"#,
            #"="([^"]*)";"#,
        ]
        return Dictionary(uniqueKeysWithValues: patterns.compactMap { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                return nil
            }
            return (pattern, regex)
        })
    }()

    func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = Self.regexCache[pattern] ?? (try? NSRegularExpression(pattern: pattern, options: [])) else {
            return nil
        }
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let resultRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[resultRange])
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    func prefixString(_ length: Int) -> String {
        String(prefix(length))
    }
}
