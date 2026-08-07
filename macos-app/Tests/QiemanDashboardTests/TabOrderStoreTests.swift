import XCTest
@testable import QiemanDashboard

// MARK: - TabOrderStore 测试
//
// 用本地定义的 SampleTab 枚举模拟真实 tab 集合(String rawValue + CaseIterable + Identifiable),
// 用独立的 UserDefaults suite 隔离,避免污染全局 .standard。

private enum SampleTab: String, CaseIterable, Identifiable {
    case analysis = "组合分析"
    case assets = "资产明细"
    case watchlist = "关注"

    var id: String { rawValue }
}

final class TabOrderStoreTests: XCTestCase {

    /// 每个测试用独立的 suite,保证互不污染。
    private func makeStore(namespace: String = "test") -> TabOrderStore {
        let suite = UserDefaults(suiteName: "TabOrderStoreTests.\(UUID().uuidString)")!
        return TabOrderStore(namespace: namespace, defaults: suite)
    }

    func testEmptyPersistenceReturnsAllCasesOrder() {
        let store = makeStore()
        let ordered = store.ordered(SampleTab.self, id: { $0.id })
        XCTAssertEqual(ordered.map(\.rawValue), ["组合分析", "资产明细", "关注"])
    }

    func testSaveAndReorderRoundTrip() {
        let store = makeStore()
        // 用户把「资产明细」拖到「组合分析」前面
        store.save(["资产明细", "组合分析", "关注"])

        let ordered = store.ordered(SampleTab.self, id: { $0.id })
        XCTAssertEqual(ordered.map(\.rawValue), ["资产明细", "组合分析", "关注"])
    }

    func testMissingItemsAppendedAtTail() {
        let store = makeStore()
        // 持久化里只记了一个(比如旧版本没有「关注」),新增的应补到末尾
        store.save(["资产明细"])

        let ordered = store.ordered(SampleTab.self, id: { $0.id })
        XCTAssertEqual(ordered.first?.rawValue, "资产明细")
        // 其余两项按 allCases 声明顺序补尾
        let tail = ordered.dropFirst().map(\.rawValue)
        XCTAssertEqual(tail, ["组合分析", "关注"])
    }

    func testRemovedItemsIgnored() {
        let store = makeStore()
        // 持久化里含一个已下线的 tab「社区」,应被忽略
        store.save(["社区", "关注", "资产明细", "组合分析"])

        let ordered = store.ordered(SampleTab.self, id: { $0.id })
        XCTAssertEqual(ordered.map(\.rawValue), ["关注", "资产明细", "组合分析"])
        XCTAssertFalse(ordered.contains { $0.rawValue == "社区" })
    }

    func testDifferentNamespacesIsolated() {
        let suite = UserDefaults(suiteName: "TabOrderStoreTests.iso.\(UUID().uuidString)")!
        let storeA = TabOrderStore(namespace: "portfolio", defaults: suite)
        let storeB = TabOrderStore(namespace: "platform", defaults: suite)

        storeA.save(["关注", "资产明细", "组合分析"])
        storeB.save(["组合分析", "资产明细", "关注"])

        let a = storeA.ordered(SampleTab.self, id: { $0.id })
        let b = storeB.ordered(SampleTab.self, id: { $0.id })
        XCTAssertEqual(a.first?.rawValue, "关注")
        XCTAssertEqual(b.first?.rawValue, "组合分析")
    }

    func testSavedOrderReflectsInSavedOrderProperty() {
        let store = makeStore()
        store.save(["关注", "资产明细"])
        XCTAssertEqual(store.savedOrder, ["关注", "资产明细"])
    }
}
