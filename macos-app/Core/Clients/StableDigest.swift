import Foundation

// MARK: - StableDigest（审查 P1：确定性 ID 的语义完备 + 跨进程稳定工具）
//
// ID 派生的统一纪律：**稳定排序后的完整语义 payload**，只排除 producedAt
// （产出时间不参与身份——重算幂等）。
//
// 跨进程稳定性边界（二轮审查 P1-3 修复）：
// - JSONEncoder 的 sortedKeys 只排序 **JSON object 的键**（含 [String: V]
//   字典）；Hashable 键字典（[ListingID: V] 等）被编码成**交替数组**，
//   顺序随进程 Dictionary 种子漂移——调用方必须先把这类输入显式转成
//   **按 rawValue 排序的 entry 数组**再进 payload（见各 IdentityPayload）
// - 数组顺序 = 调用方给定的顺序：无序语义的数组必须先排序
// - 编码失败显式抛错（不返回占位串静默降级）

enum StableDigest {
    enum DigestError: Error, Equatable, Sendable {
        case encodingFailed(String)
    }

    /// 语义 payload → 稳定 JSON 字符串（sortedKeys；编码失败显式抛错）。
    /// **约定**：payload 内不得含 Hashable 键字典（交替数组不稳定）与
    /// 未排序的无序数组——用 `sortedKeyEntries` 预先规范化。
    static func jsonPayload<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else {
            throw DigestError.encodingFailed(String(describing: type(of: value)))
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Hashable 键字典 → 按 rawValue 排序的 "key|…" 串数组（跨进程稳定形态；
    /// value 的稳定串由调用方的 transform 给出——不得再含无序结构）。
    static func sortedKeyEntries<K: RawRepresentable, V>(
        _ dictionary: [K: V], key rawKey: (K) -> String = { $0.rawValue },
        value: (V) -> String
    ) -> [String] where K.RawValue == String {
        dictionary.map { "\(rawKey($0))|\(value($1))" }.sorted()
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
