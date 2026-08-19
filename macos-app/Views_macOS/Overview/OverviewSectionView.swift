import SwiftUI

// MARK: - Overview

struct TodayBriefSummaryItem: Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let icon: String
    let tint: Color
}

struct OverviewSectionView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                TodayBriefPanel(
                    items: model.todayBriefItems,
                    summaryItems: overviewBriefSummaryItems,
                    action: openBrief,
                    summaryAction: openPortfolio
                )
                AITrendSummaryPanel(
                    summary: model.trendDashboardSummary,
                    action: handleTrendDashboardAction
                )

                managerActivityPanel
            }
            .padding(14)
        }
    }

    private var managerActivityPanel: some View {
        SectionCard(
            title: "主理人动态",
            subtitle: "调仓动作与最新发言",
            icon: "person.crop.circle"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                managerActivityGroup(
                    title: "最近调仓",
                    icon: "arrow.left.arrow.right",
                    itemCount: model.latestPlatformActions.count,
                    action: openAllPlatformActions
                ) {
                    recentPlatformActions
                }

                managerActivityGroup(
                    title: model.currentSnapshot?.snapshotType == "posts" ? "最近发言" : "最近记录",
                    icon: "text.bubble",
                    itemCount: model.forumRecords.count,
                    action: openAllForumPosts
                ) {
                    recentForumPosts
                }
            }
        }
    }

    @ViewBuilder
    private var recentPlatformActions: some View {
        if model.latestPlatformActions.isEmpty {
            EmptySectionState(
                title: "最近调仓暂时为空",
                subtitle: "平台接口现在会和论坛分开刷新；点一次刷新后，这里会优先恢复可用数据。",
                actionTitle: "刷新"
            ) {
                Task { try? await model.refreshLatest() }
            }
        } else {
            VStack(spacing: 8) {
                ForEach(Array(model.latestPlatformActions.prefix(3))) { action in
                    Button {
                        openPlatform(action)
                    } label: {
                        PlatformActionRow(
                            action: action,
                            isCompact: true,
                            showsCompactArticleLink: true
                        )
                    }
                    .buttonStyle(PressResponsiveButtonStyle())
                    .help("打开平台调仓详情")
                }
            }
        }
    }

    @ViewBuilder
    private var recentForumPosts: some View {
        if model.hasForumPosts {
            VStack(spacing: 8) {
                ForEach(Array(model.forumRecords.prefix(3))) { record in
                    Button {
                        openForum(record)
                    } label: {
                        ForumRecordRow(record: record)
                    }
                    .buttonStyle(PressResponsiveButtonStyle())
                    .help("打开论坛发言详情")
                }
            }
        } else {
            EmptySectionState(
                title: "最近发言暂时为空",
                subtitle: "论坛页会自动补拉帖子流；这里也会跟着恢复到最新发言。",
                actionTitle: "刷新"
            ) {
                Task { try? await model.refreshLatest() }
            }
        }
    }

    private func managerActivityGroup<Content: View>(
        title: String,
        icon: String,
        itemCount: Int,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(AppPalette.appFont(.caption, weight: .semibold))
                    .foregroundStyle(AppPalette.brand)
                    .frame(width: 14)

                Text(title)
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)

                Text(managerActivityCountText(itemCount))
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)

                Spacer(minLength: 8)

                Button(action: action) {
                    Label("查看全部", systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.appText)
                .controlSize(.small)
            }

            content()
        }
        .padding(10)
        .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                .stroke(AppPalette.line.opacity(0.34), lineWidth: 1)
        )
    }

    private func managerActivityCountText(_ itemCount: Int) -> String {
        guard itemCount > 0 else { return "暂无" }
        return "\(min(itemCount, 3)) 条"
    }

    private func openAllPlatformActions() {
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.88)) {
            model.selectedPlatformActivityTab = .adjustments
            model.selectedSection = .platform
        }
    }

    private func openAllForumPosts() {
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.88)) {
            model.selectedPlatformActivityTab = .forum
            model.selectedSection = .platform
        }
    }

    private func openPortfolio() {
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.88)) {
            model.selectedSection = .portfolio
        }
    }

    private func handleTrendDashboardAction(_ action: TrendDashboardAction) {
        guard !action.isDisabled else { return }
        switch action.kind {
        case .configure:
            withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.88)) {
                model.selectedSection = .settings
            }
        case .generate, .refresh:
            model.startTrendAnalysis(userInitiated: true)
        case .openReport:
            withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.88)) {
                model.selectedSection = .enhancement
            }
        case .wait:
            break
        }
    }

    private func openBrief(_ item: TodayBriefItem) {
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.88)) {
            switch item.destination {
            case .portfolio:
                model.selectedSection = .portfolio
            case .platform:
                if let action = model.latestPlatformActions.first {
                    model.selectPlatformAction(action.id)
                }
                model.selectedPlatformActivityTab = .adjustments
                model.selectedSection = .platform
            case .forum:
                if let record = model.forumRecords.first {
                    model.selectedPostID = record.id
                }
                model.selectedPlatformActivityTab = .forum
                model.selectedSection = .platform
            case .settings:
                model.selectedSection = .settings
            case .aiResearch:
                model.selectedSection = .enhancement
            }
        }
    }

    private var overviewBriefSummaryItems: [TodayBriefSummaryItem] {
        [
            TodayBriefSummaryItem(
                id: "total",
                title: "总持仓",
                value: model.personalAssetSummary.map { currencyText($0.totalEffectiveHoldingAmount) } ?? "—",
                detail: model.personalAssetSummary.map {
                    "已持有 \(currencyText($0.totalMarketValue)) + 待确认 \(currencyText($0.totalPendingCashAmount)) + 下次计划 \(currencyText($0.totalEstimatedNextPlanAmount))"
                } ?? "个人资产还未录入完整",
                icon: "wallet.bifold",
                tint: AppPalette.brand
            ),
            TodayBriefSummaryItem(
                id: "pending",
                title: "待确认买入",
                value: model.personalAssetSummary.map { currencyText($0.totalPendingCashAmount) } ?? "—",
                detail: model.pendingTradeSummary.map { "\($0.actionCount) 笔交易进行中" } ?? "暂无买入中",
                icon: "clock.badge.exclamationmark",
                tint: AppPalette.warning
            ),
            TodayBriefSummaryItem(
                id: "plans",
                title: "计划档案",
                value: model.investmentPlanSummary.map { "\($0.activePlanCount) / \($0.pausedPlanCount) / \($0.endedPlanCount)" } ?? "—",
                detail: model.investmentPlanSummary.map { "进行中 / 暂停 / 终止 · 共 \($0.planCount) 条" } ?? "还没有计划档案",
                icon: "calendar.badge.clock",
                tint: AppPalette.info
            ),
            TodayBriefSummaryItem(
                id: "coverage",
                title: "覆盖标的",
                value: model.personalAssetSummary.map { "\($0.fundCount)" } ?? "0",
                detail: model.personalAssetSummary.map { "持有 \($0.holdingFundCount) · 待确认 \($0.pendingFundCount) · 有计划 \($0.activePlanFundCount)" } ?? "先添加你的个人资产",
                icon: "square.grid.3x2",
                tint: AppPalette.accentWarm
            )
        ]
    }

    private func openPlatform(_ action: PlatformActionPayload) {
        model.selectPlatformAction(action.id)
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.88)) {
            model.selectedPlatformActivityTab = .adjustments
            model.selectedSection = .platform
        }
    }

    private func openForum(_ record: SnapshotRecordPayload) {
        model.selectedPostID = record.id
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.88)) {
            model.selectedPlatformActivityTab = .forum
            model.selectedSection = .platform
        }
    }
}
