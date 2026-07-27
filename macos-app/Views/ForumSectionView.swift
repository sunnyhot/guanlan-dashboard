import SwiftUI

// MARK: - Forum

struct ForumSectionView: View {
    @EnvironmentObject private var model: AppModel
    private let compactThreshold: CGFloat = 900
    private let detailAnchor = "forum-detail-panel"

    var body: some View {
        Group {
            if !model.hasForumPosts {
                ScrollView(showsIndicators: false) {
                    SectionCard(title: "论坛发言", subtitle: "原生抓取主理人帖子与评论入口", icon: "text.bubble") {
                        EmptySectionState(
                            title: model.currentSnapshot?.snapshotType == "posts" ? "当前还没拉到帖子" : "当前查询结果不是帖子流",
                            subtitle: "我已经补上了切到论坛页时的自动补拉。点一次刷新后，会优先回到帖子流并恢复发言列表。",
                            actionTitle: "刷新发言"
                        ) {
                            Task { try? await model.refreshLatest(persist: false) }
                        }
                    }
                }
                .padding(16)
            } else {
                GeometryReader { proxy in
                    let isCompact = proxy.size.width < compactThreshold

                    ScrollViewReader { scrollProxy in
                        ScrollView(showsIndicators: false) {
                            if isCompact {
                                VStack(alignment: .leading, spacing: 14) {
                                    forumListPanel(
                                        isCompact: true,
                                        availableHeight: proxy.size.height,
                                        scrollProxy: scrollProxy
                                    )
                                    forumDetailPanel
                                        .id(detailAnchor)
                                }
                                .padding(16)
                            } else {
                                HStack(alignment: .top, spacing: 14) {
                                    forumListPanel(
                                        isCompact: false,
                                        availableHeight: proxy.size.height,
                                        scrollProxy: scrollProxy
                                    )
                                        .frame(width: min(max(proxy.size.width * 0.34, 320), 420), alignment: .top)

                                    forumDetailPanel
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                }
                                .padding(16)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            model.ensureSelectedForumPost()
        }
        .onChange(of: model.currentSnapshot?.id) { _, _ in
            model.ensureSelectedForumPost()
        }
    }

    private func forumListPanel(
        isCompact: Bool,
        availableHeight: CGFloat,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        SectionCard(
            title: "发言列表",
            subtitle: isCompact ? "窄窗口先选发言，再自动跳到下面看详情" : "宽窗口左侧快速切换发言",
            icon: "list.bullet.rectangle"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("主理人发言")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text("\(model.forumRecords.count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(AppPalette.muted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AppPalette.cardStrong, in: Capsule())
                    Spacer()
                    if isCompact {
                        Text("点一下直接看详情")
                            .font(.system(size: 10))
                            .foregroundStyle(AppPalette.muted)
                    }
                }

                Group {
                    if isCompact {
                        LazyVStack(spacing: 8) {
                            forumRecordButtons(isCompact: true, scrollProxy: scrollProxy)
                        }
                    } else {
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVStack(spacing: 8) {
                                forumRecordButtons(isCompact: false, scrollProxy: scrollProxy)
                            }
                            .padding(.trailing, 4)
                        }
                        .frame(height: PlatformWorkspaceLayout.forumListHeight(for: availableHeight))
                        .clipped()
                    }
                }
            }
        }
    }

    private var forumDetailPanel: some View {
        SectionCard(title: "发言详情", subtitle: "支持原帖内容、评论排序和主理人回复过滤", icon: "text.book.closed") {
            if let post = model.selectedPost {
                VStack(alignment: .leading, spacing: 16) {
                    Text(post.titleText)
                        .font(.system(size: 22, weight: .bold))

                    FlowLayout(spacing: 8) {
                        if let createdAt = post.createdAt, !createdAt.isEmpty {
                            StatChip(title: "时间", value: createdAt)
                        }
                        if let groupName = post.groupName, !groupName.isEmpty {
                            StatChip(title: "小组", value: groupName)
                        }
                        if let userName = post.userName, !userName.isEmpty {
                            StatChip(title: "用户", value: userName)
                        }
                        if let interaction = post.interactionText {
                            StatChip(title: "互动", value: interaction)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(post.bodyText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let detail = post.detailUrl, let url = URL(string: detail) {
                        Link("打开原帖", destination: url)
                            .font(.system(size: 11, weight: .semibold))
                    }

                    if model.currentSnapshotSupportsComments {
                        Divider()

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                Picker("评论排序", selection: $model.commentSortType) {
                                    Text("热评").tag("hot")
                                    Text("最新评论").tag("latest")
                                }
                                .pickerStyle(.segmented)
                                .frame(maxWidth: 220)

                                Toggle("只看主理人回复", isOn: $model.onlyManagerReplies)
                                    .toggleStyle(.checkbox)

                                Button {
                                    Task { await model.loadCommentsForSelectedPost() }
                                } label: {
                                    Label(model.isLoadingComments ? "刷新中" : "刷新评论", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.appSecondary)
                                .disabled(model.isLoadingComments)

                                Spacer()
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                Picker("评论排序", selection: $model.commentSortType) {
                                    Text("热评").tag("hot")
                                    Text("最新评论").tag("latest")
                                }
                                .pickerStyle(.segmented)
                                .frame(maxWidth: 220)

                                Toggle("只看主理人回复", isOn: $model.onlyManagerReplies)
                                    .toggleStyle(.checkbox)

                                Button {
                                    Task { await model.loadCommentsForSelectedPost() }
                                } label: {
                                    Label(model.isLoadingComments ? "刷新中" : "刷新评论", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.appSecondary)
                                .disabled(model.isLoadingComments)
                            }
                        }

                        if let comments = model.commentsPayload?.comments, !comments.isEmpty {
                            VStack(spacing: 10) {
                                ForEach(comments) { comment in
                                    CommentBlock(comment: comment)
                                }
                            }
                        } else {
                            Text(model.isLoadingComments ? "正在加载评论…" : "暂无评论。")
                                .foregroundStyle(AppPalette.muted)
                        }
                    }
                }
                .task(id: forumCommentsAutoLoadKey) {
                    guard model.currentSnapshotSupportsComments else { return }
                    await model.loadCommentsForSelectedPost()
                }
            } else {
                EmptySectionState(
                    title: "暂时没有可展示的论坛内容",
                    subtitle: "先选一条发言，或者执行一次刷新，这里就会显示正文和评论入口。",
                    actionTitle: "刷新发言"
                ) {
                    Task { try? await model.refreshLatest(persist: false) }
                }
            }
        }
    }

    private var forumCommentsAutoLoadKey: String {
        [
            model.selectedPost?.postId.map(String.init) ?? "",
            model.commentSortType,
            model.onlyManagerReplies ? "manager" : "all"
        ].joined(separator: "|")
    }

    @ViewBuilder
    private func forumRecordButtons(isCompact: Bool, scrollProxy: ScrollViewProxy) -> some View {
        ForEach(model.forumRecords) { record in
            let isSelected = model.selectedPostID == record.id
            Button {
                model.selectedPostID = record.id
                if isCompact {
                    withAnimation(AppPalette.motionSlow) {
                        scrollProxy.scrollTo(detailAnchor, anchor: .top)
                    }
                }
            } label: {
                ForumSelectableRow(record: record, isSelected: isSelected, isCompact: true)
            }
            .buttonStyle(PressResponsiveButtonStyle())
        }
    }
}
