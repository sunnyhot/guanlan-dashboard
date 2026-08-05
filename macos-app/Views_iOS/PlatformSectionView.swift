#if os(iOS)
import SwiftUI

// MARK: - iOS 平台动态页
//
// 对齐 macOS 产品逻辑:调仓动态(字段完整的卡片 + 点击详情 sheet)/
// 论坛发言(标题/作者/时间/互动 + 点击看正文)。复用 latestPlatformActions
// 和 forumRecords 数据。

struct PlatformSectionView: View {
    @EnvironmentObject private var model: AppModel
    @State private var detailAction: PlatformActionPayload?
    @State private var detailPost: SnapshotRecordPayload?

    /// iOS 平台页三段切换:长赢调仓 / 投顾组合 / 论坛。
    /// 不复用共享的 PlatformActivityTab 枚举(改它会影响 macOS),
    /// 而是映射到 selectedPlatformActivityTab + selectedPlatformAdjustmentViewMode。
    private enum IOSSection: String, CaseIterable, Identifiable {
        case longWin = "长赢调仓"
        case alfa = "投顾组合"
        case forum = "论坛"
        var id: String { rawValue }
    }

    private var sectionBinding: Binding<IOSSection> {
        Binding(
            get: {
                if model.selectedPlatformActivityTab == .forum { return .forum }
                return model.selectedPlatformAdjustmentViewMode == .alfa ? .alfa : .longWin
            },
            set: { section in
                switch section {
                case .forum:
                    model.selectedPlatformActivityTab = .forum
                case .alfa:
                    model.selectedPlatformActivityTab = .adjustments
                    model.selectedPlatformAdjustmentViewMode = .alfa
                case .longWin:
                    model.selectedPlatformActivityTab = .adjustments
                    model.selectedPlatformAdjustmentViewMode = .longWin
                }
            }
        )
    }

