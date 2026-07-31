import SwiftUI

struct PlatformActivitySectionView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            activityTabBar

            switch model.selectedPlatformActivityTab {
            case .adjustments:
                PlatformSectionView()
            case .forum:
                ForumSectionView()
            }
        }
        .onChange(of: model.selectedPlatformActivityTab) { _, tab in
            if tab == .forum {
                model.ensureSelectedForumPost()
            }
            model.refreshDataForSectionIfNeeded(.platform)
        }
    }

    private var activityTabBar: some View {
        ModuleTabBar(
            items: PlatformActivityTab.allCases,
            selection: $model.selectedPlatformActivityTab,
            title: { $0.rawValue },
            systemImage: { $0.systemImage }
        )
    }
}

struct PlatformWorkspaceLayout {
    static let compactThreshold: CGFloat = 1_050
    static let actionListHeight: CGFloat = 430
    static let adjustmentWorkspaceHeight: CGFloat = 520
    private static let forumListChromeHeight: CGFloat = 124

    static func listWidth(for availableWidth: CGFloat) -> CGFloat {
        min(max(availableWidth * 0.36, 500), 680)
    }

    static func forumListHeight(for availableHeight: CGFloat) -> CGFloat {
        max(actionListHeight, availableHeight - forumListChromeHeight)
    }
}

// MARK: - Platform

struct PlatformSectionView: View {
    @EnvironmentObject private var model: AppModel
    private let detailAnchor = "platform-detail-panel"
    @State private var isAdjustmentDetailsExpanded = false

    // MARK: - Body

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width < PlatformWorkspaceLayout.compactThreshold

