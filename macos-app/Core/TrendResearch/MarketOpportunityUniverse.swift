import Foundation

/// 全市场机会扫描的受控研究池。
///
/// 它只决定 Agent 可以主动研究哪些通用方向，不代表系统看多这些方向，
/// 也不会因为用户是否持有而增删候选。
enum MarketOpportunityUniverse {
    /// 允许 Agent 用一个结构化目标表达“扫描主要市场”，避免强迫模型随意挑选
    /// 某一个指数或资产类别来冒充全市场覆盖。
    static let aggregateIndexKey = "大盘宽基指数"
    static let aggregateAssetClassKey = "大类资产配置"

    static let indices = [
        "上证指数", "沪深300", "中证500", "中证1000", "科创50", "创业板指",
        "恒生指数", "恒生科技", "标普500", "纳斯达克", "纳斯达克100", "道琼斯",
        "日经225", "德国DAX"
    ]

    static let sectorGroups = [
        MarketOpportunitySectorGroup(
            key: "科技成长",
            sectors: ["人工智能", "半导体", "机器人", "软件", "通信", "数据中心", "传媒"]
        ),
        MarketOpportunitySectorGroup(
            key: "医药消费",
            sectors: ["医药", "创新药", "消费", "农业"]
        ),
        MarketOpportunitySectorGroup(
            key: "金融地产",
            sectors: ["金融", "银行", "保险", "券商", "房地产"]
        ),
        MarketOpportunitySectorGroup(
            key: "制造新能源",
            sectors: ["新能源", "光伏", "储能", "电力", "高端制造", "军工"]
        ),
        MarketOpportunitySectorGroup(
            key: "周期资源",
            sectors: ["有色金属", "煤炭", "石油石化"]
        ),
        MarketOpportunitySectorGroup(
            key: "防御价值",
            sectors: ["公用事业", "红利"]
        ),
    ]

    static let sectors = sectorGroups.flatMap(\.sectors)

    static let assetClasses = [
        "A股", "港股", "美股", "日本股市", "欧洲股市",
        "债券", "利率债", "信用债", "黄金", "白银", "原油", "商品", "REITs", "现金"
    ]

    static var promptDescription: String {
        "大盘/宽基：\(indices.joined(separator: "、"))；"
            + "板块分组：\(sectorGroups.map { "\($0.key)[\($0.sectors.joined(separator: "、"))]" }.joined(separator: "；"))；"
            + "大类资产：\(assetClasses.joined(separator: "、"))。"
    }

    static var requiredSectorGroupKeys: [String] {
        sectorGroups.map(\.key)
    }

    static func sectorGroup(matching key: String) -> MarketOpportunitySectorGroup? {
        let normalizedKey = normalized(key)
        return sectorGroups.first { normalized($0.key) == normalizedKey }
    }

    static func isCompleteSectorGroupTarget(_ target: TrendResearchTarget) -> Bool {
        guard target.kind == .sector,
              let group = sectorGroup(matching: target.key) else {
            return false
        }
        return Set(target.sectorKeys.map(normalized)) == Set(group.sectors.map(normalized))
    }

    /// 六个全市场板块分组是 App 自己维护的受控研究池。模型只要给出合法分组名，
    /// App 就确定性补齐完整成员，避免因为漏抄一个 sectorKeys 而反复消耗 Agent 预算。
    static func canonicalizedTarget(_ target: TrendResearchTarget) -> TrendResearchTarget {
        guard target.kind == .sector,
              let group = sectorGroup(matching: target.key) else {
            return target
        }
        return TrendResearchTarget(
            kind: .sector,
            key: group.key,
            entityCodes: target.entityCodes,
            sectorKeys: group.sectors,
            assetClassKeys: target.assetClassKeys
        )
    }

    static func contains(_ key: String, kind: TrendResearchTargetKind) -> Bool {
        let normalizedKey = normalized(key)
        let values: [String]
        switch kind {
        case .index:
            values = indices
        case .sector:
            values = sectors + requiredSectorGroupKeys
        case .assetClass:
            values = assetClasses
        case .asset, .macro:
            return false
        }
        return values.contains { normalized($0) == normalizedKey }
    }

    static func isAggregateTarget(_ key: String, kind: TrendResearchTargetKind) -> Bool {
        let normalizedKey = normalized(key)
        switch kind {
        case .index:
            return normalizedKey == normalized(aggregateIndexKey)
        case .assetClass:
            return normalizedKey == normalized(aggregateAssetClassKey)
        case .asset, .sector, .macro:
            return false
        }
    }

    static func stableSearchCacheScope(for target: TrendResearchTarget) -> String? {
        switch target.kind {
        case .index:
            guard isAggregateTarget(target.key, kind: .index)
                    || contains(target.key, kind: .index) else {
                return nil
            }
        case .sector:
            guard contains(target.key, kind: .sector) else { return nil }
        case .assetClass:
            guard isAggregateTarget(target.key, kind: .assetClass)
                    || contains(target.key, kind: .assetClass) else {
                return nil
            }
        case .asset, .macro:
            return nil
        }
        return ([target.kind.rawValue, target.key]
            + target.entityCodes.sorted()
            + target.sectorKeys.sorted()
            + target.assetClassKeys.sorted())
            .map(normalized)
            .joined(separator: "|")
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}
