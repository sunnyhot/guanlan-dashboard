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
                    model.startTrendAnalysis(userInitiated: true, scope: .closeReview)
                } label: {
                    Label(
                        isGeneratingCloseReview ? "复盘中…" : freshness.actionTitle,
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
                .disabled(
                    !model.trendSettings.provider.isConfigured
                    || model.trendGenerationState == .generating
                )
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

                if isGeneratingCloseReview {
                    TrendResearchProgressCard(
                        message: model.trendProgressLogs.last?.message,
                        progress: model.trendResearchProgress
                    )
                }

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

/// 复盘/雷达等 trend 管线生成进度卡：风格与 NextHourGuidanceProgressView 对齐。
struct TrendResearchProgressCard: View {
    let message: String?
    let progress: TrendResearchModuleProgress

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            HStack(alignment: .top, spacing: AppPalette.spaceS) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("收盘复盘正在进行")
                VStack(alignment: .leading, spacing: 2) {
                    Text(message ?? "正在整理今天的持仓收盘数据")
                        .font(AppPalette.appFont(.subheadline, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(2)
                    Text("收盘行情、冻结持仓和逐只归因完成后，这里会生成组合复盘。")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                }
            }

            HStack(spacing: AppPalette.spaceS) {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .tint(AppPalette.info)
                    .frame(maxWidth: .infinity)
                Text(progress.detailText)
                    .font(AppPalette.appFont(.caption, weight: .medium))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
            }
        }
        .padding(AppPalette.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.info.opacity(AppPalette.accentSubtle), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                .stroke(AppPalette.info.opacity(AppPalette.strokeSubtle), lineWidth: 1)
        )
    }
}
