import SwiftUI

struct NextHourGuidancePriorityActionRow: View {
    let position: Int
    let action: NextHourGuidanceAction
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                HStack(alignment: .firstTextBaseline, spacing: AppPalette.spaceS) {
                    Text("\(position)")
                        .font(AppPalette.appFont(.caption, weight: .bold, design: .rounded))
                        .foregroundStyle(actionTint)
                        .frame(width: 22, height: 22)
                        .background(actionTint.opacity(AppPalette.accentFill), in: Circle())

                    Text(action.targetName)
                        .font(AppPalette.appFont(.body, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)

                    Text(action.action.displayName)
                        .font(AppPalette.appFont(.footnote, weight: .bold))
                        .foregroundStyle(actionTint)

                    Spacer(minLength: AppPalette.spaceS)

                    TintedCapsuleBadge(
                        text: "把握 \(confidenceText) \(action.confidence)",
                        tint: confidenceTint,
                        font: AppPalette.appFont(.footnote, weight: .semibold),
                        horizontalPadding: 7,
                        verticalPadding: 3,
                        softStrokeOpacity: nil
                    )
                }

                Text(action.instruction)
                    .font(AppPalette.appFont(.subheadline, weight: .medium))
                    .foregroundStyle(AppPalette.ink)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: AppPalette.spaceM) {
                        conditionText("触发", value: action.trigger, systemImage: "scope", tint: AppPalette.info)
                        conditionText("失效", value: action.invalidation, systemImage: "xmark.circle", tint: AppPalette.warning)
                    }

                    VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                        conditionText("触发", value: action.trigger, systemImage: "scope", tint: AppPalette.info)
                        conditionText("失效", value: action.invalidation, systemImage: "xmark.circle", tint: AppPalette.warning)
                    }
                }
            }
            .padding(AppPalette.spaceM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: AppPalette.cardRadius))
            .staticSurface(
                tint: actionTint,
                fill: AppPalette.cardStrong,
                strokeOpacity: AppPalette.strokeSubtle,
                activeStrokeOpacity: 0.40
            )
        }
        .buttonStyle(PressResponsiveButtonStyle())
        .contextMenu {
            Button("查看完整判断依据", systemImage: "doc.text.magnifyingglass", action: onSelect)
        }
        .help("查看 \(action.targetName) 的完整操作理由和证据")
        .accessibilityLabel("优先级 \(position)，\(action.targetName)，\(action.action.displayName)，把握 \(action.confidence)")
        .accessibilityHint("打开完整操作理由、触发条件、失效条件和证据")
    }

    private func conditionText(
        _ title: String,
        value: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        Label {
            Text("\(title)：\(value.isEmpty ? "未给出" : value)")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionTint: Color {
        switch action.action {
        case .buy, .buySmall:
            AppPalette.marketGain
        case .sell, .reduceSmall:
            AppPalette.marketLoss
        case .hold, .watch, .wait, .avoidChasing:
            AppPalette.info
        }
    }

    private var confidenceText: String {
        switch action.confidence {
        case 85...:
            "很高"
        case 70...:
            "较高"
        case 55...:
            "中等"
        default:
            "偏低"
        }
    }

    private var confidenceTint: Color {
        switch action.confidence {
        case 70...:
            AppPalette.positive
        case 55...:
            AppPalette.info
        default:
            AppPalette.warning
        }
    }
}
