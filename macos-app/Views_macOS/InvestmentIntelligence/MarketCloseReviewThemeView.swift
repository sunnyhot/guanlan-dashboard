import SwiftUI

struct MarketCloseReviewThemeView: View {
    let strongThemes: [MarketCloseReviewSnapshot.ThemeItem]
    let weakThemes: [MarketCloseReviewSnapshot.ThemeItem]

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            Label("主线与风险", systemImage: "point.3.connected.trianglepath.dotted")
                .font(AppPalette.appFont(.headline, weight: .bold))
                .foregroundStyle(AppPalette.ink)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppPalette.spaceL) {
                    themeColumn(
                        title: "相对强势",
                        emptyText: "没有达到证据门槛的强势主线",
                        items: strongThemes,
                        tint: AppPalette.positive
                    )
                    Divider()
                    themeColumn(
                        title: "偏弱与风险",
                        emptyText: "没有明确的偏弱主线",
                        items: weakThemes,
                        tint: AppPalette.warning
                    )
                }
                VStack(alignment: .leading, spacing: AppPalette.spaceL) {
                    themeColumn(
                        title: "相对强势",
                        emptyText: "没有达到证据门槛的强势主线",
                        items: strongThemes,
                        tint: AppPalette.positive
                    )
                    themeColumn(
                        title: "偏弱与风险",
                        emptyText: "没有明确的偏弱主线",
                        items: weakThemes,
                        tint: AppPalette.warning
                    )
                }
            }
        }
    }

    private func themeColumn(
        title: String,
        emptyText: String,
        items: [MarketCloseReviewSnapshot.ThemeItem],
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            Text(title)
                .font(AppPalette.appFont(.caption, weight: .bold))
                .foregroundStyle(tint)
            if items.isEmpty {
                Text(emptyText)
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
            } else {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: AppPalette.spaceS) {
                            Text(item.name)
                                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                                .foregroundStyle(AppPalette.ink)
                            Text(item.confidenceText)
                                .font(AppPalette.appFont(.caption, design: .rounded))
                                .foregroundStyle(tint)
                        }
                        Text(item.rationale)
                            .font(AppPalette.appFont(.subheadline))
                            .foregroundStyle(AppPalette.muted)
                            .lineSpacing(3)
                            .lineLimit(2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
