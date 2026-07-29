import Foundation

/// 且慢各 API 客户端共享的 JSON 响应文本解析工具。
///
/// 多个客户端（QiemanNativeClient / QiemanPlatformNativeClient /
/// QiemanAlfaClient / NativeSnapshotStore）过去各自维护一份等价的
/// 字符串归一化实现，规则分散后容易漂移。统一收敛到此处。
enum QiemanText {
    /// 把任意 JSON 值归一化为干净字符串：
    /// - `nil` / `NSNull` → `""`
    /// - 其余 → `String(describing:)` 后统一换行（`\r\n`、`\r` → `\n`）并去除首尾空白。
    static func normalizedString(_ value: Any?) -> String {
        guard let value else { return "" }
        if value is NSNull { return "" }
        return String(describing: value)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
