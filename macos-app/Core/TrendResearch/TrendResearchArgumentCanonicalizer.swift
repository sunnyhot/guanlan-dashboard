import Foundation

/// 工具调用参数规范化器：让「等价格式」的调用共享结果缓存与非重试语义。
///
/// 在 sorted-keys JSON 规范化之上追加**值级规范化**：
/// - 看起来像证券代码的字符串统一为规范键（`0700.HK`/`hk700`/`HK00700` → `HK00700`；
///   `sh600519`/`600519.SH`/`1.600519` → `600519`），大小写统一；
/// - 其余字符串保持原样（不误伤自然语言参数）。
/// 口径对拍 daily_stock_analysis execution.py 的参数规范化缓存 key。
enum TrendResearchArgumentCanonicalizer {
    /// 返回规范化后的参数 JSON 文本；不是合法 JSON 对象时原样返回（解析容错与既有签名行为一致）。
    static func canonicalJSON(_ rawArguments: String) -> String {
        let trimmed = rawArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object)
        else {
            return trimmed
        }
        let normalized = normalizeValue(object)
        guard let canonicalData = try? JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys]),
              let canonical = String(data: canonicalData, encoding: .utf8)
        else {
            return trimmed
        }
        return canonical
    }

    /// 工具签名：`name|canonicalArguments`。提交类工具由调用方自行排除。
    static func signature(toolName: String, arguments: String) -> String {
        "\(toolName)|\(canonicalJSON(arguments))"
    }

    // MARK: - 值规范化

    private static func normalizeValue(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            var result: [String: Any] = [:]
            for (key, item) in dictionary {
                result[key] = normalizeValue(item)
            }
            return result
        case let array as [Any]:
            return array.map(normalizeValue)
        case let text as String:
            return normalizeString(text)
        default:
            return value
        }
    }

    /// 仅规范化「像代码」的短字符串：6 位 A股/5 位数字/HK 前缀/带 .SH .SZ .HK 后缀。
    /// 长文本、含空格或中文的参数原样保留。
    static func normalizeString(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        // 含空格或非 ASCII 的多词文本不是代码
        guard !trimmed.contains(" "), trimmed.allSatisfy({ $0.isASCII }) else { return trimmed }

        let upper = trimmed.uppercased()
        // HK 系
        if upper.hasPrefix("HK") || upper.hasSuffix(".HK") {
            let key = MarketCodeNormalizer.canonicalKey(for: upper)
            if key != upper {
                return key
            }
            return upper
        }
        // 带 A股交易所后缀
        if upper.hasSuffix(".SH") || upper.hasSuffix(".SZ") || upper.hasSuffix(".BJ") {
            return MarketCodeNormalizer.bareACode(from: upper)
        }
        // 带交易所前缀
        let lower = trimmed.lowercased()
        if lower.hasPrefix("sh") || lower.hasPrefix("sz") || lower.hasPrefix("bj") {
            return MarketCodeNormalizer.bareACode(from: lower)
        }
        // 东财 secid 形如 1.600519
        if upper.contains("."), upper.split(separator: ".").count == 2,
           let head = upper.split(separator: ".").first, head.count == 1, head.allSatisfy(\.isNumber) {
            return MarketCodeNormalizer.bareACode(from: upper)
        }
        // 纯 6 位数字（A股裸代码，大小写无关）原样
        if upper.count == 6, upper.allSatisfy(\.isNumber) {
            return upper
        }
        // 纯 5 位数字（港股裸代码）补 HK 前缀
        if upper.count == 5, upper.allSatisfy(\.isNumber) {
            return MarketCodeNormalizer.canonicalKey(for: upper)
        }
        return trimmed
    }
}
