import SwiftUI

/// 展示收盘时冻结的个人组合表现与持仓归因。
struct MarketCloseReviewSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var isShowingDetails = false

    var body: some View {
        let review = model.marketCloseReview
        let freshness = model.marketCloseReviewFreshness

        SectionCard(
            title: model.marketCloseReviewTitle,
            subtitle: isGeneratingCloseReview ? review.subtitle : freshness.subtitleText,
            icon: "sunset.fill",
            trailing: {
                Spacer()
                if !isGeneratingCloseReview {
                    InvestmentStateBadge(
                        text: freshness.badgeText,
                        tint: freshnessTint(freshness)
                    )
                }
                Button {
                    model.startTrendAnalysisFromUser(withExpectation: .closeReview)
                } label: {
                    Label(
                        closeReviewButtonTitle(freshness),
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
                .disabled(!model.trendSettings.provider.isConfigured)
            }
        ) {
            VStack(alignment: .leading, spacing: AppPalette.spaceL) {
                if !model.trendSettings.provider.isConfigured {
                    Label(
                        "未配置 AI 模型：收盘复盘的自动更新与手动生成都需要先在设置中配置。",
                        systemImage: "exclamationmark.circle"
                    )
                    .font(AppPalette.appFont(.caption, weight: .medium))
                    .foregroundStyle(AppPalette.warning)
                }

                MarketCloseReviewHeaderView(review: review)

                // 进度统一在页面顶部的 TrendLiveLogPanel 展示（唯一进度区）。

                if let portfolioReview = review.portfolioReview {
                    CloseReviewMetricsView(review: portfolioReview)
                } else {
                    Label(
                        "尚未刷新个人持仓，暂时无法生成组合层复盘。",
                        systemImage: "exclamationmark.circle"
                    )
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
                    .padding(AppPalette.spaceM)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .staticSurface(
                        tint: AppPalette.warning,
                        fill: AppPalette.cardStrong,
                        strokeOpacity: AppPalette.strokeSubtle,
                        activeStrokeOpacity: 0.40
                    )
                }

                PortfolioCloseReviewView(
                    review: review.portfolioReview,
                    tomorrowWatch: review.tomorrowWatch
                )

                HStack(spacing: AppPalette.spaceM) {
                    Button(
                        "查看完整复盘",
                        systemImage: "doc.text.magnifyingglass",
                        action: showDetails
                    )
                    .buttonStyle(.appSecondary)
                    .controlSize(.small)

                    Text(detailSummary(for: review))
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(1)

                    Spacer(minLength: AppPalette.spaceS)
                }
            }
        }
        .sheet(isPresented: $isShowingDetails) {
            MarketCloseReviewDetailSheet(review: review)
        }
    }

    private func showDetails() {
        isShowingDetails = true
    }

    /// 只显示真正由收盘复盘入口触发的进度。市场雷达即使因合并约束回退成
    /// effective `.full`，也不能让这个板块看起来正在重做收盘复盘。
    private var isGeneratingCloseReview: Bool {
        guard model.trendGenerationState == .generating else { return false }
        return model.trendResearchRequestedScope == .closeReview
    }

    /// W3.7:复盘按钮三态——运行中 / 已排队 / 语义化空闲标题。
    private func closeReviewButtonTitle(_ freshness: MarketCloseReviewFreshness) -> String {
        if isGeneratingCloseReview { return "复盘中…" }
        if model.queuedUserRequestedScope == .closeReview { return "已排队" }
        return freshness.actionTitle
    }

    /// 今日已复盘 = 正向；等待晚间/即将自动 = 中性信息；自动尝试未成功或未开启 = 弱化/警示。
    private func freshnessTint(_ freshness: MarketCloseReviewFreshness) -> Color {
        switch freshness.phase {
        case .generatedToday:
            return AppPalette.positive
        case .waitingForTonight:
            return AppPalette.info
        case .tonightUnfinished(autoAttempted: true):
            return AppPalette.warning
        case .tonightUnfinished(autoAttempted: false):
            return freshness.autoAnalysisEnabled ? AppPalette.info : AppPalette.muted
        }
    }

    private func detailSummary(for review: MarketCloseReviewSnapshot) -> String {
        let themeCount = review.strongThemes.count + review.weakThemes.count
        let holdingCount = review.portfolioReview?.holdingImpacts.count ?? 0
        if review.marketPulse.isEmpty && themeCount == 0 {
            return "持仓 \(holdingCount) 项 · 明日关注 \(review.tomorrowWatch.count) 项"
        }
        return "市场温度 \(review.marketPulse.count) 项 · 主线风险 \(themeCount) 项 · 持仓 \(holdingCount) 项"
    }
}

