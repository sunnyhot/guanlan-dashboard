import Foundation

// 集中度评估结果类型。
//
// ConcentrationRiskEngine 的输出,记录评估时的量化指标,
// 用于生成 DecisionCase 和 UI 展示。

// MARK: - 集中度评估结果

// MARK: - 集中度原始计算指标

/// 从 personalAssetRows 算出的直接持仓集中度原始指标。
struct DirectConcentrationMetrics: Hashable {
    /// 第一大标的占比(0-100)。
    let topShare: Double
    /// 第一大标的名称。
    let topName: String
    /// 第一大标的代码。
    let topCode: String?
    /// HHI(赫芬达尔指数,0-10000)。
    /// 值越大越集中:10000 = 单一标的,0 = 无限分散。
    let hhi: Double
    /// 有效持仓总数(用于 UI 展示)。
    let holdingCount: Int
}

/// 穿透重叠指标。
struct LookThroughOverlapMetrics: Hashable {
    /// 最大重叠暴露(0-100,同一底层证券被多只基金+直接持仓合计的占比)。
    let maxOverlapShare: Double
    /// 最大重叠标的名称。
    let topName: String
    /// 最大重叠标的代码。
    let topCode: String
    /// 贡献来源数(几只基金/直接持仓持有该底层)。
    let contributorCount: Int
    /// 穿透数据是否可用。
    let isAvailable: Bool
}
