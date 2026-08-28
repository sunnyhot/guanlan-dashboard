import SwiftUI

/// 统一把握度胶囊进度条：数字写在胶囊里，按档位用同色系浅深渐变。
/// 供总览 AI 趋势摘要、今日研判、跟踪清单等所有展示确定性评分的地方共用。
/// W4.6:`showsAnchorCaption` 时在胶囊旁挂档位人话锚定(高可直接参考/
/// 中需结合自己判断/低仅供参考先别动),由结论卡启用;紧凑场景保持纯胶囊。
struct TrendConfidenceMeter: View {
    let confidence: TrendConfidence
    var showsAnchorCaption: Bool = false

    private var score: Int { confidence.normalizedScore }

    /// W4.6:档位锚定人话,与词表 confidenceAnchor 同源。
    var anchorCaption: String {
        if score >= 75 { return "可直接参考" }
        if score >= 45 { return "需结合自己判断" }
        return "仅供参考,先别动"
    }

    var body: some View {
        let width: CGFloat = 58
        let height: CGFloat = 14
        let fill = max(height, width * CGFloat(score) / 100)
        let base = score >= 75 ? AppPalette.positive : (score >= 45 ? AppPalette.warning : AppPalette.danger)
        HStack(spacing: 5) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppPalette.muted.opacity(0.2))
                    .frame(width: width, height: height)
                Capsule()
                    .fill(LinearGradient(colors: [base.opacity(0.7), base], startPoint: .leading, endPoint: .trailing))
                    .frame(width: fill, height: height)
                Text("把握\(score)")
                    .font(AppPalette.appFont(.caption2, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: width, height: height)
            }
            .frame(width: width, height: height)

            if showsAnchorCaption {
                Text(anchorCaption)
                    .font(AppPalette.appFont(.caption2))
                    .foregroundStyle(AppPalette.muted)
                    .help(ResearchTerm.confidenceAnchor.plainExplanation)
            }
        }
        .help(ResearchTerm.confidence.plainExplanation)
    }
}

/// 等高网格：同一行内的卡片取最高者为行高、内容顶对齐，不空撑。
/// 供收益归因指标、市场视图板块/大盘等需要行内对齐的卡片共用。
struct EqualHeightGrid<Item: Identifiable, Card: View>: View {
    let items: [Item]
    var columnsCount: Int = 3
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        let count = max(1, columnsCount)
        let rows = stride(from: 0, to: items.count, by: count).map { Array(items[$0..<min($0 + count, items.count)]) }
        Grid(alignment: .topLeading, horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row) { item in
                        card(item)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
    }
}
