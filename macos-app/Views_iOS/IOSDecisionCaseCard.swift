#if os(iOS)
import SwiftUI

struct IOSDecisionCaseCard: View {
    let decisionCase: DecisionCase
    let isResearching: Bool
    let researchReport: DecisionCaseResearchReport?
    let onOpen: () -> Void
    let onAcknowledge: () -> Void
    let onResolve: () -> Void
    let onClose: () -> Void
    let onResearch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(decisionCase.title)
                            .font(.headline)
                            .foregroundStyle(IOSDesign.ink)
                        Spacer()
                        Text(decisionCase.metricLabel)
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(iosDecisionTint(decisionCase.decisionState))
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(IOSDesign.muted)
                    }
                    HStack(spacing: IOSDesign.spaceS) {
                        Text(decisionCase.decisionState.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(iosDecisionTint(decisionCase.decisionState))
                        Text(decisionCase.lifecycle.displayName)
                            .font(.caption)
                            .foregroundStyle(IOSDesign.muted)
                    }
                    Text(decisionCase.detail)
                        .font(.subheadline)
                        .foregroundStyle(IOSDesign.muted)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: IOSDesign.spaceS) {
                if isResearching {
                    ProgressView().controlSize(.small)
                    Text("研究中…").font(.caption).foregroundStyle(IOSDesign.muted)
                } else if researchReport != nil {
                    Label("已有专项研究", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(IOSDesign.muted)
                }
                Spacer()
                if decisionCase.userDisposition == .pending {
                    Button("关注", action: onAcknowledge)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button("研究", action: onResearch)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isResearching)
                Menu {
                    Button("标记已解决", action: onResolve)
                    Button("关闭事项", role: .destructive, action: onClose)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .padding(IOSDesign.spaceM)
        .background(IOSDesign.card, in: RoundedRectangle(cornerRadius: IOSDesign.radiusS))
    }
}

func iosDecisionTint(_ state: PortfolioDecisionState) -> Color {
    switch state {
    case .stable: return AppPalette.positive
    case .watch: return AppPalette.info
    case .prepare, .adjustReview, .exitReview: return AppPalette.warning
    case .insufficientEvidence: return IOSDesign.muted
    }
}
#endif
