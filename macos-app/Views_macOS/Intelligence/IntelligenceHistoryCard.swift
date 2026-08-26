import SwiftUI

// MARK: - 最近记录卡（macOS Table；产品重构 §8.7）
//
// Table 展示类型/结论/时间/有效性；键盘上下选择 + Return 打开详情 +
// 右键复制诊断 ID；默认 20 条（Query Service 控制 limit，View 不查库分页）。

struct IntelligenceHistoryCard: View {
    let history: [InvestmentIntelligenceDashboardSnapshot.HistoryItem]
    @State private var selection: InvestmentIntelligenceDashboardSnapshot.HistoryItem.ID?
    @State private var copiedIDNotice: String?

    var body: some View {
        SectionCard(
            title: "最近记录",
            subtitle: "全部产出（含过期，供审计）",
            icon: "list.bullet.rectangle"
        ) {
            if history.isEmpty {
                Text("暂无记录——运行评估 / 研究 / 发现后在此汇总。")
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
                    .padding(.vertical, AppPalette.spaceS)
            } else {
                Table(history, selection: $selection) {
                    TableColumn("类型") { item in
                        Text(IntelligencePresentationFormatter.historyKindLabel(item.kind))
                            .font(AppPalette.appFont(.footnote, weight: .medium))
                    }
                    .width(min: 72, ideal: 84)

                    TableColumn("结论") { item in
                        HStack(spacing: AppPalette.spaceS) {
                            Text(item.conclusionText)
                                .font(AppPalette.appFont(.footnote))
                            if !item.targetResolvable {
                                // 旧链路产物：审计可见，标注不冒充有效用户结论
                                Text("目标不可溯")
                                    .font(AppPalette.appFont(.caption2))
                                    .foregroundStyle(AppPalette.muted)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(AppPalette.muted.opacity(0.1), in: Capsule())
                            }
                        }
                    }

                    TableColumn("生成时间") { item in
                        Text(IntelligencePresentationFormatter.dateTimeText(item.producedAt))
                            .font(AppPalette.appFont(.footnote))
                            .foregroundStyle(AppPalette.muted)
                    }
                    .width(min: 120, ideal: 140)

                    TableColumn("有效状态") { item in
                        Text(IntelligencePresentationFormatter.historyValidityLabel(item.isValid))
                            .font(AppPalette.appFont(.footnote, weight: .medium))
                            .foregroundStyle(item.isValid ? AppPalette.positive : AppPalette.muted)
                    }
                    .width(min: 64, ideal: 72)
                }
                .tableStyle(.inset)
                .frame(height: min(CGFloat(history.count) * 36 + 40, 260))
                .contextMenu(forSelectionType: InvestmentIntelligenceDashboardSnapshot.HistoryItem.ID.self) { ids in
                    if let id = ids.first, let item = history.first(where: { $0.id == id }) {
                        Button("复制报告 ID") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.artifactID, forType: .string)
                            copiedIDNotice = item.artifactID
                        }
                    }
                } primaryAction: { ids in
                    _ = ids
                }
                .overlay(alignment: .bottomTrailing) {
                    if let copiedIDNotice {
                        Text("已复制 \(copiedIDNotice.prefix(12))…")
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AppPalette.panelBackground, in: Capsule())
                            .task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                self.copiedIDNotice = nil
                            }
                    }
                }
            }
        }
    }
}
