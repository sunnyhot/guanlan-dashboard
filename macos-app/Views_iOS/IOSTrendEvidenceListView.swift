#if os(iOS)
import SwiftUI

// MARK: - iOS AI 研判证据列表
//
// 复用 Core 的 `TrendEvidence` / `TrendEvidenceDetailModel`。
// 证据列表直接读 model.trendReport?.evidence（全量证据账本）。

/// 证据列表卡（嵌入 EnhancementSectionView）。
struct IOSTrendEvidenceListView: View {
    let evidence: [TrendEvidence]

    var body: some View {
        IOSSectionCard(title: "研判依据", subtitle: "\(evidence.count) 条数据", icon: "doc.text.magnifyingglass") {
            if evidence.isEmpty {
                Text("暂无证据数据")
                    .font(IOSDesign.sansBody(13))
                    .foregroundStyle(IOSDesign.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, IOSDesign.spaceS)
            } else {
                VStack(spacing: IOSDesign.spaceS) {
                    ForEach(evidence) { item in
                        evidenceRow(item)
                        if item.id != evidence.last?.id {
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }

    private func evidenceRow(_ evidence: TrendEvidence) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: IOSDesign.spaceS) {
                Text(evidence.sourceName)
                    .font(IOSDesign.sansBody(11, weight: .semibold))
                    .foregroundStyle(IOSDesign.accent)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let published = evidence.publishedAt?.trimmingCharacters(in: .whitespacesAndNewlines), !published.isEmpty {
                    Text(published)
                        .font(IOSDesign.sansBody(10))
                        .foregroundStyle(IOSDesign.muted)
                }
            }
            Text(evidence.title)
                .font(IOSDesign.sansBody(13, weight: .medium))
                .foregroundStyle(IOSDesign.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !evidence.summary.isEmpty {
                Text(evidence.summary)
                    .font(IOSDesign.sansBody(12))
                    .foregroundStyle(IOSDesign.muted)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, IOSDesign.spaceXS)
    }
}

#endif
