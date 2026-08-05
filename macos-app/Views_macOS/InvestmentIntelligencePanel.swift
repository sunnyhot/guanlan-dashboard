import SwiftUI

// macOS 端:投资智能板块(集中度风险)。
//
// 嵌入 EnhancementTodayPanel.todayContent 顶部,展示活跃的 DecisionCase 列表。
// 由 InvestmentIntelligence.enabled gate,enabled=false 时不显示。
// 见 docs/ai-pipeline-baseline.md 第 9 节。

struct InvestmentIntelligencePanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let activeCases = model.decisionCases
            .filter { $0.userDisposition != .closed && $0.lifecycle != .closed }

        if activeCases.isEmpty {
            // 无活跃事项时的空状态(只在 enabled 时显示)
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                // 板块标题
                HStack(spacing: AppPalette.spaceS) {
                    Image(systemName: "brain.head.profile")
                        .foregroundColor(AppPalette.brand)
                    Text("组合决策事项")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppPalette.ink)
                    Spacer()
                    Text("\(activeCases.count) 项")
                        .font(.system(size: 12))
                        .foregroundColor(AppPalette.muted)
                }

                // Case 列表(按严重程度排序:引擎已排好)
                ForEach(activeCases) { cs in
                    DecisionCaseCard(
                        decisionCase: cs,
                        isResearching: model.researchingDecisionCaseID == cs.id,
                        researchReport: model.lastDecisionCaseResearchReports[cs.id],
                        onAcknowledge: { model.acknowledgeDecisionCase(cs.id) },
                        onResolve: { model.resolveDecisionCase(cs.id) },
                        onClose: { model.closeDecisionCase(cs.id) },
                        onResearch: { Task { await model.researchDecisionCase(cs.id) } }
                    )
                }
            }
        }
    }
}
