import Foundation

// MARK: - 置顶项持久化（UserDefaults）
//
// 持仓明细 / 关注列表的「左划置顶」用此存储。按 namespace 隔离两套置顶 ID 集合,
// 每套存一个 [String]（保持置顶先后顺序,先置顶的排更前）。
// 纯 Foundation,跨平台复用。

final class PinnedItemsStore {
    let namespace: String
    private let defaults: UserDefaults

    init(namespace: String, defaults: UserDefaults = .standard) {
        self.namespace = namespace
        self.defaults = defaults
    }

    private var key: String { "qieman.pinned.\(namespace)" }

    /// 置顶 ID 列表（按置顶先后顺序,首个为最早置顶）。
    var pinnedIDs: [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    func contains(_ id: String) -> Bool {
        pinnedIDs.contains(id)
    }

    /// 加入置顶(移到列表末尾 = 最近置顶)。若已存在先移除再追加,刷新置顶时间。
    func pin(_ id: String) {
        var current = pinnedIDs.filter { $0 != id }
        current.append(id)
        defaults.set(current, forKey: key)
    }

    /// 取消置顶。
    func unpin(_ id: String) {
        let current = pinnedIDs.filter { $0 != id }
        defaults.set(current, forKey: key)
    }

    /// 置顶排序辅助:pinned 项排前,按 pinnedIDs 顺序;非 pinned 项保持原相对顺序。
    func sorted<T>(_ items: [T], id: (T) -> String) -> [T] {
        let order = pinnedIDs
        guard !order.isEmpty else { return items }
        let orderIndex = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return items.sorted { lhs, rhs in
            let li = orderIndex[id(lhs)]
            let ri = orderIndex[id(rhs)]
            if li != nil && ri != nil { return li! < ri! }
            if li != nil { return true }
            if ri != nil { return false }
            return false
        }
    }
}