            ScrollViewReader { scrollProxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        viewModePicker

                        if model.selectedPlatformAdjustmentViewMode == .alfa {
                            AlfaPlatformPanel(
                                isCompact: isCompact,
                                availableWidth: proxy.size.width,
                                scrollProxy: scrollProxy
                            )
                        } else {
                            longWinContent(isCompact: isCompact, availableWidth: proxy.size.width, scrollProxy: scrollProxy)
                        }
                    }
                    .padding(AppPalette.contentPadding)
                }
            }
        }
    }

    private var viewModePicker: some View {
        HStack(spacing: 6) {
            ForEach(PlatformAdjustmentViewMode.allCases) { mode in
                Button {
                    withAnimation(AppPalette.motionSection) {
                        model.selectedPlatformAdjustmentViewMode = mode
                    }
                    if mode == .alfa, model.alfaPayload == nil {
                        Task { await model.fetchAllAlfaPayloads() }
                    }
                } label: {
                    Text(mode.label)
                        .font(AppPalette.appFont(.body, weight: model.selectedPlatformAdjustmentViewMode == mode ? .semibold : .regular))
                        .foregroundStyle(model.selectedPlatformAdjustmentViewMode == mode ? AppPalette.brand : AppPalette.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                                .fill(model.selectedPlatformAdjustmentViewMode == mode ? AppPalette.brand.opacity(0.12) : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func longWinContent(isCompact: Bool, availableWidth: CGFloat, scrollProxy: ScrollViewProxy) -> some View {
        PlatformFilterBar(filterState: model.filterState)

        if model.hasPlatformActions || !model.platformHoldings.isEmpty {
            StrategyRadarPanel(summary: model.strategyRadarSummary)
        }

        SectionCard(
            title: "调仓历史",
            subtitle: model.monthlyPlatformSummary.isEmpty
                ? (isCompact ? "点列表会直接跳到详情" : "左边选动作，右边看详情")
                : platformHistorySubtitle,
            icon: "chart.xyaxis.line"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if !model.monthlyPlatformSummary.isEmpty {
                    PlatformMonthlyOverview(months: model.monthlyPlatformSummary)
                }

                if model.hasPlatformActions {
                    InlineDisclosureButton(
                        title: "调仓明细",
                        countText: "\(model.platformActionPresentation.filteredActions.count) 笔",
                        icon: "list.bullet.rectangle",
                        isExpanded: isAdjustmentDetailsExpanded
                    ) {
                        isAdjustmentDetailsExpanded.toggle()
                    }

                    if isAdjustmentDetailsExpanded {
                        adjustmentWorkspace(
                            isCompact: isCompact,
                            availableWidth: availableWidth,
                            scrollProxy: scrollProxy
                        )
                        .transition(.opacity)
                    }
                } else {
                    EmptySectionState(
                        title: "平台调仓暂时为空",
                        subtitle: "我已经把平台和论坛改成了独立刷新。现在点一次刷新，就算其中一项失败，另一项也会照常显示。",
                        actionTitle: "刷新调仓"
                    ) {
                        Task { try? await model.refreshLatest(persist: false) }
                    }
                }
            }
        }

        currentHoldingsSection
    }

    private var platformHistorySubtitle: String {
        guard
            let firstMonth = model.monthlyPlatformSummary.first?.month,
            let lastMonth = model.monthlyPlatformSummary.last?.month
        else {
            return "月度走势与调仓明细"
        }

        let range = firstMonth == lastMonth ? firstMonth : "\(firstMonth) — \(lastMonth)"
        return "\(range) · \(model.monthlyPlatformSummary.count) 个月"
    }

    @ViewBuilder
    private func adjustmentWorkspace(
        isCompact: Bool,
        availableWidth: CGFloat,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        if isCompact {
            VStack(alignment: .leading, spacing: 8) {
                platformListPanel(isCompact: true, scrollProxy: scrollProxy)
                platformDetailPanel(isCompact: true)
                    .id(detailAnchor)
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                platformListPanel(isCompact: false, scrollProxy: scrollProxy)
                    .frame(
                        width: PlatformWorkspaceLayout.listWidth(for: availableWidth),
                        alignment: .top
                    )

                platformDetailPanel(isCompact: false)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: - Current Holdings

    @State private var isHoldingDetailsExpanded = false

    private var currentHoldingsSection: some View {
        SectionCard(
            title: "当前持仓",
            subtitle: model.platformHoldings.isEmpty
                ? "等待平台持仓数据"
                : "\(model.platformHoldings.count) 只 · 按当前份数统计",
            icon: "bag"
        ) {
            if model.platformHoldings.isEmpty {
                EmptySectionState(
                    title: "当前没有平台持仓",
                    subtitle: "如果最近没有拉到调仓数据，这里会先留空；刷新后会自动恢复。",
                    actionTitle: "立即刷新"
                ) {
                    Task { try? await model.refreshLatest(persist: false) }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    PlatformHoldingsPieChart(holdings: model.platformHoldings)

                    InlineDisclosureButton(
                        title: "持仓明细",
                        countText: "\(model.platformHoldings.count) 只",
                        icon: "list.bullet.rectangle",
                        isExpanded: isHoldingDetailsExpanded
                    ) {
                        isHoldingDetailsExpanded.toggle()
                    }

                    if isHoldingDetailsExpanded {
                        LazyVStack(spacing: 6) {
                            ForEach(model.platformHoldings) { holding in
                                HoldingCard(holding: holding)
                            }
                        }
                        .clipped()
                        .transition(.opacity)
                    }
                }
                .respectsReducedMotion()
            }
        }
    }

    // MARK: - List Panel

    private func platformListPanel(isCompact: Bool, scrollProxy: ScrollViewProxy) -> some View {
        let presentation = model.platformActionPresentation
        let totalCount = presentation.filteredActions.count
        let totalPages = presentation.totalPages
        let currentPage = presentation.currentPage
        let pageActions = presentation.pageActions

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("调仓动作")
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Text("\(totalCount)")
                    .font(AppPalette.appFont(.caption, weight: .bold, design: .rounded))
                    .foregroundStyle(AppPalette.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AppPalette.cardStrong, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(AppPalette.line.opacity(0.35), lineWidth: 1)
                    )

                if model.filterState.sideFilter != .all || !model.filterState.searchText.isEmpty {
                    Button {
                        withAnimation(AppPalette.motionSection) {
                            model.filterState.reset()
                        }
                    } label: {
                        Text("清除筛选")
                            .font(AppPalette.appFont(.caption, weight: .medium))
                            .foregroundStyle(AppPalette.brand)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
                if isCompact {
                    Text("点一下自动跳到详情")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                }
            }

            if pageActions.isEmpty, totalCount == 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("没有匹配的调仓动作")
                        .font(AppPalette.appFont(.subheadline, weight: .medium))
                        .foregroundStyle(AppPalette.muted)
                    if !model.filterState.searchText.isEmpty {
                        Text("试试换个关键词搜索")
                            .font(AppPalette.appFont(.footnote))
                            .foregroundStyle(AppPalette.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(AppPalette.card, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
                .overlay(
                    AppPalette.borderOverlay(radius: AppPalette.cardRadius, opacity: AppPalette.borderSubtle)
                )
            } else {
                if isCompact {
                    platformActionRows(pageActions, isCompact: true, scrollProxy: scrollProxy)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        platformActionRows(pageActions, isCompact: false, scrollProxy: scrollProxy)
                            .padding(.trailing, 4)
                    }
                    .frame(height: PlatformWorkspaceLayout.actionListHeight)
                    .clipped()
                }
            }

            if totalPages > 1 {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(AppPalette.motionSection) {
                            model.filterState.currentPage = max(0, currentPage - 1)
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(AppPalette.appFont(.footnote, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppPalette.ink)
                    .background(AppPalette.card, in: RoundedRectangle(cornerRadius: AppPalette.badgeRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppPalette.badgeRadius)
                            .stroke(AppPalette.line.opacity(AppPalette.borderMedium), lineWidth: 1)
                    )
                    .disabled(currentPage == 0)
                    .opacity(currentPage == 0 ? 0.4 : 1.0)
                    .accessibilityLabel("上一页")
                    .help("上一页")

                    Text("\(currentPage + 1) / \(totalPages)")
                        .font(AppPalette.appFont(.subheadline, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppPalette.muted)

                    Button {
                        withAnimation(AppPalette.motionSection) {
                            model.filterState.currentPage = min(totalPages - 1, currentPage + 1)
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(AppPalette.appFont(.footnote, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppPalette.ink)
                    .background(AppPalette.card, in: RoundedRectangle(cornerRadius: AppPalette.badgeRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppPalette.badgeRadius)
                            .stroke(AppPalette.line.opacity(AppPalette.borderMedium), lineWidth: 1)
                    )
                    .disabled(currentPage >= totalPages - 1)
                    .opacity(currentPage >= totalPages - 1 ? 0.4 : 1.0)
                    .accessibilityLabel("下一页")
                    .help("下一页")

                    Spacer()
                }
            }
        }
        .padding(10)
        .frame(
            maxWidth: .infinity,
            minHeight: isCompact ? nil : PlatformWorkspaceLayout.adjustmentWorkspaceHeight,
            maxHeight: isCompact ? nil : PlatformWorkspaceLayout.adjustmentWorkspaceHeight,
            alignment: .topLeading
        )
        .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.panelRadius))
        .overlay(
            AppPalette.borderOverlay(radius: AppPalette.panelRadius, opacity: AppPalette.borderStrong)
        )
    }

    private func platformActionRows(
        _ actions: [PlatformActionPayload],
        isCompact: Bool,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        LazyVStack(spacing: 4) {
            ForEach(actions) { action in
                Button {
                    model.selectPlatformAction(action.id)
                    if isCompact {
                        withAnimation(AppPalette.motionSlow) {
                            scrollProxy.scrollTo(detailAnchor, anchor: .top)
                        }
                    }
                } label: {
                    PlatformActionRow(
                        action: action,
                        isSelected: model.selectedPlatformActionID == action.id,
                        isCompact: true,
                        showsFourColumnMetrics: !isCompact
                    )
                }
                .buttonStyle(PressResponsiveButtonStyle())
                .id(action.id)
            }
        }
    }

    // MARK: - Detail Panel

    private func platformDetailPanel(isCompact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("调仓详情")
                .font(AppPalette.appFont(.body, weight: .semibold))
                .foregroundStyle(AppPalette.ink)

            if let selectedAction = model.selectedPlatformAction {
                PlatformActionDetailCard(action: selectedAction)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("还没有选中的调仓动作")
                        .font(AppPalette.appFont(.headline, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text("从左侧动作列表里点一条，就会在这里展示调仓估值、当前估值和变化。")
                        .font(AppPalette.appFont(.subheadline))
                        .foregroundStyle(AppPalette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(AppPalette.cardHover, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                        .stroke(AppPalette.line.opacity(0.35), lineWidth: 1)
                )
            }
        }
        .padding(10)
        .frame(
            maxWidth: .infinity,
            minHeight: isCompact ? nil : PlatformWorkspaceLayout.adjustmentWorkspaceHeight,
            alignment: .topLeading
        )
        .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.panelRadius))
        .overlay(
            AppPalette.borderOverlay(radius: AppPalette.panelRadius, opacity: AppPalette.borderStrong)
        )
    }
}
