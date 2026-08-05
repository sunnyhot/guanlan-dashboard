#if os(iOS)
import SwiftUI

// MARK: - iOS 论坛评论树
//
// 复用 Core 的 `CommentPayload`（含 `children` 递归字段）。
// 评论需按 post 单独拉取：设 model.selectedPostID 后调 loadCommentsForSelectedPost()，
// 结果在 model.commentsPayload.comments。
// 渲染：递归 CommentBlock，缩进 + 竖线，复用 IOSDesign 杂志型排版。

struct IOSForumCommentTree: View {
    let comments: [CommentPayload]
    let isLoading: Bool
    var onLoadMore: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            HStack(spacing: 6) {
                Text("评论")
                    .font(IOSDesign.serifHeading(15, weight: .semibold))
                    .foregroundStyle(IOSDesign.ink)
                if !comments.isEmpty {
                    Text("\(comments.count) 楼")
                        .font(IOSDesign.sansBody(11))
                        .foregroundStyle(IOSDesign.muted)
                }
                Spacer()
            }

            if isLoading {
                HStack(spacing: IOSDesign.spaceS) {
                    ProgressView().controlSize(.small)
                    Text("加载评论…")
                        .font(IOSDesign.sansBody(12))
                        .foregroundStyle(IOSDesign.muted)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, IOSDesign.spaceS)
            } else if comments.isEmpty {
                Text("暂无评论")
                    .font(IOSDesign.sansBody(12))
                    .foregroundStyle(IOSDesign.muted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, IOSDesign.spaceS)
            } else {
                ForEach(comments) { comment in
                    commentBlock(comment, depth: 0)
                }
                if let onLoadMore {
                    Button {
                        onLoadMore()
                    } label: {
                        Text("加载更多评论")
                            .font(IOSDesign.sansBody(13, weight: .medium))
                            .foregroundStyle(IOSDesign.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, IOSDesign.spaceS)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 递归评论块
    //
    // Swift 的 `some View` 不支持直接递归（opaque return type 不能引用自身），
    // 用 AnyView 打断递归边界。

    @ViewBuilder
    private func commentBlock(_ comment: CommentPayload, depth: Int) -> some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            singleComment(comment, depth: depth)
            if !comment.children.isEmpty {
                // 子评论：左侧竖线 + 缩进，递归渲染（AnyView 打断递归）
                HStack(alignment: .top, spacing: IOSDesign.spaceS) {
                    Rectangle()
                        .fill(IOSDesign.ink.opacity(0.1))
                        .frame(width: 2)
                    VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
                        ForEach(comment.children) { child in
                            AnyView(commentBlock(child, depth: depth + 1))
                        }
                    }
                }
            }
        }
    }

    private func singleComment(_ comment: CommentPayload, depth: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: IOSDesign.spaceS) {
                Text(comment.userName ?? "匿名")
                    .font(IOSDesign.sansBody(13, weight: .semibold))
                    .foregroundStyle(IOSDesign.ink)
                if let toUser = comment.toUserName, !toUser.isEmpty {
                    Text("回复 \(toUser)")
                        .font(IOSDesign.sansBody(11))
                        .foregroundStyle(IOSDesign.muted)
                }
                Spacer()
                if let date = comment.createdAt?.shortDate {
                    Text(date)
                        .font(IOSDesign.sansBody(10))
                        .foregroundStyle(IOSDesign.muted)
                }
            }
            if let content = comment.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty {
                Text(content)
                    .font(IOSDesign.sansBody(13))
                    .foregroundStyle(IOSDesign.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: IOSDesign.spaceM) {
                if let likes = comment.likeCount, likes > 0 {
                    Label("\(likes)", systemImage: "heart")
                        .font(IOSDesign.sansBody(10))
                        .foregroundStyle(IOSDesign.muted)
                }
                if let replies = comment.replyCount, replies > 0 {
                    Label("\(replies)", systemImage: "bubble.right")
                        .font(IOSDesign.sansBody(10))
                        .foregroundStyle(IOSDesign.muted)
                }
                if let location = comment.ipLocation, !location.isEmpty {
                    Text(location)
                        .font(IOSDesign.sansBody(10))
                        .foregroundStyle(IOSDesign.muted)
                }
            }
        }
        .padding(IOSDesign.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IOSDesign.ink.opacity(0.03), in: RoundedRectangle(cornerRadius: IOSDesign.radiusS))
    }
}

// MARK: - 日期短格式辅助

private extension String {
    var shortDate: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count >= 10 ? String(trimmed.prefix(10)) : trimmed
    }
}
#endif
