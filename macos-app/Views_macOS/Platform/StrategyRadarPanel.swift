import SwiftUI

// MARK: - StrategyRadarPanel

struct StrategyRadarPanel: View {
    let summary: StrategyRadarSummary

    var body: some View {
        SectionCard(title: "主理人策略雷达", subtitle: summary.headline, icon: "radar") {
            ViewThatFits(in: .horizontal) {
                radarStrip
                    .frame(minWidth: 740)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(minimum: 180), spacing: 0, alignment: .top),
                        GridItem(.flexible(minimum: 180), spacing: 0, alignment: .top)
                    ],
                    alignment: .leading,
                    spacing: 0
                ) {
                    ForEach(summary.items) { item in
                        StrategyRadarTile(item: item)
                    }
                }
                .radarGroupSurface()

                VStack(spacing: 0) {
                    ForEach(summary.items) { item in
                        StrategyRadarTile(item: item)
                    }
                }
                .radarGroupSurface()
            }
        }
    }

    private var radarStrip: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(summary.items) { item in
                StrategyRadarTile(item: item)

                if item.id != summary.items.last?.id {
                    Divider()
                        .padding(.vertical, AppPalette.spaceS)
                }
            }
        }
        .radarGroupSurface()
    }
}

struct StrategyRadarTile: View {
    let item: StrategyRadarItem

    private var scoreTint: Color {
        if item.score >= 70 {
            return AppPalette.positive
        }
        if item.score >= 40 {
            return AppPalette.warning
        }
        return AppPalette.muted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            HStack(alignment: .firstTextBaseline, spacing: AppPalette.spaceS) {
                Text(item.title)
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Spacer(minLength: 0)
                Text("\(item.score)")
                    .font(AppPalette.appFont(.body, weight: .bold, design: .rounded))
                    .foregroundStyle(scoreTint)
                    .monospacedDigit()
            }

            HStack(alignment: .firstTextBaseline, spacing: AppPalette.spaceS) {
                Text(item.metric)
                    .font(AppPalette.appFont(.title3, weight: .bold, design: .rounded))
                    .foregroundStyle(scoreTint)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Text(item.detail)
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }

            ProgressView(value: Double(item.score), total: 100)
                .progressViewStyle(.linear)
                .tint(scoreTint)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .padding(.horizontal, AppPalette.spaceM)
        .padding(.vertical, AppPalette.spaceS + 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityValue("\(item.metric)，\(item.detail)，\(item.score) 分")
    }
}

private extension View {
    func radarGroupSurface() -> some View {
        background(
            AppPalette.cardStrong.opacity(0.58),
            in: RoundedRectangle(cornerRadius: AppPalette.controlRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                .stroke(AppPalette.line.opacity(AppPalette.borderLight), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppPalette.controlRadius))
    }
}
