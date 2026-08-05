import SwiftUI

// macOS 端:DecisionCase 卡片。
//
// 展示单个集中度风险决策事项:状态徽章、标题、指标、详情、操作按钮。
// 遵循项目惯例:红涨绿跌用 AppPalette(本卡片主要用 warning/positive/muted)。
// 见 docs/ai-pipeline-baseline.md 第 9 节。

struct DecisionCaseCard: View {
    let decisionCase: DecisionCase
    let isResearching: Bool
    let researchReport: DecisionCaseResearchReport?
    let onAcknowledge: () -> Void
    let onResolve: () -> Void
    let onClose: () -> Void
    let onResearch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            // 标题行:状态徽章 + 标题 + 指标
            HStack(alignment: .top, spacing: AppPalette.spaceS) {
                stateBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text(decisionCase.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppPalette.ink)
                    Text(decisionCase.metricDescription + " " + decisionCase.metricLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(metricColor)
                }
                Spacer()
            }

            // 详情
            Text(decisionCase.detail)
                .font(.system(size: 12))
                .foregroundColor(AppPalette.muted)
                .fixedSize(horizontal: false, vertical: true)

            // 研究报告展示(Slice 3)
            if let report = researchReport {
                researchReportView(report)
            }

            // 研究中进度(Slice 3)
            if isResearching {
                HStack(spacing: AppPalette.spaceS) {
                    ProgressView().controlSize(.small)
                    Text("深度研究中…")
                        .font(.system(size: 11))
                        .foregroundColor(AppPalette.muted)
                }
            }

            // 操作按钮(用户已关闭的不显示)
            // 用项目统一的 AppActionButtonStyle(见 UIExperienceRegressionTests 约定)
            if decisionCase.userDisposition != .closed {
                HStack(spacing: AppPalette.spaceS) {
                    if decisionCase.userDisposition == .pending {
                        Button("关注", action: onAcknowledge)
                            .buttonStyle(.appSecondary)
                            .controlSize(.small)
                    }
                    Button("已处理", action: onResolve)
                        .buttonStyle(.appSecondary)
                        .controlSize(.small)
                    // Slice 3:深度研究按钮(只在有 AI Provider 时有意义,UI 统一显示)
                    Button(action: onResearch) {
                        Label("深度研究", systemImage: "brain.head.profile")
                    }
                    .buttonStyle(.appSecondary)
                    .controlSize(.small)
                    .disabled(isResearching)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.appIcon)
                    .foregroundColor(AppPalette.muted)
                    .help("关闭(不再关注)")
                }
            }
        }
        .padding(AppPalette.spaceM)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                .stroke(stateColor.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - 子视图

    @ViewBuilder
    private func researchReportView(_ report: DecisionCaseResearchReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: AppPalette.spaceS) {
                Image(systemName: "lightbulb")
                    .foregroundColor(AppPalette.brand)
                    .font(.system(size: 10))
                Text("AI 研究建议:\(report.suggestedState.rawValue)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppPalette.ink)
            }
            if !report.findings.isEmpty {
                Text("支持:\(report.findings.map(\.claim).joined(separator: "、"))")
                    .font(.system(size: 11))
                    .foregroundColor(AppPalette.muted)
                    .lineLimit(2)
            }
            if !report.counterFindings.isEmpty {
                Text("反证:\(report.counterFindings.map(\.claim).joined(separator: "、"))")
                    .font(.system(size: 11))
                    .foregroundColor(AppPalette.muted)
                    .lineLimit(2)
            }
            Text(report.rationale)
                .font(.system(size: 11))
                .foregroundColor(AppPalette.muted)
                .lineLimit(3)
        }
        .padding(AppPalette.spaceS)
        .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
    }

    private var stateBadge: some View {
        Text(stateLabel)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(stateColor, in: RoundedRectangle(cornerRadius: AppPalette.badgeRadius))
    }

    // MARK: - 派生

    private var stateLabel: String {
        switch decisionCase.decisionState {
        case .stable: return "正常"
        case .watch: return "观察"
        case .prepare: return "准备"
        case .adjustReview: return "建议复核"
        case .exitReview: return "退出复核"
        case .insufficientEvidence: return "数据不足"
        }
    }

    private var stateColor: Color {
        switch decisionCase.decisionState {
        case .stable: return AppPalette.positive
        case .watch: return AppPalette.warning
        case .prepare: return AppPalette.warning
        case .adjustReview: return AppPalette.warning
        case .exitReview: return AppPalette.warning
        case .insufficientEvidence: return AppPalette.muted
        }
    }

    private var metricColor: Color {
        switch decisionCase.decisionState {
        case .stable: return AppPalette.positive
        case .insufficientEvidence: return AppPalette.muted
        default: return AppPalette.warning
        }
    }
}
