import Foundation

// 集中度评估结果类型。
//
// ConcentrationRiskEngine 的输出,记录评估时的量化指标,
// 用于生成 DecisionCase 和 UI 展示。

// MARK: - 集中度评估结果

/// 单一维度的集中度评估。
struct ConcentrationAssessment: Codable, Hashable, Sendable {
    /// 维度(直接持仓 / 穿透 / 穿透重叠)。
    let dimension: ConcentrationDimension
    /// 标的名称(如「易方达蓝筹精选」或「贵州茅台」)。
    let subjectName: String
    /// 标的代码。
    let subjectCode: String?
    /// 核心指标值(如 top1 占比 55.3,或重叠暴露 28.0)。
    let metricValue: Double
    /// 格式化后的指标标签(如「55.3%」)。
    let metricLabel: String
    /// 指标描述(如「第一大标的占比」「穿透重叠暴露」)。
    let metricDescription: String

    /// 评估时用的阈值(用于 UI 展示边界)。
    let watchThreshold: Double
    let reviewThreshold: Double

    /// 数据是否充足(穿透覆盖率是否达标)。
    let hasSufficientData: Bool

    /// 根据指标和阈值推导的初步状态(未考虑 Profile 约束)。
    let preliminaryState: PortfolioDecisionState
}

/// 整体集中度评估(含多个维度)。
struct ConcentrationAssessmentBundle: Codable, Hashable, Sendable {
    /// 直接持仓集中度评估列表(按 metricValue 降序)。
    let directAssessments: [ConcentrationAssessment]
    /// 穿透集中度评估列表(按 metricValue 降序)。
    let lookThroughAssessments: [ConcentrationAssessment]
    /// 穿透重叠评估列表(按 metricValue 降序)。
    let overlapAssessments: [ConcentrationAssessment]

    /// 所有维度的评估合并(用于生成 DecisionCase)。
    var allAssessments: [ConcentrationAssessment] {
        directAssessments + lookThroughAssessments + overlapAssessments
    }

    /// 是否有任何维度数据不足。
    var hasAnyInsufficientData: Bool {
        allAssessments.contains { !$0.hasSufficientData }
    }
}

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

/// 从 PortfolioLookThroughSnapshot 算出的穿透集中度原始指标。
struct LookThroughConcentrationMetrics: Hashable {
    /// 穿透后第一大底层证券占比(0-100)。
    let topShare: Double
    /// 第一大底层证券名称。
    let topName: String
    /// 第一大底层证券代码。
    let topCode: String
    /// 穿透覆盖率(0-100,已披露底层证券占组合有效暴露的比例)。
    let coveragePct: Double
    /// 穿透数据是否可用(覆盖率达标)。
    let isAvailable: Bool
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
