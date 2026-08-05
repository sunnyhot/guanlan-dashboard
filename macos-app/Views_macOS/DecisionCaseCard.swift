import SwiftUI

// macOS 端:DecisionCase 卡片。
//
// 展示单个集中度风险决策事项:状态徽章、标题、指标、详情、操作按钮。
// 遵循项目惯例:红涨绿跌用 AppPalette(本卡片主要用 warning/positive/muted)。
// 见 docs/ai-pipeline-baseline.md 第 9 节。

struct DecisionCaseCard: View {
    let decisionCase: DecisionCase
    let onAcknowledge: () -> Void
    let onResolve: () -> Void
    let onClose: () -> Void

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

            // 操作按钮(用户已关闭的不显示)
            if decisionCase.userDisposition != .closed {
                HStack(spacing: AppPalette.spaceS) {
                    if decisionCase.userDisposition == .pending {
                        Button("关注", action: onAcknowledge)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Button("已处理", action: onResolve)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
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
