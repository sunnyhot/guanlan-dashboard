import SwiftUI

/// 全市场收盘复盘；不读取个人持仓或决策事项。
struct MarketCloseReviewSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let review = model.marketCloseReview

        SectionCard(
            title: "今日收盘复盘",
            subtitle: review.subtitle,
            icon: "sunset.fill"
        ) {
            VStack(alignment: .leading, spacing: AppPalette.spaceL) {
                header(review)

                if review.state == .scanning {
                    HStack(spacing: AppPalette.spaceS) {
                        ProgressView().controlSize(.small)
                        Text(model.trendProgressLogs.last?.message ?? "正在扫描市场…")
                            .font(AppPalette.appFont(.subheadline, weight: .medium))
                            .foregroundStyle(AppPalette.muted)
                    }
                }

                if !review.marketPulse.isEmpty {
                    Divider()
                    marketPulse(review.marketPulse)
                }

                if !review.strongThemes.isEmpty || !review.weakThemes.isEmpty {
                    Divider()
                    themeReview(review)
                }

                if !review.tomorrowWatch.isEmpty {
                    Divider()
                    tomorrowWatch(review.tomorrowWatch)
                }

                HStack(spacing: AppPalette.spaceS) {
                    Image(systemName: "shield.lefthalf.filled")
                        .accessibilityHidden(true)
                    Text(review.dataBoundary)
                    if let evidenceText = review.evidenceText {
                        Text("·")
                        Text(evidenceText)
                    }
                }
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func header(_ review: MarketCloseReviewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            Text(review.eyebrow)
                .font(AppPalette.appFont(.caption, weight: .bold))
                .foregroundStyle(headerTint(review.state))
            Text(review.headline)
                .font(AppPalette.appFont(.title2, weight: .bold))
                .foregroundStyle(AppPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(review.summary)
                .font(AppPalette.appFont(.subheadline))
                .foregroundStyle(AppPalette.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func marketPulse(_ items: [MarketCloseReviewSnapshot.PulseItem]) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            Label("市场温度", systemImage: "waveform.path.ecg")
                .font(AppPalette.appFont(.subheadline, weight: .bold))
                .foregroundStyle(AppPalette.ink)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220), spacing: AppPalette.spaceM)],
                alignment: .leading,
                spacing: AppPalette.spaceM
            ) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: AppPalette.spaceS) {
                            Text(item.name)
                                .font(AppPalette.appFont(.subheadline, weight: .bold))
                                .foregroundStyle(AppPalette.ink)
                            Spacer(minLength: 0)
                            Text(item.direction.dashboardText)
                                .font(AppPalette.appFont(.caption, weight: .bold))
                                .foregroundStyle(directionTint(item.direction))
                        }
                        Text("\(item.category) · 置信度 \(item.confidenceText)")
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                        Text(item.rationale)
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                            .lineLimit(2)
                    }
                    .padding(AppPalette.spaceM)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .staticSurface(tint: directionTint(item.direction))
                }
            }
        }
    }

    private func themeReview(_ review: MarketCloseReviewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            Label("主线与风险", systemImage: "point.3.connected.trianglepath.dotted")
                .font(AppPalette.appFont(.subheadline, weight: .bold))
                .foregroundStyle(AppPalette.ink)

            HStack(alignment: .top, spacing: AppPalette.spaceL) {
                themeColumn(
                    title: "相对强势",
                    emptyText: "没有达到证据门槛的强势主线",
                    items: review.strongThemes,
                    tint: AppPalette.positive
                )
                Divider()
                themeColumn(
                    title: "偏弱与风险",
                    emptyText: "没有明确的偏弱主线",
                    items: review.weakThemes,
                    tint: AppPalette.warning
                )
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
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                            .lineLimit(2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tomorrowWatch(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            Label("次日观察", systemImage: "binoculars.fill")
                .font(AppPalette.appFont(.subheadline, weight: .bold))
                .foregroundStyle(AppPalette.ink)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Label(item, systemImage: "circle.fill")
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
                    .symbolRenderingMode(.hierarchical)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func headerTint(_ state: MarketCloseReviewSnapshot.State) -> Color {
        switch state {
        case .ready: AppPalette.positive
        case .scanning, .awaitingClose: AppPalette.info
        case .noScan, .stale: AppPalette.warning
        }
    }

    private func directionTint(_ direction: TrendDirection) -> Color {
        switch direction {
        case .bullish, .neutralPositive: AppPalette.positive
        case .neutral: AppPalette.info
        case .neutralNegative, .bearish: AppPalette.warning
        case .uncertain: AppPalette.muted
        }
    }
}
