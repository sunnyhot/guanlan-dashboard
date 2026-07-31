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

    private var tabBinding: Binding<PlatformActivityTab> {
        Binding(
            get: { model.selectedPlatformActivityTab },
            set: { model.selectedPlatformActivityTab = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: tabBinding) {
                ForEach(PlatformActivityTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, IOSDesign.spaceM)
            .padding(.vertical, IOSDesign.spaceS)

            if model.selectedPlatformActivityTab == .adjustments {
                // 二级切换:长赢调仓 / 投顾组合
                Picker("", selection: viewModeBinding) {
                    ForEach(PlatformAdjustmentViewMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, IOSDesign.spaceM)
                .padding(.bottom, IOSDesign.spaceS)

                if model.selectedPlatformAdjustmentViewMode == .alfa {
                    IOSAlfaPlatformPanel()
                } else {
                    ScrollView {
                        longWinContent
                    }
                    .background(IOSDesign.paper)
                    .refreshable {
                        try? await model.refreshLatest(persist: false)
                    }
                }
            } else {
                ScrollView {
                    forumList
                }
                .background(IOSDesign.paper)
                .refreshable {
                    try? await model.refreshLatest(persist: false)
                }
            }
        }
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

    // MARK: - 调仓动态

    private var viewModeBinding: Binding<PlatformAdjustmentViewMode> {
        Binding(
            get: { model.selectedPlatformAdjustmentViewMode },
            set: { model.selectedPlatformAdjustmentViewMode = $0 }
        )
    }

    private var longWinContent: some View {
        let actions = model.latestPlatformActions
        return VStack(alignment: .leading, spacing: IOSDesign.spaceS + 4) {
            IOSStrategyRadarPanel()
            IOSPlatformMonthlyChart()
            IOSPlatformHoldingsPie()
            if actions.isEmpty {
                IOSEmptyState(
                    title: "暂无调仓动态",
                    subtitle: "刷新拉取最新的主理人调仓记录。",
                    actionTitle: "刷新"
                ) {
                    Task { try? await model.refreshLatest(persist: false) }
                }
                .padding(.top, IOSDesign.spaceXL)
            } else {
                IOSSectionCard(title: "调仓明细", subtitle: "\(actions.count) 笔", icon: "list.bullet.rectangle") {
                    ForEach(actions, id: \.id) { action in
                        actionRow(action)
                        if action.id != actions.last?.id {
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, IOSDesign.spaceM)
        .padding(.vertical, IOSDesign.spaceS + 4)
        .padding(.horizontal, IOSDesign.spaceM)
        .padding(.vertical, IOSDesign.spaceS + 4)
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
        return VStack(alignment: .leading, spacing: IOSDesign.spaceS + 4) {
            if posts.isEmpty {
                IOSEmptyState(
                    title: "暂无社区动态",
                    subtitle: "刷新拉取主理人最新的发言和记录。",
                    actionTitle: "刷新"
                ) {
                    Task { try? await model.refreshLatest(persist: false) }
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
