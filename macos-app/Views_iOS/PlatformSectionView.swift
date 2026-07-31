#if os(iOS)
import SwiftUI

// MARK: - iOS 平台动态页
//
// 顶部分段切换(调仓动态 / 论坛发言),单列列表展示。复用 latestPlatformActions
// 和 forumRecords 数据。

struct PlatformSectionView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedTab: PlatformActivityTab = .adjustments

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(PlatformActivityTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            ScrollView {
                if selectedTab == .adjustments {
                    adjustmentsList
                } else {
                    forumList
                }
            }
            .refreshable {
                try? await model.refreshLatest(persist: false)
            }
        }
    }

    private var adjustmentsList: some View {
        let actions = model.latestPlatformActions
        return VStack(alignment: .leading, spacing: 12) {
            if actions.isEmpty {
                IOSEmptyState(
                    title: "暂无调仓动态",
                    subtitle: "刷新拉取最新的主理人调仓记录。",
                    actionTitle: "刷新"
                ) {
                    Task { try? await model.refreshLatest(persist: false) }
                }
                .padding(16)
            } else {
                ForEach(actions, id: \.id) { action in
                    actionCard(action)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func actionCard(_ action: PlatformActionPayload) -> some View {
        IOSSectionCard(title: action.displayTitle, subtitle: actionDateText(action), icon: "arrow.triangle.2.circlepath") {
            EmptyView()
        }
    }

    private var forumList: some View {
        let posts = model.forumRecords
        return VStack(alignment: .leading, spacing: 12) {
            if posts.isEmpty {
                IOSEmptyState(
                    title: "暂无社区动态",
                    subtitle: "刷新拉取主理人最新的发言和记录。",
                    actionTitle: "刷新"
                ) {
                    Task { try? await model.refreshLatest(persist: false) }
                }
                .padding(16)
            } else {
                ForEach(posts, id: \.id) { post in
                    postCard(post)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func postCard(_ post: SnapshotRecordPayload) -> some View {
        IOSSectionCard(title: post.titleText, icon: "bubble.left.and.bubble.right.fill") {
            EmptyView()
        }
    }

    private func actionDateText(_ action: PlatformActionPayload) -> String {
        let raw = action.txnDate ?? action.createdAt ?? ""
        guard !raw.isEmpty else { return "" }
        return raw.count >= 10 ? String(raw.prefix(10)) : raw
    }
}
#endif