    var body: some View {
        // 分段控件放进 ScrollView 内容顶部,随内容滚动 —— 这样 ScrollView 是
        // NavigationStack 的直接内容,大标题能正常联动缩放,与其他页面交互一致。
        // 分段控件会随内容上移,大标题缩成 inline 后它停在导航栏下方(系统标准行为)。
        ScrollView {
            VStack(spacing: 0) {
                Picker("", selection: sectionBinding) {
                    ForEach(IOSSection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, IOSDesign.spaceM)
                .padding(.top, 2)
                .padding(.bottom, IOSDesign.spaceS)

                sectionSwitcherBody
            }
        }
        .background(IOSDesign.paper)
        .sheet(item: $detailAction) { action in
            IOSPlatformActionDetailSheet(action: action)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $detailPost) { post in
            IOSForumPostDetailSheet(post: post)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var sectionSwitcherBody: some View {
        switch sectionBinding.wrappedValue {
        case .longWin:
            longWinContent
        case .alfa:
            IOSAlfaPlatformPanel()
        case .forum:
            forumList
        }
    }

    // MARK: - 调仓动态

    /// 长赢调仓:分析层为 hero(雷达→月度趋势→持仓饼图),始终可见;
    /// 调仓明细默认折叠 + 买卖方/搜索筛选。复用 Core 的 PlatformFilterState。
    private var longWinContent: some View {
        let presentation = model.platformActionPresentation
        return VStack(alignment: .leading, spacing: IOSDesign.spaceS + 4) {
            // 分析层(hero,始终可见)
            IOSStrategyRadarPanel()
            IOSPlatformMonthlyChart()
            IOSPlatformHoldingsPie()

            // 调仓明细(带筛选,默认折叠)
            if presentation.counts.all == 0 {
                IOSEmptyState(
                    title: "暂无调仓动态",
                    subtitle: "刷新拉取最新的主理人调仓记录。",
                    actionTitle: "刷新"
                ) {
                    Task { try? await model.refreshLatest(updateNotice: false) }
                }
                .padding(.top, IOSDesign.spaceS)
            } else {
                IOSDisclosureCard(title: "调仓明细", count: presentation.counts.all, unit: "笔") {
                    filterBar(presentation.counts)
                    filteredList(presentation)
                }
            }
        }
        .padding(.horizontal, IOSDesign.spaceM)
        .padding(.vertical, IOSDesign.spaceS + 4)
    }

    // MARK: 筛选条（买卖方 segmented + 搜索框）

    private func filterBar(_ counts: PlatformActionCounts) -> some View {
        VStack(spacing: IOSDesign.spaceS) {
            Picker("", selection: sideFilterBinding) {
                Text("全部 \(counts.all)").tag(PlatformSideFilter.all)
                Text("买入 \(counts.buy)").tag(PlatformSideFilter.buy)
                Text("卖出 \(counts.sell)").tag(PlatformSideFilter.sell)
            }
            .pickerStyle(.segmented)

            HStack(spacing: IOSDesign.spaceS) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(IOSDesign.muted)
                TextField("搜索基金名称 / 代码", text: searchBinding)
                    .font(IOSDesign.sansBody(14))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !model.filterState.searchText.isEmpty {
                    Button {
                        model.filterState.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(IOSDesign.muted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, IOSDesign.spaceS)
            .padding(.vertical, 7)
            .background(IOSDesign.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: IOSDesign.radiusS))
        }
        .padding(.vertical, IOSDesign.spaceXS)
    }

    private var sideFilterBinding: Binding<PlatformSideFilter> {
        Binding(
            get: { model.filterState.sideFilter },
            set: { model.filterState.sideFilter = $0 }
        )
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { model.filterState.searchText },
            set: { model.filterState.searchText = $0 }
        )
    }

    // MARK: 筛选后列表

    @ViewBuilder
    private func filteredList(_ presentation: PlatformActionPresentation) -> some View {
        if presentation.pageActions.isEmpty {
            Text("没有匹配的调仓记录")
                .font(IOSDesign.sansBody(13))
                .foregroundStyle(IOSDesign.muted)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, IOSDesign.spaceM)
        } else {
            ForEach(presentation.pageActions, id: \.id) { action in
                actionRow(action)
                if action.id != presentation.pageActions.last?.id {
                    Divider().opacity(0.4)
                }
            }
            if presentation.totalPages > 1 {
                paginationControls(presentation)
            }
        }
    }

    private func paginationControls(_ presentation: PlatformActionPresentation) -> some View {
        HStack(spacing: IOSDesign.spaceM) {
            Button {
                if model.filterState.currentPage > 0 {
                    model.filterState.currentPage -= 1
                }
            } label: {
                Label("上一页", systemImage: "chevron.left")
                    .font(IOSDesign.sansBody(13, weight: .medium))
            }
            .buttonStyle(.bordered)
            .disabled(presentation.currentPage <= 0)

            Spacer()
            Text("第 \(presentation.currentPage + 1) / \(presentation.totalPages) 页")
                .font(IOSDesign.sansBody(12))
                .foregroundStyle(IOSDesign.muted)
            Spacer()

            Button {
                if presentation.currentPage < presentation.totalPages - 1 {
                    model.filterState.currentPage += 1
                }
            } label: {
                Label("下一页", systemImage: "chevron.right")
                    .font(IOSDesign.sansBody(13, weight: .medium))
            }
            .buttonStyle(.bordered)
            .labelStyle(.titleAndIcon)
            .disabled(presentation.currentPage >= presentation.totalPages - 1)
        }
        .padding(.top, IOSDesign.spaceS)
    }

    private func actionRow(_ action: PlatformActionPayload) -> some View {
        Button {
            detailAction = action
        } label: {
            VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
                HStack(alignment: .top, spacing: IOSDesign.spaceS) {
                    if let side = action.side {
                        sideBadge(side)
                    }
                    Text(action.displayTitle)
                        .font(IOSDesign.sansBody(15, weight: .semibold))
                        .foregroundStyle(IOSDesign.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer()
                }
                if let code = action.fundCode, !code.isEmpty {
                    Text("\(action.fundName ?? "") · \(code)")
                        .font(IOSDesign.sansBody(12))
                        .foregroundStyle(IOSDesign.muted)
                        .lineLimit(1)
                }
                actionSummary(action)
                if let date = actionDateText(action) {
                    Text(date).font(IOSDesign.sansBody(11)).foregroundStyle(IOSDesign.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sideBadge(_ side: String) -> some View {
        let isBuy = side.lowercased() == "buy"
        return Text(isBuy ? "买入" : "卖出")
            .font(IOSDesign.sansBody(11, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background((isBuy ? AppPalette.marketGain : AppPalette.marketLoss).opacity(0.12), in: Capsule())
            .foregroundStyle(isBuy ? AppPalette.marketGain : AppPalette.marketLoss)
    }

    /// 调仓摘要:百分比分支显示 前→后,估值分支显示交易估值/变化
    @ViewBuilder
    private func actionSummary(_ action: PlatformActionPayload) -> some View {
        if action.isPercentBased {
            HStack(spacing: 6) {
                if let before = action.beforePercent {
                    Text(String(format: "%.1f%%", before * 100))
                        .font(IOSDesign.monoNumber(13))
                        .foregroundStyle(IOSDesign.muted)
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 10))
                    .foregroundStyle(IOSDesign.muted)
                if let after = action.afterPercent {
                    Text(String(format: "%.1f%%", after * 100))
                        .font(IOSDesign.monoNumber(13, weight: .semibold))
                        .foregroundStyle(IOSDesign.accent)
                }
                if let group = action.groupName, !group.isEmpty {
                    Spacer()
                    Text(group)
                        .font(IOSDesign.sansBody(11))
                        .foregroundStyle(IOSDesign.muted)
                }
            }
        } else {
            HStack(spacing: IOSDesign.spaceM) {
                if let v = action.tradeValuation {
                    metricLabel("交易", currencyText(v))
                }
                if let pct = action.valuationChangePct {
                    metricLabel("变化", String(format: "%+.2f%%", pct), tone: marketTone(for: pct))
                }
                if let unit = action.tradeUnit {
                    Spacer()
                    metricLabel("份数", "\(unit)", tone: .neutral)
                }
            }
        }
    }

    private func metricLabel(_ title: String, _ value: String, tone: IOSStatTile.StatTone = .neutral) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .font(IOSDesign.sansBody(11))
                .foregroundStyle(IOSDesign.muted)
            Text(value)
                .font(IOSDesign.monoNumber(13))
                .foregroundStyle(tone == .neutral ? IOSDesign.ink : tone.color)
        }
    }

    private func actionDateText(_ action: PlatformActionPayload) -> String? {
        let raw = action.txnDate ?? action.createdAt ?? ""
        guard !raw.isEmpty else { return nil }
        return raw.count >= 10 ? String(raw.prefix(10)) : raw
    }

    // MARK: - 论坛发言

    private var forumList: some View {
        let posts = model.forumRecords
        // LazyVStack:卡片按需构建,切到论坛 tab 不会一次性 parse 全部帖子正文。
        return LazyVStack(alignment: .leading, spacing: IOSDesign.spaceS + 4) {
            if posts.isEmpty {
                IOSEmptyState(
                    title: "暂无社区动态",
                    subtitle: "刷新拉取主理人最新的发言和记录。",
                    actionTitle: "刷新"
                ) {
                    Task { try? await model.refreshLatest(updateNotice: false) }
                }
                .padding(.top, IOSDesign.spaceXL)
            } else {
                ForEach(posts, id: \.id) { post in
                    postCard(post)
                }
            }
        }
        .padding(.horizontal, IOSDesign.spaceM)
        .padding(.vertical, IOSDesign.spaceS + 4)
    }

    private func postCard(_ post: SnapshotRecordPayload) -> some View {
        Button {
            detailPost = post
        } label: {
            VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
                Text(post.titleText)
                    .font(IOSDesign.serifHeading(16, weight: .semibold))
                    .foregroundStyle(IOSDesign.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(post.bodyText)
                    .font(IOSDesign.sansBody(13))
                    .foregroundStyle(IOSDesign.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: IOSDesign.spaceS) {
                    if let name = displayAuthor(post) {
                        Label(name, systemImage: "person.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    if let date = shortDate(post.createdAt) {
                        Label(date, systemImage: "clock")
                            .labelStyle(.titleAndIcon)
                    }
                    Spacer()
                    if let count = post.commentCount, count > 0 {
                        Label("\(count)", systemImage: "bubble.right")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(IOSDesign.sansBody(11))
                .foregroundStyle(IOSDesign.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(IOSDesign.spaceM)
            .background(IOSDesign.card, in: RoundedRectangle(cornerRadius: IOSDesign.radiusM))
            .overlay(RoundedRectangle(cornerRadius: IOSDesign.radiusM).stroke(IOSDesign.ink.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func displayAuthor(_ post: SnapshotRecordPayload) -> String? {
        let name = post.managerName ?? post.userName ?? post.groupName
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return name
    }

    private func shortDate(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.count >= 10 ? String(raw.prefix(10)) : raw
    }
}
#endif
