import Foundation

// MARK: - StableDigest（审查 P1-3：确定性 ID 的语义完备工具）
//
// ID 派生的统一纪律：**稳定排序后的完整语义 payload**，只排除 producedAt
// （产出时间不参与身份——重算幂等）。JSON 用 sortedKeys 保证字典键序
// 稳定；数组按调用方排序后的顺序编码。

enum StableDigest {
    /// 语义 payload → 稳定 JSON 字符串（sortedKeys；编码失败返回占位，
    /// 不会静默丢弃字段）。
    static func jsonPayload<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "<unencodable>" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 双 FNV-1a 确定性摘要（128 bit hex；防意外漂移不防恶意碰撞）。
    static func digest(_ input: String) -> String {
        let data = Data(input.utf8)
        var h1: UInt64 = 0xcbf29ce484222325
        var h2: UInt64 = 0x9e3779b97f4a7c15
        for byte in data {
            h1 = (h1 ^ UInt64(byte)) &* 0x100000001b3
            h2 = (h2 &+ UInt64(byte)) &* 0xbf58476d1ce4e5b9
        }
        return String(format: "%016lx%016lx", h1, h2)
    }
}
