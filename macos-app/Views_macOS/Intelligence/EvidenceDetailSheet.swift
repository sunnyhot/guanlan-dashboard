import SwiftUI

// MARK: - 研究证据明细 Sheet（审计 A6：V1 逐条证据查看的 V2 重建）
//
// 输入是 EvidenceID 列表（来自 SignalDigest.evidenceIDs），加载走
// ArtifactQueryService.researchEvidence（每个 ID 取最新未废弃 vintage）。
// 展示：来源 / 关联主体 / 数据截至（publishedAt ?? availableAt）/ 内容节选。

struct EvidenceDetailSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// 查询请求（信号文本随行展示——用户知道在看哪条结论的依据）。
    struct Query: Identifiable {
        let signalText: String
        let evidenceIDs: [String]
        var id: String { "\(evidenceIDs.joined(separator: ","))|\(signalText)" }
    }

    let query: Query

    @State private var evidence: [ResearchEvidenceDigest] = []
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("判断依据")
                        .font(AppPalette.appFont(.title3, weight: .bold))
                    Text("\(query.evidenceIDs.count) 条已引用数据 · 数据截至见各行")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.appSecondary)
                    .controlSize(.small)
            }
            if !query.signalText.isEmpty {
                Text(query.signalText)
                    .font(AppPalette.appFont(.footnote, weight: .medium))
                    .foregroundStyle(AppPalette.ink)
                    .padding(AppPalette.spaceS)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: AppPalette.spaceM) {
                    if isLoading {
                        HStack(spacing: AppPalette.spaceS) {
                            ProgressView().controlSize(.small)
                            Text("正在读取证据…")
                                .font(AppPalette.appFont(.footnote))
                                .foregroundStyle(AppPalette.muted)
                        }
                    } else if evidence.isEmpty {
                        Text("证据记录不可读（可能已被清理或从未入库）。")
                            .font(AppPalette.appFont(.footnote))
                            .foregroundStyle(AppPalette.muted)
                    } else {
                        ForEach(evidence) { item in
                            evidenceRow(item)
                        }
                        Text("这些数据由研究工具获取并被当前信号引用；证据入库后不可变，重研究会产出新证据。")
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(AppPalette.spaceL)
        .frame(width: 600, height: 520)
        .task(id: query.id) {
            isLoading = true
            evidence = await model.loadResearchEvidence(evidenceIDs: query.evidenceIDs)
            isLoading = false
        }
    }

    private func evidenceRow(_ item: ResearchEvidenceDigest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: AppPalette.spaceS) {
                Text(item.sourceName)
                    .font(AppPalette.appFont(.caption, weight: .medium))
                    .foregroundStyle(AppPalette.info)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AppPalette.info.opacity(0.1), in: Capsule())
                Text(item.subjectText)
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                Spacer(minLength: 0)
                if let publishedAt = item.publishedAt ?? item.availableAt {
                    Label(
                        IntelligencePresentationFormatter.dateTimeText(publishedAt),
                        systemImage: "clock")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                }
            }
            Text(item.contentExcerpt)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppPalette.spaceS)
        .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
    }
}
