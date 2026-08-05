import SwiftUI

// iOS 端:投资智能板块(集中度风险 + 决策事项 + 偏好设置)。
// 嵌入 EnhancementSectionView.reportContent。
// 由 InvestmentIntelligence.enabled gate。

struct IOSInvestmentIntelligencePanel: View {
    @EnvironmentObject var model: AppModel
    @State private var showProfileEditor = false

    var body: some View {
        let activeCases = model.decisionCases
            .filter { $0.userDisposition != .closed && $0.lifecycle != .closed }

        VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            HStack(spacing: IOSDesign.spaceS) {
                Image(systemName: "brain.head.profile")
                    .foregroundColor(IOSDesign.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("组合决策事项")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(IOSDesign.ink)
                    Text("\(activeCases.count) 项" + (model.userDecisionProfile.isCustomized ? " · 已配置偏好" : " · 默认偏好"))
                        .font(.system(size: 12))
                        .foregroundColor(IOSDesign.muted)
                }
                Spacer()
                Button(action: { showProfileEditor.toggle() }) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundColor(IOSDesign.muted)
            }

            if !activeCases.isEmpty {
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

            if showProfileEditor {
                IOSUserDecisionProfileEditor()
            }
        }
    }
}
