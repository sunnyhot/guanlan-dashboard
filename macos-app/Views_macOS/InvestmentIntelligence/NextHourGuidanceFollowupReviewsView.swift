import SwiftUI

/// 「昨日关注回顾」(P5):昨晚复盘明日关注的逐条兑现状态。
/// 放在决策台底部(评审决定:靠下,不打扰主结论)。
/// 全部未兑现/无法确认时仍如实展示——"昨晚的关注今天没兑现"本身就是信息。
struct NextHourGuidanceFollowupReviewsView: View {
    let reviews: [NextHourFollowupReview]

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            HStack(spacing: AppPalette.spaceS) {
                Label("昨日关注回顾", systemImage: "sun.max")
                    .font(AppPalette.appFont(.subheadline, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                Text("昨晚复盘说今天要盯的事")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
            }

            VStack(spacing: AppPalette.spaceXS) {
                ForEach(reviews) { review in
                    row(review)
                }
            }
        }
        .padding(AppPalette.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppPalette.cardStrong,
            in: RoundedRectangle(cornerRadius: AppPalette.controlRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                .stroke(AppPalette.hairline.opacity(AppPalette.strokeSubtle), lineWidth: 1)
        )
    }

    private func row(_ review: NextHourFollowupReview) -> some View {
        HStack(alignment: .top, spacing: AppPalette.spaceS) {
            Image(systemName: statusIcon(review.status))
                .font(AppPalette.appFont(.footnote, weight: .semibold))
                .foregroundStyle(statusTint(review.status))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: AppPalette.spaceS) {
                    Text(review.itemText)
                        .font(AppPalette.appFont(.footnote, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                    TintedCapsuleBadge(
                        text: review.status.displayName,
                        tint: statusTint(review.status),
                        font: AppPalette.appFont(.caption2, weight: .bold),
                        horizontalPadding: 6,
                        verticalPadding: 2,
                        softStrokeOpacity: nil
                    )
                }
                if !review.note.isEmpty {
                    Text(review.note)
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !review.evidenceIDs.isEmpty {
                    Text("依据 \(review.evidenceIDs.count) 条")
                        .font(AppPalette.appFont(.caption2))
                        .foregroundStyle(AppPalette.muted.opacity(0.8))
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("昨日关注:\(review.itemText),\(review.status.displayName)")
    }

    private func statusIcon(_ status: NextHourFollowupReview.Status) -> String {
        switch status {
        case .confirmed: return "checkmark.circle.fill"
        case .notSeen: return "minus.circle"
        case .inconclusive: return "questionmark.circle"
        }
    }

    private func statusTint(_ status: NextHourFollowupReview.Status) -> Color {
        switch status {
        case .confirmed: return AppPalette.positive
        case .notSeen: return AppPalette.muted
        case .inconclusive: return AppPalette.warning
        }
    }
}
