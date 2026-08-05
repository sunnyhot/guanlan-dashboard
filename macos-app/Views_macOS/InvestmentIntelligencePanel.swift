import SwiftUI

// macOS 端:投资智能板块(集中度风险 + 决策事项 + 偏好设置)。
//
// 嵌入 EnhancementTodayPanel.todayContent,展示:
// 1. 投资智能概况(有多少 Case、最严重状态、Profile 状态)
// 2. 活跃 DecisionCase 列表
// 3. 可展开的偏好设置(Profile 编辑)
// 由 InvestmentIntelligence.enabled gate,enabled=false 时不显示。

struct InvestmentIntelligencePanel: View {
    @EnvironmentObject var model: AppModel
    @State private var showProfileEditor = false

    var body: some View {
        let activeCases = model.decisionCases
            .filter { $0.userDisposition != .closed && $0.lifecycle != .closed }
        let severity = mostSevereState(activeCases)

        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            // 板块标题 + 概况
            HStack(spacing: AppPalette.spaceS) {
                Image(systemName: "brain.head.profile")
                    .foregroundColor(AppPalette.brand)
                VStack(alignment: .leading, spacing: 1) {
                    Text("组合决策事项")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppPalette.ink)
                    Text(summaryText(activeCases: activeCases, severity: severity))
                        .font(.system(size: 11))
                        .foregroundColor(AppPalette.muted)
                }
                Spacer()
                // Profile 状态徽章
                profileBadge
                Button(action: { showProfileEditor.toggle() }) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12))
                }
                .buttonStyle(.appIcon)
                .foregroundColor(AppPalette.muted)
                .help("投资偏好设置")
            }

            // Case 列表
            if !activeCases.isEmpty {
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

            // Profile 编辑(可展开)
            if showProfileEditor {
                UserDecisionProfileEditor()
            }
        }
    }

    // MARK: - 派生

    private var profileBadge: some View {
        let isCustomized = model.userDecisionProfile.isCustomized
        return Text(isCustomized ? "已配置偏好" : "默认偏好")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(isCustomized ? AppPalette.positive : AppPalette.warning)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                (isCustomized ? AppPalette.positive : AppPalette.warning).opacity(0.12),
                in: Capsule()
            )
    }

    private func summaryText(activeCases: [DecisionCase], severity: PortfolioDecisionState?) -> String {
        if activeCases.isEmpty {
            return "当前组合状态稳定,无需处理的决策事项。"
        }
        let count = activeCases.count
        let severityText: String
        switch severity {
        case .adjustReview, .exitReview: severityText = "建议复核"
        case .prepare: severityText = "接近阈值"
        case .watch: severityText = "观察中"
        case .insufficientEvidence: severityText = "数据不足"
        case .stable, nil: severityText = "正常"
        }
        return "\(count) 项决策事项 · 最严重:\(severityText)"
    }

    private func mostSevereState(_ cases: [DecisionCase]) -> PortfolioDecisionState? {
        let order: [PortfolioDecisionState] = [.exitReview, .adjustReview, .prepare, .watch, .insufficientEvidence, .stable]
        for state in order {
            if cases.contains(where: { $0.decisionState == state }) { return state }
        }
        return nil
    }
}
