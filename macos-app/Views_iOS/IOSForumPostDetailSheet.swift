#if os(iOS)
import SwiftUI

// MARK: - iOS 论坛帖子详情 Sheet
//
// 展示帖子完整正文 + 元信息(时间/小组/作者/互动) + 评论树 + 平台原文链接。
// 评论通过 model.selectedPostID + loadCommentsForSelectedPost() 加载，
// 结果在 model.commentsPayload.comments。渲染见 IOSForumCommentTree。

struct IOSForumPostDetailSheet: View {
    let post: SnapshotRecordPayload
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
                    // 帖子主体(标题/正文/互动/原文)抽成独立子视图 —— post 是值常量,
                    // 评论加载触发的 commentsPayload 变化不会让正文重新求值/重算。
                    IOSForumPostDetailHeader(post: post)

                    // 评论树(随 model.commentsPayload / isLoadingComments 刷新)
                    Divider().opacity(0.4)
                    IOSForumCommentTree(
                        comments: model.commentsPayload?.comments ?? [],
                        isLoading: model.isLoadingComments
                    )
                }
                .padding(.horizontal, IOSDesign.spaceM)
                .padding(.vertical, IOSDesign.spaceM)
            }
            .background(IOSDesign.paper)
            .navigationTitle("动态详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
                .task {
                // 进入详情时加载评论：设置 selectedPostID 后触发拉取
                guard let postID = post.postId else { return }
                let id = String(postID)
                guard model.selectedPostID != id else { return }
                model.selectedPostID = id
                await model.loadCommentsForSelectedPost()
            }
        }
    }
}

// MARK: - 帖子主体(标题/元信息/正文/互动/原文)
//
// 独立子视图:只依赖 post(值常量),不订阅 model。评论加载触发的
// commentsPayload 变化只刷新评论树,不会让这里的正文重新求值。

private struct IOSForumPostDetailHeader: View {
    let post: SnapshotRecordPayload
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
            Text(post.titleText)
                .font(IOSDesign.serifHeading(22))
                .foregroundStyle(IOSDesign.ink)
                .fixedSize(horizontal: false, vertical: true)

            metaChips

            Divider().opacity(0.4)

            Text(post.bodyText)
                .font(IOSDesign.sansBody(15))
                .foregroundStyle(IOSDesign.ink)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            if hasInteraction {
                interactionRow
            }

            if let url = detailURL {
                Button {
                    openURL(url)
                } label: {
                    Label("查看平台原文", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(IOSDesign.accent)
                .padding(.top, IOSDesign.spaceS)
            }
        }
    }

    private var detailURL: URL? {
        guard let raw = post.detailUrl, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private var hasInteraction: Bool {
        (post.likeCount ?? 0) > 0 || (post.commentCount ?? 0) > 0 || (post.collectionCount ?? 0) > 0
    }

    private var metaChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: IOSDesign.spaceS) {
                if let name = post.managerName, !name.isEmpty {
                    chip("主理人 · \(name)")
                }
                if let group = post.groupName, !group.isEmpty {
                    chip(group)
                }
                if let date = post.createdAt, !date.isEmpty {
                    chip(String(date.prefix(10)))
                }
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(IOSDesign.sansBody(12))
            .padding(.horizontal, IOSDesign.spaceS)
            .padding(.vertical, 4)
            .background(IOSDesign.ink.opacity(0.05), in: Capsule())
            .foregroundStyle(IOSDesign.muted)
    }

    private var interactionRow: some View {
        HStack(spacing: IOSDesign.spaceL) {
            if let like = post.likeCount, like > 0 {
                interactionItem("heart", "\(like)")
            }
            if let comment = post.commentCount, comment > 0 {
                interactionItem("bubble.right", "\(comment)")
            }
            if let fav = post.collectionCount, fav > 0 {
                interactionItem("bookmark", "\(fav)")
            }
            Spacer()
        }
        .padding(.top, IOSDesign.spaceS)
    }

    private func interactionItem(_ icon: String, _ count: String) -> some View {
        Label(count, systemImage: icon)
            .font(IOSDesign.sansBody(13))
            .foregroundStyle(IOSDesign.muted)
    }
}
#endif
