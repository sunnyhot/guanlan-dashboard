import SwiftUI

struct CloseReviewTomorrowWatchView: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            Label("明日关注", systemImage: "binoculars.fill")
                .font(AppPalette.appFont(.headline, weight: .bold))
                .foregroundStyle(AppPalette.ink)

            if items.isEmpty {
                Label("暂无需要优先验证的事项", systemImage: "checkmark.circle")
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
            } else {
                VStack(spacing: AppPalette.spaceS) {
                    ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { offset, item in
                        HStack(alignment: .center, spacing: AppPalette.spaceS) {
                            Text("\(offset + 1)")
                                .font(AppPalette.appFont(.caption, weight: .bold, design: .rounded))
                                .foregroundStyle(AppPalette.info)
                                .frame(width: 22, height: 22)
                                .background(
                                    AppPalette.info.opacity(AppPalette.accentFill),
                                    in: Circle()
                                )
                                .monospacedDigit()
                            Text(item)
                                .font(AppPalette.appFont(.subheadline))
                                .foregroundStyle(AppPalette.ink)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: AppPalette.spaceS)
                        }
                        .padding(.horizontal, AppPalette.spaceM)
                        .padding(.vertical, AppPalette.spaceS)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .staticSurface(
                            tint: AppPalette.info,
                            fill: AppPalette.cardStrong,
                            strokeOpacity: AppPalette.strokeSubtle,
                            activeStrokeOpacity: 0.40
                        )
                    }
                }
            }
        }
    }
}
