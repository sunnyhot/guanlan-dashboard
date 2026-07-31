#if os(iOS)
import SwiftUI

// MARK: - iOS 总览页
//
// 复用 AppModel 数据契约(todayBriefItems / personalAssetSummary / trendDashboardSummary /
// latestPlatformActions / forumRecords),用 iPhone 原生单列布局展示三个卡片块:
// 今日简报 → AI 趋势 → 主理人动态。数据层完全共享,只重写展示层。

struct OverviewSectionView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
                // Signature detail：杂志型报头（serif 大标题 + 日期 + 细线）
                masthead
                todayBriefCard
                aiTrendCard
                managerActivityCard
            }
            .padding(.horizontal, IOSDesign.spaceM)
            .padding(.vertical, 12)
        }
        .background(IOSDesign.paper)
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            try? await model.refreshLatest(persist: false)
        }
    }

    // MARK: - 报头（Signature Detail）

    /// 杂志刊头：serif 标题 + 日期，像一份每日简报的报眼。
    private var masthead: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("今日简报")
                .font(IOSDesign.serifHeading(30))
                .foregroundStyle(IOSDesign.ink)
            Text(mastheadDateString)
                .font(IOSDesign.sansBody(13))
                .foregroundStyle(IOSDesign.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, IOSDesign.spaceS)
        .padding(.bottom, IOSDesign.spaceS)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(IOSDesign.accent.opacity(0.6))
                .frame(height: 1.5)
                .padding(.bottom, -1)
        }
    }

    private var mastheadDateString: String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M月d日 EEEE"
        return fmt.string(from: Date())
    }

    // MARK: - 今日简报

    private var todayBriefCard: some View {
        let summary = model.personalAssetSummary
        return IOSSectionCard(title: "今日看点", subtitle: "资产概览与待办", icon: "rectangle.grid.2x2.fill") {
            VStack(alignment: .leading, spacing: 10) {
                // 资产汇总数字格
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    IOSStatTile(
                        title: "持仓市值",
                        value: summary.map { currencyText($0.totalMarketValue) } ?? "—"
                    )
                    IOSStatTile(
                        title: "有效持仓",
                        value: summary.map { currencyText($0.totalEffectiveHoldingAmount) } ?? "—"
                    )
                    IOSStatTile(
                        title: "待确认资金",
                        value: summary.map { currencyText($0.totalPendingCashAmount) } ?? "—"
                    )
                    IOSStatTile(
                        title: "持仓基金数",
                        value: summary.map { "\($0.holdingFundCount) 只" } ?? "—"
                    )
                }

                // 待办行动项(来自 TodayBriefBuilder)
                let items = model.todayBriefItems
                if items.isEmpty {
                    Text("暂无待办事项")
                        .font(.system(size: 13))
                        .foregroundStyle(AppPalette.muted)
                        .padding(.top, 2)
                } else {
                    Divider().opacity(0.5)
                    ForEach(items.prefix(4)) { item in
                        todayBriefItemRow(item)
                    }
                }
            }
        }
    }

    private func todayBriefItemRow(_ item: TodayBriefItem) -> some View {
        Button {
            handleTodayBriefTap(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.iconName)
                    .font(.system(size: 13))
                    .foregroundStyle(todayBriefToneColor(item.tone))
                    .frame(width: 26, height: 26)
                    .background(todayBriefToneColor(item.tone).opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppPalette.ink)
                    if !item.detail.isEmpty {
                        Text(item.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(AppPalette.muted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !item.metric.isEmpty {
                    Text(item.metric)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(todayBriefToneColor(item.tone))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(AppPalette.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - AI 趋势

    private var aiTrendCard: some View {
        let summary = model.trendDashboardSummary
        return IOSSectionCard(title: "AI 趋势研判", subtitle: summary.dataAsOf ?? "尚未生成", icon: "sparkles") {
            VStack(alignment: .leading, spacing: 10) {
                // 状态 + 风险 标签行
                HStack(spacing: 8) {
                    IOSTintedBadge(text: summary.stateText, tone: .neutral)
                    if summary.riskLevel != nil, !summary.riskText.isEmpty {
                        IOSTintedBadge(text: summary.riskText, tone: trendToneToStat(summary.riskTone))
                    }
                    Spacer()
                }

                // 标题 + 详情
                Text(summary.headline)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !summary.detail.isEmpty {
                    Text(summary.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 周期研判
                if !summary.horizons.isEmpty {
                    Divider().opacity(0.5)
                    Text("周期研判")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppPalette.muted)
                    ForEach(summary.horizons) { horizon in
                        trendItemRow(
                            title: horizon.title,
                            direction: horizon.directionText,
                            confidence: horizon.confidenceText,
                            rationale: horizon.rationale,
                            tone: horizon.tone
                        )
                    }
                }

                // 主操作按钮
                Button {
                    handleTrendAction(summary.primaryAction)
                } label: {
                    Label(summary.primaryAction.title, systemImage: summary.primaryAction.systemImage)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(trendToneColor(summary.primaryAction.tone))
                .disabled(summary.primaryAction.isDisabled)
            }
        }
    }

    private func trendItemRow(title: String, direction: String, confidence: String, rationale: String, tone: TrendDashboardTone) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(trendToneColor(tone))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppPalette.ink)
                    Spacer()
                    Text(direction)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(trendToneColor(tone))
                }
                if !rationale.isEmpty {
                    Text(rationale)
                        .font(.system(size: 12))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 主理人动态

    private var managerActivityCard: some View {
        let actions = Array(model.latestPlatformActions.prefix(3))
        let posts = Array(model.forumRecords.prefix(3))
        let isEmpty = actions.isEmpty && posts.isEmpty
        return IOSSectionCard(title: "主理人动态", subtitle: "最近调仓与发言", icon: "rectangle.stack.badge.play.fill") {
            if isEmpty {
                IOSEmptyState(
                    title: "暂无动态",
                    subtitle: "点击刷新拉取最新的调仓和社区动态。",
                    actionTitle: "刷新"
                ) {
                    Task { try? await model.refreshLatest(persist: false) }
                }
            } else {
                if !actions.isEmpty {
                    Text("最近调仓")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppPalette.muted)
                    ForEach(actions, id: \.id) { action in
                        activityRow(title: action.displayTitle, date: actionDateText(action))
                    }
                }
                if !actions.isEmpty && !posts.isEmpty {
                    Divider().opacity(0.5).padding(.vertical, 2)
                }
                if !posts.isEmpty {
                    Text(model.hasForumPosts ? "最近发言" : "最近记录")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppPalette.muted)
                    ForEach(posts, id: \.id) { post in
                        activityRow(title: post.titleText, date: nil)
                    }
                }
                Button {
                    model.selectedPlatformActivityTab = actions.isEmpty ? .forum : .adjustments
                    model.selectedSection = .platform
                } label: {
                    Text("查看全部")
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(IOSDesign.accent)
            }
        }
    }

    private func activityRow(title: String, date: String?) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(AppPalette.ink)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let date {
                Text(date)
                    .font(.system(size: 12))
                    .foregroundStyle(AppPalette.muted)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 导航与交互

    private func handleTodayBriefTap(_ item: TodayBriefItem) {
        switch item.destination {
        case .portfolio: model.selectedSection = .portfolio
        case .platform: model.selectedSection = .platform
        case .forum:
            model.selectedPlatformActivityTab = .forum
            model.selectedSection = .platform
        case .settings: model.selectedSection = .settings
        }
    }

    private func handleTrendAction(_ action: TrendDashboardAction) {
        // 趋势操作主要在 AI 研判板块;总览页点击跳转过去
        model.selectedSection = .enhancement
    }

    // MARK: - 颜色与格式化辅助

    private func todayBriefToneColor(_ tone: TodayBriefTone) -> Color {
        switch tone {
        case .brand: return AppPalette.brand
        case .info: return AppPalette.info
        case .warning: return AppPalette.warning
        case .danger: return AppPalette.marketLoss
        case .positive: return AppPalette.positive
        case .muted: return AppPalette.muted
        case .marketGain: return AppPalette.marketGain
        case .marketLoss: return AppPalette.marketLoss
        }
    }

    private func actionDateText(_ action: PlatformActionPayload) -> String? {
        // 用最短日期表示;若无则返回 nil
        let raw = action.txnDate ?? action.createdAt ?? ""
        guard !raw.isEmpty else { return nil }
        if raw.count >= 10 { return String(raw.prefix(10)) }
        return raw
    }
}
#endif
