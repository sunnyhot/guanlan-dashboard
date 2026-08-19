import Foundation

/// 模型输出规整:提交工具解码前,把"应为字符串数组"的字段元素强制收敛为字符串。
///
/// 背景(v4.1.0 首晚线上故障):模型偶尔忽略 schema,把 counterSignals 输出成
/// [{"text":"…"}] 或数字,合成解码直接 typeMismatch,整个模块提交失败且
/// 自动修正循环救不回。与 TrendDirection 的容错解析同理:单字段毛刺不应
/// 否决整份报告。只动提交入口的解码前 JSON,不改任何 DTO 与磁盘契约。
enum ModelOutputCoercion {
    /// 报告 DTO 家族里"字符串数组"契约字段(JSON 键为 camelCase,与提交模板一致)。
    private static let stringArrayFields: Set<String> = [
        "counterSignals",
        "triggerConditions",
        "invalidatingConditions",
        "evidenceIDs",
    ]

    /// 递归规整:目标字段做元素收敛,其余键只下钻不改值。
    static func normalized(_ object: [String: Any]) -> [String: Any] {
        var result = [String: Any]()
        result.reserveCapacity(object.count)
        for (key, value) in object {
            if stringArrayFields.contains(key), let array = value as? [Any] {
                result[key] = array.compactMap(coerceString)
                continue
            }
            result[key] = normalizedValue(value)
        }
        return result
    }

    /// 便捷入口:Data → 规整 → Data;任何一步失败原样返回(调用方降级为旧行为)。
    static func normalizedJSON(_ data: Data) -> Data {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let normalized = try? JSONSerialization.data(withJSONObject: normalized(object)) else {
            return data
        }
        return normalized
    }

    private static func normalizedValue(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            return normalized(dict)
        }
        if let array = value as? [Any] {
            return array.map(normalizedValue)
        }
        return value
    }

    /// 字符串原样(去空白);数字/布尔转字符串;对象取常见正文字段;其余丢弃。
    private static func coerceString(_ element: Any) -> String? {
        if let text = element as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = element as? NSNumber {
            return number.stringValue
        }
        if let dict = element as? [String: Any] {
            for key in ["text", "content", "value", "reason", "summary", "signal", "description"] {
                if let text = dict[key] as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
        }
        return nil
    }
}
