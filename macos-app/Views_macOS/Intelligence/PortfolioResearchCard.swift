import SwiftUI

// MARK: - 我的组合长期研判（V1 产品语义，V2 研究与决策数据）
//
// 相比基础形态新增：
// - 信号行可点开「判断依据」证据明细 Sheet（A6）
// - 行动候选区：最新决策 artifact 胜者计划的动作可「加入跟踪」直通
//   决策事项（B3，V1「加入关注」的 V2 对应物）

struct PortfolioResearchCard: View {
    let snapshot: InvestmentIntelligenceDashboardSnapshot
    @ObservedObject var model: AppModel
    @State private var evidenceQuery: EvidenceDetailSheet.Query?

    private var research: InvestmentIntelligenceDashboardSnapshot.ResearchSummary? {
        snapshot.research
    }

    var body: some View {
        SectionCard(
            title: "我的组合长期研判",
            subtitle: "持仓方向、组合风险、行动候选",
            icon: "sparkles",
            trailing: {
                Button(
                    model.researchOperationState.isRunning ? "更新中…" : (hasResult ? "更新研判" : "生成研判")
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
                Text("尚未生成组合长期研判——配置 AI 模型后，系统将结合持仓收集证据并产出论点、风险与行动候选。")
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
                    .padding(.vertical, AppPalette.spaceS)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: $evidenceQuery) { query in
            EvidenceDetailSheet(query: query)
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
            if !research.signalDetails.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("关键信号（点击查看依据）")
                        .font(AppPalette.appFont(.caption, weight: .medium))
                        .foregroundStyle(AppPalette.muted)
                    ForEach(
                        Array(research.signalDetails.prefix(5).enumerated()),
                        id: \.element.id
                    ) { index, signal in
                        signalRow(signal, rank: index + 1)
                    }
                }
            } else if !research.topSignals.isEmpty {
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
            if !research.actionCandidates.isEmpty {
                actionCandidatesSection(research.actionCandidates)
            }
            Text("证据 \(research.evidenceCount) 条 · 信号 \(research.signalCount) 条 · \(IntelligencePresentationFormatter.dateTimeText(research.producedAt))")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
        }
    }

    /// 信号行：文本 + 有证据引用时可点开判断依据（审计 A6）。
    private func signalRow(
        _ signal: InvestmentIntelligenceDashboardSnapshot.SignalDigest, rank: Int
    ) -> some View {
        Button {
            guard !signal.evidenceIDs.isEmpty else { return }
            evidenceQuery = EvidenceDetailSheet.Query(
                signalText: signal.text,
                evidenceIDs: signal.evidenceIDs)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: AppPalette.spaceS) {
                Text("· \(signal.text)")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !signal.evidenceIDs.isEmpty {
                    Label("依据", systemImage: "doc.text.magnifyingglass")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.info)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityHint(signal.evidenceIDs.isEmpty ? "" : "查看判断依据")
        }
        .disabled(signal.evidenceIDs.isEmpty)
    }

    /// 行动候选（审计 B3）：研究/决策产物 →「加入跟踪」直通决策事项。
    @ViewBuilder
    private func actionCandidatesSection(
        _ candidates: [InvestmentIntelligenceDashboardSnapshot.ActionCandidate]
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("行动候选")
                .font(AppPalette.appFont(.caption, weight: .medium))
                .foregroundStyle(AppPalette.muted)
            ForEach(candidates) { candidate in
                HStack(spacing: AppPalette.spaceS) {
                    Image(systemName: candidate.directionText == "增持"
                        ? "arrow.up.right.circle" : "arrow.down.right.circle")
                        .foregroundStyle(AppPalette.info)
                    Text(candidate.rationaleText)
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("加入跟踪") {
                        model.addCaseFromActionCandidate(
                            subjectName: candidate.subjectKey,
                            subjectCode: nil,
                            directionText: candidate.directionText,
                            rationale: candidate.rationaleText,
                            trigger: nil,
                            invalidation: nil,
                            sourceArtifactID: candidate.artifactID)
                    }
                    .buttonStyle(.appSecondary)
                    .controlSize(.small)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
