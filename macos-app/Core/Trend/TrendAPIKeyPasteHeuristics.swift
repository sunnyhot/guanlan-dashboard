import Foundation

/// W1.4:剪贴板 API Key 的智能识别(纯函数,双端可复用)。
///
/// 只做保守的前缀/形状匹配,避免把任意文本误当 Key:
/// - `sk-` → OpenAI 兼容供应商 Key(OpenAI/DeepSeek 等都用此前缀,无法唯一定供应商,只填 Key)
/// - 32 位十六进制.16 位十六进制 → 智谱 Key(同时建议智谱预设)
enum TrendAPIKeyPasteHeuristics {
    enum Match: Equatable {
        /// 供应商 Key;suggestedPresetName 非空时提示确认对应预设。
        case providerKey(suggestedPresetName: String?)
    }

    /// 识别剪贴板文本;不符合任何已知 Key 形状时返回 nil。
    static func classify(_ text: String) -> Match? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 太短不可能是 Key,太长多半是多行文本;顺带排除含空白/换行的内容。
        guard (12...200).contains(trimmed.count),
              !trimmed.contains(where: { $0.isWhitespace }) else { return nil }
        if trimmed.hasPrefix("tvly-") {
        }
        if trimmed.hasPrefix("sk-") {
            return .providerKey(suggestedPresetName: nil)
        }
        if isZhipuShaped(trimmed) {
            return .providerKey(suggestedPresetName: "智谱")
        }
        return nil
    }

    /// 智谱 API Key 形状:`{32 位十六进制}.{16 位十六进制}`。
    private static func isZhipuShaped(_ text: String) -> Bool {
        text.range(of: "^[0-9a-f]{32}\\.[0-9a-f]{16}$", options: .regularExpression) != nil
    }
}
