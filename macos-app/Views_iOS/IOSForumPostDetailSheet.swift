#if os(iOS)
import SwiftUI

// MARK: - iOS 论坛帖子详情 Sheet
//
// 展示帖子完整正文 + 元信息(时间/小组/作者/互动) + 平台原文链接。
// 评论线程(comments)暂不在此版实现(需要单独的评论加载 API + UI,后续阶段)。

struct IOSForumPostDetailSheet: View {
    let post: SnapshotRecordPayload
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
                    // 标题
                    Text(post.titleText)
                        .font(IOSDesign.serifHeading(22))
                        .foregroundStyle(IOSDesign.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    // 元信息 chips
                    metaChips

                    Divider().opacity(0.4)

                    // 正文
                    Text(post.bodyText)
                        .font(IOSDesign.sansBody(15))
                        .foregroundStyle(IOSDesign.ink)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)

                    // 互动统计
                    if hasInteraction {
                        interactionRow
                    }

                    // 平台原文
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
