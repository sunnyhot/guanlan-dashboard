#if os(iOS)
import SwiftUI

struct IOSDecisionCaseDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let caseID: UUID
    let onReview: () -> Void

    private var decisionCase: DecisionCase? {
        model.decisionCases.first { $0.id == caseID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let decisionCase {
                    VStack(alignment: .leading, spacing: IOSDesign.spaceL) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(decisionCase.decisionState.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(iosDecisionTint(decisionCase.decisionState))
                            Spacer()
                            Text(decisionCase.metricLabel)
                                .font(.title2.weight(.bold).monospacedDigit())
                                .foregroundStyle(iosDecisionTint(decisionCase.decisionState))
                        }

                        Text(decisionCase.decisionState.guidanceText)
                            .font(.title3.weight(.semibold))
                        Text(decisionCase.detail)
                            .font(.body)
                            .foregroundStyle(IOSDesign.muted)

                        Divider()
                        metricRow("影响对象", decisionCase.subjectName)
                        metricRow(decisionCase.metricDescription, decisionCase.metricLabel)
                        metricRow("最近评估", String(decisionCase.lastEvaluatedAt.prefix(16)))
                        metricRow("下次复查", decisionCase.reviewDueAt.map { String($0.prefix(16)) } ?? "关注后设定")

                        Divider()
                        Text("专项研究").font(.headline)
                        if let report = model.lastDecisionCaseResearchReports[decisionCase.id] {
                            Text(report.rationale).font(.body)
                            ForEach(report.findings, id: \.claim) { finding in
                                Label(finding.claim, systemImage: "checkmark.circle")
                                    .font(.subheadline)
                                    .foregroundStyle(IOSDesign.muted)
                            }
                            if !report.evidence.isEmpty {
                                DisclosureGroup("分析依据（\(report.evidence.count)）") {
                                    ForEach(report.evidence) { evidence in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(evidence.title).font(.subheadline.weight(.medium))
                                            Text(evidence.sourceName).font(.caption).foregroundStyle(IOSDesign.muted)
                                        }
                                        .padding(.vertical, 4)
                                    }
                                }
                            }
                        } else {
                            Text("尚未启动专项研究。当前判断来自组合指标与基金穿透。")
                                .font(.subheadline)
                                .foregroundStyle(IOSDesign.muted)
                        }

                        if let error = model.decisionCaseResearchErrors[decisionCase.id] {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.subheadline)
                                .foregroundStyle(AppPalette.warning)
                        }

                        if let reviews = model.decisionCaseReviews[decisionCase.id], !reviews.isEmpty {
                            Divider()
                            Text("最近复盘").font(.headline)
                            ForEach(reviews.suffix(3).reversed()) { review in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(review.conclusion.displayName).font(.subheadline.weight(.semibold))
                                    Text("\(String(review.reviewedAt.prefix(10))) · \(review.portfolioOutcome)")
                                        .font(.caption)
                                        .foregroundStyle(IOSDesign.muted)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle(decisionCase?.title ?? "决策事项")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                if let decisionCase, decisionCase.lifecycle != .closed {
                    ToolbarItemGroup(placement: .bottomBar) {
                        if decisionCase.userDisposition == .pending {
                            Button("关注") { model.acknowledgeDecisionCase(decisionCase.id) }
                        }
                        Button("专项研究") { Task { await model.researchDecisionCase(decisionCase.id) } }
                            .disabled(model.researchingDecisionCaseID == decisionCase.id || !model.trendSettings.provider.isConfigured)
                        Spacer()
                        Button("复盘") {
                            dismiss()
                            onReview()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func metricRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.subheadline).foregroundStyle(IOSDesign.muted)
            Spacer()
            Text(value).font(.subheadline.weight(.semibold))
        }
    }
}

struct IOSDecisionReviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let caseID: UUID

    @State private var conclusion: DecisionReviewConclusion = .unresolved
    @State private var lessons = ""
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("评估原判断与后续事实是否一致，不用最终涨跌简单判对错。")
                        .font(.subheadline)
                        .foregroundStyle(IOSDesign.muted)
                }
                Section("复盘结论") {
                    Picker("结论", selection: $conclusion) {
                        ForEach(DecisionReviewConclusion.allCases, id: \.self) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                }
                Section("可复用经验") {
                    TextField("记录以后可以复用的判断经验", text: $lessons, axis: .vertical)
                        .lineLimit(3...6)
                }
                if !errorMessage.isEmpty {
                    Section { Text(errorMessage).foregroundStyle(AppPalette.warning) }
                }
            }
            .navigationTitle("决策复盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if model.performReview(for: caseID, conclusion: conclusion, lessons: lessons) {
                            dismiss()
                        } else {
                            errorMessage = model.lastDecisionReviewError.isEmpty ? "复盘未能保存" : model.lastDecisionReviewError
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
#endif
