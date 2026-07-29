import SwiftUI

struct TrendEvidenceDetailSelection: Identifiable, Hashable {
    let id: String
    let subjectTitle: String
    let rationale: String
    let dataAsOf: String
    let detail: TrendEvidenceDetailModel
}

struct TrendEvidenceDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    let selection: TrendEvidenceDetailSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppPalette.spaceM) {
                    ForEach(TrendEvidenceRole.allCases, id: \.self) { role in
                        evidenceSection(role)
                    }
                    emptyOrMissingState
                }
                .padding(AppPalette.spaceL)
            }
            Divider()
            footer
        }
        .frame(
            minWidth: 680,
            idealWidth: 760,
            maxWidth: 900,
            minHeight: 480,
            idealHeight: 620,
            maxHeight: 760
        )
        .background(AppPalette.cardStrong)
        .textSelection(.enabled)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            HStack(alignment: .firstTextBaseline, spacing: AppPalette.spaceS) {
                Label("Agent 判断依据", systemImage: "doc.text.magnifyingglass")
                    .font(AppPalette.appFont(.headline, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                Spacer(minLength: AppPalette.spaceS)
                Text("\(selection.detail.items.count) 条已引用数据")
                    .font(AppPalette.appFont(.caption, weight: .semibold))
                    .foregroundStyle(AppPalette.info)
            }

            Text(selection.subjectTitle)
                .font(AppPalette.appFont(.title3, weight: .bold))
                .foregroundStyle(AppPalette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(selection.rationale)
                .font(AppPalette.appFont(.subheadline))
                .foregroundStyle(AppPalette.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if !selection.dataAsOf.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label("报告数据时点 \(selection.dataAsOf)", systemImage: "clock")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
            }
        }
        .padding(AppPalette.spaceL)
    }

    private var footer: some View {
        HStack(spacing: AppPalette.spaceS) {
            Text("这些数据由 Agent 获取并被当前 AI 判断引用。")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
            Spacer(minLength: AppPalette.spaceL)
            Button("关闭") {
                dismiss()
            }
            .buttonStyle(.appPrimary)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, AppPalette.spaceL)
        .padding(.vertical, AppPalette.spaceM)
    }

    @ViewBuilder
    private func evidenceSection(_ role: TrendEvidenceRole) -> some View {
        let items = selection.detail.items(for: role)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                Label(role.displayText, systemImage: role.systemImage)
                    .font(AppPalette.appFont(.subheadline, weight: .bold))
                    .foregroundStyle(role.tint)
                ForEach(items) { item in
                    evidenceCard(item)
                }
            }
        }
    }

    private func evidenceCard(_ detailItem: TrendEvidenceDetailItem) -> some View {
        let item = detailItem.evidence
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(detailItem.role.displayText)
                    .font(AppPalette.appFont(.caption2, weight: .bold))
                    .foregroundStyle(detailItem.role.tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        detailItem.role.tint.opacity(AppPalette.accentFill),
                        in: Capsule()
                    )
                Text(item.sourceName)
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(AppPalette.info)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(item.publishedAt ?? item.retrievedAt)
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
            }

            if let destination = safeDestination(item.url) {
                Link(destination: destination) {
                    Label(item.title, systemImage: "arrow.up.right.square")
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(AppPalette.brand)
                        .multilineTextAlignment(.leading)
                }
            } else {
                Text(item.title)
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
            }

            Text(item.summary)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                evidenceMetadataTag(item.metadata.sourceKind.displayText)
                evidenceMetadataTag(item.metadata.sourceTier.displayText)
                Spacer(minLength: 4)
            }

            Text(item.id)
                .font(AppPalette.appFont(.caption2, design: .monospaced))
                .foregroundStyle(AppPalette.muted.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.id)
        }
        .padding(AppPalette.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .staticSurface(
            tint: detailItem.role.tint,
            fill: AppPalette.card,
            strokeOpacity: 0.18,
            activeStrokeOpacity: 0.34
        )
    }

    private func evidenceMetadataTag(_ text: String) -> some View {
        Text(text)
            .font(AppPalette.appFont(.caption2, weight: .semibold))
            .foregroundStyle(AppPalette.muted)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(AppPalette.controlFill, in: Capsule())
    }

    @ViewBuilder
    private var emptyOrMissingState: some View {
        if selection.detail.items.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Label("没有可展示的直接证据", systemImage: "exclamationmark.triangle")
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.warning)
                Text(selection.detail.exemptionReason ?? "Agent 没有为这条判断关联证据账本数据。")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if !selection.detail.missingEvidenceIDs.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Label(
                    "\(selection.detail.missingEvidenceIDs.count) 条引用未在报告证据账本中找到",
                    systemImage: "link.badge.plus"
                )
                .font(AppPalette.appFont(.footnote, weight: .semibold))
                .foregroundStyle(AppPalette.warning)
                Text(selection.detail.missingEvidenceIDs.joined(separator: "\n"))
                    .font(AppPalette.appFont(.caption, design: .monospaced))
                    .foregroundStyle(AppPalette.muted)
            }
        }
    }

    private func safeDestination(_ value: String?) -> URL? {
        guard let value,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return nil
        }
        return url
    }
}

private extension TrendEvidenceRole {
    var displayText: String {
        switch self {
        case .supporting: return "支持证据"
        case .counter: return "反向证据"
        case .context: return "背景数据"
        case .referenced: return "其他引用"
        }
    }

    var systemImage: String {
        switch self {
        case .supporting: return "checkmark.seal"
        case .counter: return "arrow.triangle.branch"
        case .context: return "square.stack.3d.up"
        case .referenced: return "link"
        }
    }

    var tint: Color {
        switch self {
        case .supporting: return AppPalette.positive
        case .counter: return AppPalette.warning
        case .context: return AppPalette.info
        case .referenced: return AppPalette.muted
        }
    }
}

private extension TrendEvidenceSourceKind {
    var displayText: String {
        switch self {
        case .portfolioSnapshot: return "组合快照"
        case .marketQuote: return "行情数据"
        case .fundDisclosure: return "基金披露"
        case .platformSignal: return "平台信号"
        case .managerSignal: return "主理人信号"
        case .officialFiling: return "官方文件"
        case .officialFinancial: return "官方财务数据"
        case .licensedMarketData: return "授权市场数据"
        case .webSearch: return "联网搜索"
        case .derived: return "本地派生"
        case .unknown: return "未分类数据"
        }
    }
}

private extension TrendEvidenceSourceTier {
    var displayText: String {
        switch self {
        case .primary: return "一手来源"
        case .authoritative: return "权威来源"
        case .secondary: return "二手来源"
        case .community: return "社区来源"
        case .unknown: return "来源级别未知"
        }
    }
}
