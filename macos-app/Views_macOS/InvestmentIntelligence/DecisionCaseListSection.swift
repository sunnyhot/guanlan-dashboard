import SwiftUI

// macOS 决策事项列表区。
// 展示活跃 Case,所有操作通过 @EnvironmentObject model。
// 点击打开详情 Sheet。

struct DecisionCaseListSection: View {
    @EnvironmentObject var model: AppModel
    @State private var detailCase: DecisionCase?

    let cases: [DecisionCase]

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            ForEach(cases) { cs in
                DecisionCaseCard(
                    decisionCase: cs,
                    isResearching: model.researchingDecisionCaseID == cs.id,
                    researchReport: model.lastDecisionCaseResearchReports[cs.id],
                    onOpen: { detailCase = cs },
                    onAcknowledge: { model.acknowledgeDecisionCase(cs.id) },
                    onResolve: { model.resolveDecisionCase(cs.id) },
                    onClose: { model.closeDecisionCase(cs.id) },
                    onResearch: { Task { await model.researchDecisionCase(cs.id) } }
                )
            }
        }
        .sheet(item: $detailCase) { cs in
            DecisionCaseDetailSheet(caseID: cs.id)
                .environmentObject(model)
        }
    }
}
