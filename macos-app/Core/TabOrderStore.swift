import Foundation

// MARK: - 顶部 Tab 顺序持久化（UserDefaults）
//
// 持仓 / 平台活动 / 增强中心顶部 ModuleTabBar 的「自定义顺序」用此存储。
// 按 namespace 隔离三套顺序,每套存一个 [String]（ID 顺序即 tab 渲染顺序）。
// 纯 Foundation,跨平台复用。与 PinnedItemsStore 同范式（namespace + UserDefaults [String]）。
//
// 健壮性约定:
// - ordered<T>(_:id:) 以 T.allCases 为基准,持久化里缺失的项补到末尾(新增 tab 不丢),
//   持久化里有但枚举已删的项自动忽略(tab 下线兼容),无需写迁移代码。
// - ID 用各 tab 枚举的 rawValue(中文标签,稳定且唯一)。

final class TabOrderStore {
    let namespace: String
    private let defaults: UserDefaults

    init(namespace: String, defaults: UserDefaults = .standard) {
        self.namespace = namespace
        self.defaults = defaults
    }

    private var key: String { "qieman.dashboard.tabOrder.\(namespace).v1" }

    /// 持久化的 tab ID 顺序(用户上次重排后的结果)。空时返回 []。
    var savedOrder: [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    /// 落盘用户重排后的 ID 顺序。
    func save(_ ids: [String]) {
        defaults.set(ids, forKey: key)
    }

    /// 按 T.allCases 基准 + 持久化顺序重排。
    /// - 持久化里有的项,按持久化顺序排前;
    /// - 持久化里没有的项(新增 tab),按 allCases 声明顺序补到末尾;
    /// - 持久化里有但 allCases 里已不存在的项(下线 tab),自动忽略。
    func ordered<T>(_ type: T.Type, id: (T) -> String) -> [T] where T: CaseIterable, T.AllCases: RandomAccessCollection {
        let all = Array(type.allCases)
        let stored = savedOrder
        guard !stored.isEmpty else { return all }

        let validIDs = Set(all.map(id))

        // 持久化里有效的项,按持久化顺序(filter 保序);缺失项按 allCases 声明顺序补末尾
        let orderedKnown = stored.filter { validIDs.contains($0) }
        let knownSet = Set(orderedKnown)
        let tail = all.filter { !knownSet.contains(id($0)) }

        let idToItem = Dictionary(uniqueKeysWithValues: all.map { (id($0), $0) })
        let head = orderedKnown.compactMap { idToItem[$0] }
        return head + tail
    }
}
