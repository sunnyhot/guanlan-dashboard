import SwiftUI

// iOS 端:DecisionCase 卡片。
// 与 macOS 版对齐信息密度,但用 IOSDesign 杂志型排版(项目惯例:两端各自实现)。
// 见 Views_iOS/IOSPortfolioDiagnosticsPanel.swift 的共享约定注释。

struct IOSDecisionCaseCard: View {
    let decisionCase: DecisionCase
    let onAcknowledge: () -> Void
    let onResolve: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            HStack(alignment: .top, spacing: IOSDesign.spaceS) {
                stateBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text(decisionCase.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(IOSDesign.ink)
                    Text(decisionCase.metricDescription + " " + decisionCase.metricLabel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(stateColor)
                }
                Spacer()
            }

            Text(decisionCase.detail)
                .font(.system(size: 13))
                .foregroundColor(IOSDesign.muted)
                .fixedSize(horizontal: false, vertical: true)

            if decisionCase.userDisposition != .closed {
                HStack(spacing: IOSDesign.spaceS) {
                    if decisionCase.userDisposition == .pending {
                        Button("关注") { onAcknowledge() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Button("已处理") { onResolve() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Spacer()
                    Button { onClose() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(IOSDesign.muted)
                }
            }
        }
        .padding(IOSDesign.spaceM)
        .background(IOSDesign.card, in: RoundedRectangle(cornerRadius: IOSDesign.radiusS))
    }

    private var stateBadge: some View {
        Text(stateLabel)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(stateColor, in: Capsule())
    }

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
        case .stable: return IOSDesign.accent
        case .watch, .prepare, .adjustReview, .exitReview: return IOSDesign.accent
        case .insufficientEvidence: return IOSDesign.muted
        }
    }
}
