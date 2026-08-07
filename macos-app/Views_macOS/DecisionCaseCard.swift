import SwiftUI

/// 单个决策事项卡片（紧凑布局）。
///
/// 两行结构：标题行（标题 + 状态徽章 + 指标 + 操作）+ 一行处置建议。
/// 不再展开三栏「怎么做/影响对象/下一节点」（与标题行信息重复、占空间过大）。
/// 完整理由和历史点「查看判断」进详情。
struct DecisionCaseCard: View {
    let decisionCase: DecisionCase
    let isResearching: Bool
    let researchReport: DecisionCaseResearchReport?
    let onOpen: () -> Void
    let onAcknowledge: () -> Void
    let onResolve: () -> Void
    let onClose: () -> Void
    let onResearch: () -> Void

    private var tint: Color {
        InvestmentIntelligenceStyle.tint(for: decisionCase.decisionState)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 第一行：色点 + 标题（左）｜ 指标（中）｜ 操作按钮（右）
            HStack(alignment: .center, spacing: AppPalette.spaceM) {
                Button(action: onOpen) {
                    HStack(spacing: AppPalette.spaceS) {
                        Circle().fill(tint).frame(width: 8, height: 8)
                        Text(decisionCase.title)
                            .font(AppPalette.appFont(.body, weight: .semibold))
                            .foregroundStyle(AppPalette.ink)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: AppPalette.spaceS)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(decisionCase.metricLabel)
                        .font(AppPalette.appFont(.headline, weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                    Text(decisionCase.metricDescription)
                        .font(AppPalette.appFont(.caption2))
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(1)
                }

                HStack(spacing: 4) {
                    if decisionCase.userDisposition == .pending {
                        Button("关注") { onAcknowledge() }
                            .buttonStyle(.appSecondary)
                            .controlSize(.small)
                    }
                    Button {
                        onResearch()
                    } label: {
                        Image(systemName: "brain.head.profile")
                    }
                    .buttonStyle(.appSecondary)
                    .controlSize(.small)
                    .disabled(isResearching)
                    .help("专项研究")

                    Menu {
                        Button("标记已解决", action: onResolve)
                        Divider()
                        Button("关闭事项", role: .destructive, action: onClose)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("更多操作")
                }
            }

            // 第二行：处置建议
            Text(decisionCase.decisionState.guidanceText)
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 16)

            if isResearching {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("AI 正在深入研究…")
                        .font(AppPalette.appFont(.caption2))
                        .foregroundStyle(AppPalette.muted)
                }
                .padding(.leading, 16)
            } else if let report = researchReport {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                            .font(AppPalette.appFont(.caption2))
                            .foregroundStyle(AppPalette.positive)
                        Text("AI 研究：\(report.rationale)")
                            .font(AppPalette.appFont(.caption2))
                            .foregroundStyle(AppPalette.ink)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 6) {
                        Text("研究于 \(String(report.generatedAt.prefix(10)))")
                            .font(AppPalette.appFont(.caption2))
                            .foregroundStyle(AppPalette.muted)
                        if !report.evidence.isEmpty {
                            Text("引用 \(report.evidence.count) 条证据")
                                .font(AppPalette.appFont(.caption2))
                                .foregroundStyle(AppPalette.info)
                        }
                    }
                }
                .padding(.leading, 16)
            } else {
                Text("尚未研究，点「专项研究」让 AI 深入分析")
                    .font(AppPalette.appFont(.caption2))
                    .foregroundStyle(AppPalette.muted)
                    .padding(.leading, 16)
            }
        }
        .padding(.horizontal, AppPalette.spaceM)
        .padding(.vertical, AppPalette.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                .stroke(AppPalette.muted.opacity(0.12), lineWidth: 1)
        )
    }
}
