import SwiftUI

struct DecisionReviewSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let caseID: UUID

    @State private var conclusion: DecisionReviewConclusion = .unresolved
    @State private var lessons = ""
    @State private var saveError = ""

    private var decisionCase: DecisionCase? {
        model.decisionCases.first { $0.id == caseID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            VStack(alignment: .leading, spacing: 5) {
                Text("决策复盘")
                    .font(AppPalette.appFont(.title2, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                Text("评估原判断和后续事实是否一致，不用最终涨跌简单判对错。")
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
            }

            if let decisionCase {
                HStack(spacing: AppPalette.spaceL) {
                    InvestmentMetricLabel(title: "原判断", value: decisionCase.decisionState.displayName)
                    InvestmentMetricLabel(title: decisionCase.metricDescription, value: decisionCase.metricLabel)
                    InvestmentMetricLabel(title: "事项状态", value: decisionCase.lifecycle.displayName)
                }
                .padding(AppPalette.spaceM)
                .background(AppPalette.controlFill.opacity(0.55), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
            }

            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                Text("复盘结论")
                    .font(AppPalette.appFont(.headline, weight: .semibold))
                Picker("复盘结论", selection: $conclusion) {
                    ForEach(DecisionReviewConclusion.allCases, id: \.self) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280, alignment: .leading)
                Text(conclusionHelp)
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
            }

            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                Text("可复用经验（可选）")
                    .font(AppPalette.appFont(.headline, weight: .semibold))
                TextEditor(text: $lessons)
                    .font(AppPalette.appFont(.body))
                    .frame(minHeight: 90)
                    .padding(6)
                    .background(AppPalette.controlFill.opacity(0.5), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                            .stroke(AppPalette.muted.opacity(0.18), lineWidth: 1)
                    )
            }

            if !saveError.isEmpty {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.warning)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.appSecondary)
                Button("保存复盘") {
                    if model.performReview(for: caseID, conclusion: conclusion, lessons: lessons) {
                        dismiss()
                    } else {
                        saveError = model.lastDecisionReviewError.isEmpty ? "复盘未能保存，请重试。" : model.lastDecisionReviewError
                    }
                }
                .buttonStyle(.appPrimary)
            }
        }
        .padding(AppPalette.spaceL)
        .frame(width: 500)
    }

    private var conclusionHelp: String {
        switch conclusion {
        case .supported: return "后续事实充分支持原风险判断，继续按原节奏监控。"
        case .partiallySupported: return "部分前提成立，但需要调整判断边界。"
        case .contradicted: return "关键事实推翻原判断，事项将结束。"
        case .unresolved: return "条件尚未触发，当前无法形成结论。"
        case .invalidatedBeforeEvaluation: return "复盘前事项已因条件变化失效。"
        case .insufficientData: return "现有数据不足，系统会缩短复查周期。"
        }
    }
}
