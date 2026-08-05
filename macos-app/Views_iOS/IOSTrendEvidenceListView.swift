#if os(iOS)
import SwiftUI

// MARK: - iOS AI 研判证据列表 + 详情
//
// 复用 Core 的 `TrendEvidence` / `TrendEvidenceDetailModel`。
// 证据列表直接读 model.trendReport?.evidence（全量证据账本）。
// 证据详情 Sheet 接收 TrendEvidenceDetailSelection（含某条结论的 claimEvidence 解析结果）。
// 注意：TrendEvidenceRole 的展示映射在 macOS 是 Views_macOS private extension，
// iOS target 编译不到，这里用 fileprivate 自建。

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

// MARK: - 证据详情 Sheet（某条结论的支持/反向/背景证据）
//
// `TrendEvidenceDetailSelection` 在 macOS 端定义于 Views_macOS（iOS target 编译不到），
// 这里在 iOS 端重建同名类型供本 target 使用（两端互不可见，无符号冲突）。

struct TrendEvidenceDetailSelection: Identifiable, Hashable {
    let id: String
    let subjectTitle: String
    let rationale: String
    let dataAsOf: String
    let detail: TrendEvidenceDetailModel
}

struct IOSTrendEvidenceDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let selection: TrendEvidenceDetailSelection

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
                    header
                    ForEach(TrendEvidenceRole.allCases, id: \.self) { role in
                        roleSection(role)
                    }
                    if !selection.detail.items.isEmpty {
                        Text("共引用 \(selection.detail.items.count) 条数据")
                            .font(IOSDesign.sansBody(11))
                            .foregroundStyle(IOSDesign.muted)
                    }
                }
                .padding(IOSDesign.spaceM)
            }
            .background(IOSDesign.paper)
            .navigationTitle("判断依据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .textSelection(.enabled)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
            Text(selection.subjectTitle)
                .font(IOSDesign.serifHeading(17))
                .foregroundStyle(IOSDesign.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !selection.rationale.isEmpty {
                Text(selection.rationale)
                    .font(IOSDesign.sansBody(13))
                    .foregroundStyle(IOSDesign.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let reason = selection.detail.exemptionReason, !reason.isEmpty {
                HStack(alignment: .top, spacing: IOSDesign.spaceS) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(AppPalette.warning)
                    Text(reason)
                        .font(IOSDesign.sansBody(11))
                        .foregroundStyle(IOSDesign.muted)
                }
                .padding(IOSDesign.spaceS)
                .background(AppPalette.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: IOSDesign.radiusS))
            }
        }
    }

    @ViewBuilder
    private func roleSection(_ role: TrendEvidenceRole) -> some View {
        let items = selection.detail.items(for: role)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: IOSDesign.spaceS) {
                HStack(spacing: 6) {
                    Image(systemName: roleSystemImage(role))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(roleColor(role))
                    Text(roleDisplayText(role))
                        .font(IOSDesign.sansBody(13, weight: .semibold))
                        .foregroundStyle(IOSDesign.ink)
                    Text("\(items.count) 条")
                        .font(IOSDesign.sansBody(11))
                        .foregroundStyle(IOSDesign.muted)
                }
                ForEach(items) { detailItem in
                    evidenceCard(detailItem.evidence, role: role)
                }
            }
        }
    }

    private func evidenceCard(_ evidence: TrendEvidence, role: TrendEvidenceRole) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(evidence.sourceName)
                    .font(IOSDesign.sansBody(11, weight: .semibold))
                    .foregroundStyle(roleColor(role))
                Spacer()
                if let published = evidence.publishedAt, !published.isEmpty {
                    Text(published).font(IOSDesign.sansBody(10)).foregroundStyle(IOSDesign.muted)
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
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let url = evidence.url, let target = URL(string: url) {
                Link(destination: target) {
                    Label("查看原文", systemImage: "arrow.up.right.square")
                        .font(IOSDesign.sansBody(11, weight: .medium))
                        .foregroundStyle(IOSDesign.accent)
                }
            }
        }
        .padding(IOSDesign.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IOSDesign.ink.opacity(0.03), in: RoundedRectangle(cornerRadius: IOSDesign.radiusS))
    }

    // MARK: 角色映射

    private func roleDisplayText(_ role: TrendEvidenceRole) -> String {
        switch role {
        case .supporting:  return "支持证据"
        case .counter:     return "反向证据"
        case .context:     return "背景数据"
        case .referenced:  return "其他引用"
        }
    }

    private func roleSystemImage(_ role: TrendEvidenceRole) -> String {
        switch role {
        case .supporting:  return "checkmark.seal"
        case .counter:     return "arrow.triangle.branch"
        case .context:     return "square.stack.3d.up"
        case .referenced:  return "link"
        }
    }

    private func roleColor(_ role: TrendEvidenceRole) -> Color {
        switch role {
        case .supporting:  return AppPalette.positive
        case .counter:     return AppPalette.warning
        case .context:     return AppPalette.info
        case .referenced:  return AppPalette.muted
        }
    }
}
#endif
