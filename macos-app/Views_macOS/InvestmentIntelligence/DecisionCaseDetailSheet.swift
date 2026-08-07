import SwiftUI

struct DecisionCaseDetailSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let caseID: UUID

    @State private var isShowingReview = false

    private var decisionCase: DecisionCase? {
        model.decisionCases.first { $0.id == caseID }
    }

    var body: some View {
        if let decisionCase {
            VStack(spacing: 0) {
                header(decisionCase)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: AppPalette.spaceL) {
                        decisionSummary(decisionCase)
                        researchSection(decisionCase)
                        reviewSection(decisionCase)
                        eventHistory(decisionCase)
                    }
                    .padding(AppPalette.spaceL)
                }
                Divider()
                actionBar(decisionCase)
            }
            .frame(minWidth: 620, idealWidth: 680, minHeight: 600, idealHeight: 720)
            .sheet(isPresented: $isShowingReview) {
                DecisionReviewSheet(caseID: decisionCase.id)
                    .environmentObject(model)
            }
        } else {
            InvestmentEmptyState(icon: "questionmark.folder", title: "事项不存在", detail: "它可能已经被清理或迁移。")
                .padding(AppPalette.spaceL)
        }
    }

    private func header(_ decisionCase: DecisionCase) -> some View {
        let tint = InvestmentIntelligenceStyle.tint(for: decisionCase.decisionState)
        return HStack(alignment: .top, spacing: AppPalette.spaceM) {
            VStack(alignment: .leading, spacing: 5) {
                Text(decisionCase.kind.displayName)
                    .font(AppPalette.appFont(.caption, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(AppPalette.brand)
                Text(decisionCase.title)
                    .font(AppPalette.appFont(.title2, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                Text("\(decisionCase.lifecycle.displayName) · \(decisionCase.userDisposition.displayName)")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
            }
            Spacer()
            InvestmentStateBadge(text: decisionCase.decisionState.displayName, tint: tint)
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.appIcon)
                .help("关闭")
        }
        .padding(AppPalette.spaceL)
    }

    private func decisionSummary(_ decisionCase: DecisionCase) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            Text(decisionCase.decisionState.guidanceText)
                .font(AppPalette.appFont(.title3, weight: .semibold))
                .foregroundStyle(AppPalette.ink)

            HStack(alignment: .top, spacing: 0) {
                InvestmentMetricLabel(title: decisionCase.metricDescription, value: decisionCase.metricLabel)
                Divider().frame(height: 38).padding(.horizontal, AppPalette.spaceL)
                InvestmentMetricLabel(title: "影响对象", value: decisionCase.subjectName)
                Divider().frame(height: 38).padding(.horizontal, AppPalette.spaceL)
                InvestmentMetricLabel(title: "最近评估", value: String(decisionCase.lastEvaluatedAt.prefix(16)))
            }

            Text(decisionCase.detail)
                .font(AppPalette.appFont(.body))
                .foregroundStyle(AppPalette.muted)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppPalette.spaceL)
        .background(AppPalette.controlFill.opacity(0.55), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
    }

    @ViewBuilder
    private func researchSection(_ decisionCase: DecisionCase) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            HStack {
                Text("专项研究")
                    .font(AppPalette.appFont(.headline, weight: .semibold))
                Spacer()
                if model.researchingDecisionCaseID == decisionCase.id {
                    ProgressView().controlSize(.small)
                    Text("研究中")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                }
            }

            if let report = model.lastDecisionCaseResearchReports[decisionCase.id] {
                HStack(alignment: .firstTextBaseline) {
                    InvestmentStateBadge(
                        text: report.suggestedState.displayName,
                        tint: InvestmentIntelligenceStyle.tint(for: report.suggestedState)
                    )
                    Text("生成于 \(String(report.generatedAt.prefix(16)))")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                }
                Text(report.rationale)
                    .font(AppPalette.appFont(.body))
                    .foregroundStyle(AppPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                findingList("支持判断", findings: report.findings, tint: AppPalette.info)
                findingList("反向证据", findings: report.counterFindings, tint: AppPalette.warning)

                if !report.uncertainties.isEmpty {
                    DisclosureGroup("不确定性与数据缺口（\(report.uncertainties.count)）") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(report.uncertainties, id: \.self) { item in
                                Text("• \(item)")
                                    .font(AppPalette.appFont(.subheadline))
                                    .foregroundStyle(AppPalette.muted)
                            }
                        }
                        .padding(.top, AppPalette.spaceS)
                    }
                }

                if !report.evidence.isEmpty {
                    DisclosureGroup("分析依据（\(report.evidence.count)）") {
                        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                            ForEach(report.evidence) { evidence in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(evidence.title)
                                        .font(AppPalette.appFont(.subheadline, weight: .semibold))
                                    Text("\(evidence.sourceName) · \(evidence.publishedAt ?? evidence.retrievedAt)")
                                        .font(AppPalette.appFont(.caption))
                                        .foregroundStyle(AppPalette.muted)
                                }
                            }
                        }
                        .padding(.top, AppPalette.spaceS)
                    }
                }
            } else {
                Text("尚未启动专项研究。系统当前判断来自本地组合指标与基金穿透。")
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
            }

            if let error = model.decisionCaseResearchErrors[decisionCase.id], !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func findingList(_ title: String, findings: [ResearchFinding], tint: Color) -> some View {
        if !findings.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(AppPalette.appFont(.caption, weight: .bold))
                    .foregroundStyle(tint)
                ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                    Text("• \(finding.claim)")
                        .font(AppPalette.appFont(.subheadline))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func reviewSection(_ decisionCase: DecisionCase) -> some View {
        let reviews = model.decisionCaseReviews[decisionCase.id] ?? []
        return VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            HStack {
                Text("复盘")
                    .font(AppPalette.appFont(.headline, weight: .semibold))
                Spacer()
                if decisionCase.lifecycle != .closed {
                    Button("记录复盘") { isShowingReview = true }
                        .buttonStyle(.appSecondary)
                        .controlSize(.small)
                }
            }

            if reviews.isEmpty {
                Text(decisionCase.reviewDueAt.map { "计划于 \(String($0.prefix(16))) 复查" } ?? "关注此事项后会设置复查时间")
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
            } else {
                ForEach(reviews.suffix(3).reversed()) { review in
                    HStack(alignment: .top, spacing: AppPalette.spaceM) {
                        Text(String(review.reviewedAt.prefix(10)))
                            .font(AppPalette.appFont(.caption, design: .monospaced))
                            .foregroundStyle(AppPalette.muted)
                            .frame(width: 82, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(review.conclusion.displayName)
                                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                            Text(review.portfolioOutcome)
                                .font(AppPalette.appFont(.caption))
                                .foregroundStyle(AppPalette.muted)
                        }
                    }
                }
            }
        }
    }

    private func eventHistory(_ decisionCase: DecisionCase) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            DisclosureGroup("状态历史（\(decisionCase.events.count)）") {
                VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                    ForEach(decisionCase.events.reversed()) { event in
                        HStack(alignment: .top, spacing: AppPalette.spaceM) {
                            Text(String(event.at.prefix(16)))
                                .font(AppPalette.appFont(.caption, design: .monospaced))
                                .foregroundStyle(AppPalette.muted)
                                .frame(width: 118, alignment: .leading)
                            Text(event.reason)
                                .font(AppPalette.appFont(.subheadline))
                                .foregroundStyle(AppPalette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, AppPalette.spaceS)
            }
        }
    }

    private func actionBar(_ decisionCase: DecisionCase) -> some View {
        HStack(spacing: AppPalette.spaceS) {
            if decisionCase.lifecycle != .closed {
                if decisionCase.userDisposition == .pending {
                    Button("加入关注") { model.acknowledgeDecisionCase(decisionCase.id) }
                        .buttonStyle(.appPrimary)
                }
                Button {
                    Task { await model.researchDecisionCase(decisionCase.id) }
                } label: {
                    Label("专项研究", systemImage: "brain.head.profile")
                }
                .buttonStyle(.appSecondary)
                .disabled(model.researchingDecisionCaseID == decisionCase.id || !model.trendSettings.provider.isConfigured)
                Button("记录复盘") { isShowingReview = true }
                    .buttonStyle(.appSecondary)
                Spacer()
                Menu {
                    Button("标记已解决") { model.resolveDecisionCase(decisionCase.id) }
                    Button("关闭事项", role: .destructive) { model.closeDecisionCase(decisionCase.id) }
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(.appPrimary)
            }
        }
        .padding(AppPalette.spaceM)
        .background(AppPalette.cardStrong)
    }
}
