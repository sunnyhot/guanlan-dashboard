import SwiftUI

struct NextHourGuidanceDecisionConsole: View {
    let report: NextHourGuidanceReport

    @State private var selectedAction: NextHourGuidanceAction?
    @State private var isShowingEvidence = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                HStack(alignment: .firstTextBaseline, spacing: AppPalette.spaceS) {
                    TintedCapsuleBadge(
                        text: report.posture.displayName,
                        tint: postureTint,
                        font: AppPalette.appFont(.footnote, weight: .bold),
                        horizontalPadding: 8,
                        verticalPadding: 3,
                        softStrokeOpacity: nil
                    )
                    TermHelpView(term: .posture)

                    Text("有效至 \(String(report.validUntil.suffix(5)))")
                        .font(AppPalette.appFont(.footnote, weight: .semibold))
                        .foregroundStyle(AppPalette.brand)

                    Text("\(report.completeEvidenceLedger.count) 条依据")
                        .font(AppPalette.appFont(.footnote, design: .rounded))
                        .foregroundStyle(AppPalette.muted)

                    Spacer(minLength: AppPalette.spaceS)

                    Text(report.scope.displayName)
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                }

                Text(report.headline)
                    .font(AppPalette.appFont(.title2, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                Text(report.summary)
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if report.disposition == .analysisOnly {
                Label(
                    "当前证据只支持研究或持有建议；系统不会把证据不足包装成买卖指令。",
                    systemImage: "shield.lefthalf.filled"
                )
                .font(AppPalette.appFont(.caption, weight: .semibold))
                .foregroundStyle(AppPalette.info)
            }

            NextHourGuidancePriorityActionsView(
                actions: report.actions,
                onSelect: select
            )

            HStack(spacing: AppPalette.spaceM) {
                Button("查看完整依据", systemImage: "doc.text.magnifyingglass", action: showEvidence)
                    .buttonStyle(.appSecondary)
                    .controlSize(.small)
                    .popover(isPresented: $isShowingEvidence, arrowEdge: .bottom) {
                        NextHourGuidanceEvidencePopover(report: report)
                    }

                Text("生成于 \(String(report.generatedAt.prefix(16))) · 仅在当前有效时段内参考")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)

                Spacer(minLength: AppPalette.spaceS)
            }

            // W5.3:昨日关注回指上移为盘中区段第一条可见内容,决策台内不再重复。

            Text(report.disclaimer)
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
        }
        .sheet(item: $selectedAction) { action in
            NextHourGuidanceActionDetailSheet(
                action: action,
                teamEvidence: report.teamEvidence(for: action),
                evidence: report.supportingEvidence(for: action)
            )
        }
    }

    private var postureTint: Color {
        switch report.posture {
        case .defensive:
            AppPalette.warning
        case .balanced:
            AppPalette.info
        case .selective:
            AppPalette.brand
        case .opportunistic:
            AppPalette.positive
        }
    }

    private func select(_ action: NextHourGuidanceAction) {
        selectedAction = action
    }

    private func showEvidence() {
        isShowingEvidence = true
    }

}
