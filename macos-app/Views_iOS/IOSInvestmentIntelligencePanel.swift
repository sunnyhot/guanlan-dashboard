import SwiftUI

// iOS 端:投资智能板块(集中度风险)。
// 嵌入 EnhancementSectionView.reportContent,展示活跃的 DecisionCase。
// 由 InvestmentIntelligence.enabled gate。

struct IOSInvestmentIntelligencePanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let activeCases = model.decisionCases
            .filter { $0.userDisposition != .closed && $0.lifecycle != .closed }

        if !activeCases.isEmpty {
            VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
                HStack(spacing: IOSDesign.spaceS) {
                    Image(systemName: "brain.head.profile")
                        .foregroundColor(IOSDesign.accent)
                    Text("组合决策事项")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(IOSDesign.ink)
                    Spacer()
                    Text("\(activeCases.count) 项")
                        .font(.system(size: 13))
                        .foregroundColor(IOSDesign.muted)
                }

                ForEach(activeCases) { cs in
                    IOSDecisionCaseCard(
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
