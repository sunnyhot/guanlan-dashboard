import SwiftUI

struct InvestmentDirectionCard: View {
    let signal: InvestmentDirectionSignal
    @Binding var selectedSignal: InvestmentDirectionSignal?

    var body: some View {
        Button {
            selectedSignal = signal
        } label: {
            VStack(alignment: .leading, spacing: AppPalette.spaceXS) {
                HStack(alignment: .firstTextBaseline, spacing: AppPalette.spaceXS) {
                    Text(signal.name)
                        .font(AppPalette.appFont(.subheadline, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                    Spacer(minLength: AppPalette.spaceXS)
                    Label(
                        signal.recommendation.displayName,
                        systemImage: signal.recommendation.systemImage
                    )
                    .font(AppPalette.appFont(.caption, weight: .semibold))
                    .foregroundStyle(signal.recommendation.tint)
                    .lineLimit(1)
                }

                HStack(spacing: AppPalette.spaceS) {
                    Text(signal.dimension.displayName)
                    Text("置信度 \(signal.confidence.normalizedScore)%")
                }
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)

                Text(signal.rationale)
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)

                HStack(spacing: AppPalette.spaceS) {
                    Label("\(signal.evidenceCount) 条依据", systemImage: "doc.text.magnifyingglass")
                    if signal.independentExternalSourceCount > 0 {
                        Label(
                            "\(signal.independentExternalSourceCount) 个独立来源",
                            systemImage: "point.3.connected.trianglepath.dotted"
                        )
                    }
                    Spacer(minLength: AppPalette.spaceXS)
                    Label("查看详情", systemImage: "arrow.up.right.square")
                        .foregroundStyle(AppPalette.brand)
                }
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
                .lineLimit(1)
            }
            .padding(AppPalette.spaceS)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                AppPalette.cardStrong,
                in: RoundedRectangle(cornerRadius: AppPalette.controlRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                    .stroke(signal.recommendation.tint.opacity(0.24), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: AppPalette.controlRadius))
        }
        .buttonStyle(.plain)
        .accessibilityHint("打开完整判断依据、触发条件和反向证据")
    }
}
