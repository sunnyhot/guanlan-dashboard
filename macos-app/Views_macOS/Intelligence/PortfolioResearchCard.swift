import SwiftUI

// MARK: - 组合研究卡（产品重构 §8.6）

struct PortfolioResearchCard: View {
    let snapshot: InvestmentIntelligenceDashboardSnapshot
    @ObservedObject var model: AppModel

    private var research: InvestmentIntelligenceDashboardSnapshot.ResearchSummary? {
        snapshot.research
    }

    var body: some View {
        SectionCard(
            title: "组合研究",
            subtitle: "证据 → 论点 → 信号 → 决策，全程可溯",
            icon: "sparkles",
            trailing: {
                Button(
                    model.researchOperationState.isRunning ? "研究中…" : (hasResult ? "重新研究" : "开始研究")
                ) {
                    model.runPortfolioResearch()
                }
                .buttonStyle(.appPrimary)
                .controlSize(.small)
                .disabled(
                    model.researchOperationState.isRunning
                        || !snapshot.readiness.providerConfigured
                        || model.intelligenceRuntime == nil
                        || snapshot.readiness.blocker != nil)
                .help(researchHelp)
            }
        ) {
            if case let .running(_, stage) = model.researchOperationState {
                IntelligenceRunningRow(stage: stage)
            }
            if case let .failed(error) = model.researchOperationState {
                IntelligenceInlineError(error: error)
            }
            if !snapshot.readiness.providerConfigured {
                // 未配置 Provider：可点击引导，不出现无解释的 disabled 按钮
                Button {
                    model.requestSettingsSection(.intelligence)
                } label: {
                    Label("配置 AI 模型后启用研究（前往设置）", systemImage: "arrow.right.circle")
                        .font(AppPalette.appFont(.footnote))
                }
                .buttonStyle(.appText)
            } else if let research, hasResult {
                researchContent(research)
            } else {
                Text("尚未运行组合研究——配置 AI 模型后，系统将收集证据并产出论点与信号。")
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
                    .padding(.vertical, AppPalette.spaceS)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hasResult: Bool {
        guard let research else { return false }
        return research.producedAt != nil
    }

    private var researchHelp: String {
        if !snapshot.readiness.providerConfigured { return "需先在设置中配置 AI 模型" }
        if snapshot.readiness.blocker != nil { return "需先完成战略配置与持仓归类" }
        return "运行组合研究"
    }

    @ViewBuilder
    private func researchContent(
        _ research: InvestmentIntelligenceDashboardSnapshot.ResearchSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            Text(research.narrativeHeadline)
                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !research.portfolioStatement.isEmpty {
                Text(research.portfolioStatement)
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !research.topSignals.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("关键信号")
                        .font(AppPalette.appFont(.caption, weight: .medium))
                        .foregroundStyle(AppPalette.muted)
                    ForEach(research.topSignals, id: \.self) { signal in
                        Text("· \(signal)")
                            .font(AppPalette.appFont(.footnote))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text("证据 \(research.evidenceCount) 条 · 信号 \(research.signalCount) 条 · \(IntelligencePresentationFormatter.dateTimeText(research.producedAt))")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
        }
    }
}
