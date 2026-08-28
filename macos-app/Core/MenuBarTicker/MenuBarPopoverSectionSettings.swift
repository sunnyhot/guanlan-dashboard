import Foundation

/// 菜单栏弹框的内容板块类型。新增板块时加一个 case（title/icon 在此内聚），
/// `normalized()` 会把新 case 追加到老用户 order 末尾，存量设置自动兼容。
enum MenuBarPopoverSectionKind: String, Codable, CaseIterable, Identifiable {
    case portfolio
    case watchlist
    case marketIndices
    case goldForex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .portfolio: return "我的持仓"
        case .watchlist: return "我的关注"
        case .marketIndices: return "大盘数据"
        case .goldForex: return "黄金·汇率"
        }
    }

    var icon: String {
        switch self {
        case .portfolio: return "briefcase.fill"
        case .watchlist: return "star.fill"
        case .marketIndices: return "chart.line.uptrend.xyaxis"
        case .goldForex: return "banknote"
        }
    }
}

/// 弹框板块的显示/顺序/行情选择，UserDefaults 持久化。
/// 与状态栏 ticker 的 `MenuBarTickerSettings` 相互独立。
struct MenuBarPopoverSectionSettings: Codable, Hashable {
    var order: [MenuBarPopoverSectionKind]
    var hidden: [MenuBarPopoverSectionKind]
    var marketIndexKinds: [MarketIndexKind]
    var goldForexKinds: [GoldForexKind]

    static let storageKey = "qieman.dashboard.menuBarPopoverSections.v1"
    /// 旧版"哪个板块在上"偏好（仅 portfolio/watchlist 二选一），首次加载时迁移。
    static let legacyTopSectionStorageKey = "menu.bar.popover.top-section"

    static let `default` = MenuBarPopoverSectionSettings(
        order: [.portfolio, .watchlist, .marketIndices, .goldForex],
        hidden: [],
        marketIndexKinds: [.sseComposite, .csi300, .chinext],
        goldForexKinds: [.xauUSD, .usdCNY]
    )

    init(
        order: [MenuBarPopoverSectionKind] = MenuBarPopoverSectionSettings.default.order,
        hidden: [MenuBarPopoverSectionKind] = [],
        marketIndexKinds: [MarketIndexKind] = MenuBarPopoverSectionSettings.default.marketIndexKinds,
        goldForexKinds: [GoldForexKind] = MenuBarPopoverSectionSettings.default.goldForexKinds
    ) {
        self.order = order
        self.hidden = hidden
        self.marketIndexKinds = marketIndexKinds
        self.goldForexKinds = goldForexKinds
    }

    private enum CodingKeys: String, CodingKey {
        case order
        case hidden
        case marketIndexKinds
        case goldForexKinds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 按字符串解码再映射：未来版本增删 case 时，未知值只会被丢弃，不会让整个数组解码失败。
        order = Self.decodeKindArray(c, .order) ?? Self.default.order
        hidden = Self.decodeKindArray(c, .hidden) ?? []
        marketIndexKinds = Self.decodeKindArray(c, .marketIndexKinds)
            ?? Self.default.marketIndexKinds
        goldForexKinds = Self.decodeKindArray(c, .goldForexKinds)
            ?? Self.default.goldForexKinds
    }

    private static func decodeKindArray<T: RawRepresentable>(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> [T]? where T.RawValue == String {
        guard let rawValues = try? container.decodeIfPresent([String].self, forKey: key) else {
            return nil
        }
        return rawValues.compactMap { T(rawValue: $0) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(order, forKey: .order)
        try container.encode(hidden, forKey: .hidden)
        try container.encode(marketIndexKinds, forKey: .marketIndexKinds)
        try container.encode(goldForexKinds, forKey: .goldForexKinds)
    }

    var hiddenKinds: Set<MenuBarPopoverSectionKind> { Set(hidden) }

    var visibleSections: [MenuBarPopoverSectionKind] {
        order.filter { !hiddenKinds.contains($0) }
    }

    func isHidden(_ kind: MenuBarPopoverSectionKind) -> Bool {
        hiddenKinds.contains(kind)
    }

    func normalized() -> MenuBarPopoverSectionSettings {
        var copy = self

        var seenSections = Set<MenuBarPopoverSectionKind>()
        copy.order = copy.order.filter { seenSections.insert($0).inserted }
        for kind in MenuBarPopoverSectionKind.allCases where !seenSections.contains(kind) {
            copy.order.append(kind)
        }

        var seenHidden = Set<MenuBarPopoverSectionKind>()
        copy.hidden = copy.hidden.filter { seenHidden.insert($0).inserted }

        copy.marketIndexKinds = Self.orderedUnique(
            copy.marketIndexKinds, allCases: MarketIndexKind.allCases
        )
        copy.goldForexKinds = Self.orderedUnique(
            copy.goldForexKinds, allCases: GoldForexKind.allCases
        )
        return copy
    }

    private static func orderedUnique<T: Hashable>(_ values: [T], allCases: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
            .sorted { left, right in
                let leftIndex = allCases.firstIndex(of: left) ?? allCases.count
                let rightIndex = allCases.firstIndex(of: right) ?? allCases.count
                return leftIndex < rightIndex
            }
    }

    static func load() -> MenuBarPopoverSectionSettings {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(MenuBarPopoverSectionSettings.self, from: data) {
            return decoded.normalized()
        }

        var migrated = `default`
        if let raw = UserDefaults.standard.string(forKey: legacyTopSectionStorageKey),
           let top = MenuBarPopoverSectionKind(rawValue: raw),
           top != migrated.order.first {
            migrated.order.removeAll { $0 == top }
            migrated.order.insert(top, at: 0)
        }
        let normalized = migrated.normalized()
        normalized.save()
        return normalized
    }

    func save() {
        guard let data = try? JSONEncoder().encode(normalized()) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
