import SwiftUI

/// 等高网格：同一行内的卡片取最高者为行高、内容顶对齐，不空撑。
/// 供收益归因指标、市场视图板块/大盘等需要行内对齐的卡片共用。
/// （旧 AI 链路的 TrendConfidenceMeter 已随链路下线删除,WF-4。）
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
