import SwiftUI

// MARK: - 盘中执行建议卡（产品重构 §8.4）
//
// HOLD/EXECUTE 的产品文案（不显示 enum raw value）；EXECUTE 展示每个真实
// 持仓的增减方向 + 人话 provenance；过期标注「已过期」+ 重新评估；
// target/artifact 技术细节只进详情 sheet 的折叠区。

struct IntradayDecisionCard: View {
    let snapshot: InvestmentIntelligenceDashboardSnapshot
    @Binding var activeSheet: IntelligenceSectionView.IntelligenceSheet?
    @ObservedObject var model: AppModel

    private var summary: InvestmentIntelligenceDashboardSnapshot.IntradaySummary? {
        snapshot.intraday
    }

    var body: some View {
        SectionCard(
            title: "盘中执行建议",
            subtitle: "对照战略目标的执行决策",
            icon: "clock.arrow.circlepath",
            trailing: {
                HStack(spacing: AppPalette.spaceS) {
                    Button(
                        model.intradayOperationState.isRunning ? "评估中…" : "重新评估"
                    ) {
                        model.runIntradayDecision()
                    }
                    .buttonStyle(.appSecondary)
                    .controlSize(.small)
                    .disabled(
                        model.intradayOperationState.isRunning
                            || snapshot.readiness.blocker != nil)
                    .help(evalButtonHelp)
                    if summary != nil {
                        Button("查看详情") { activeSheet = .intradayDetail }
                            .buttonStyle(.appText)
                            .controlSize(.small)
                    }
                }
            }
        ) {
            if case let .running(_, stage) = model.intradayOperationState {
                IntelligenceRunningRow(stage: stage)
            }
            if let failure = operationFailure {
                IntelligenceInlineError(error: failure)
            }
            if let summary {
                content(summary)
            } else if snapshot.readiness.blocker == nil {
                emptyHint("尚未运行盘中评估——点击「重新评估」对照战略目标检查偏差。")
            } else {
                emptyHint(blockerHint)
            }
        }
    }

    @ViewBuilder
    private func content(
        _ summary: InvestmentIntelligenceDashboardSnapshot.IntradaySummary
    ) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            HStack(spacing: AppPalette.spaceS) {
                Text(IntelligencePresentationFormatter.intradayDecisionLabel(summary.decision))
                    .font(AppPalette.appFont(.headline, weight: .bold))
                    .foregroundStyle(
                        summary.decision == .executeRebalance
                            ? AppPalette.warning : AppPalette.positive)
                if summary.validity == .expired {
                    Label("已过期", systemImage: "clock.badge.exclamationmark")
                        .font(AppPalette.appFont(.caption, weight: .medium))
                        .foregroundStyle(AppPalette.warning)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppPalette.warning.opacity(0.1), in: Capsule())
                }
                Spacer(minLength: 0)
                Text(IntelligencePresentationFormatter.dateTimeText(summary.producedAt))
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
            }

            if summary.decision == .hold {
                ForEach(summary.holdReasons, id: \.self) { reason in
                    Label(reason, systemImage: "checkmark.circle")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(summary.moves, id: \.subjectKey) { move in
                    HStack(spacing: AppPalette.spaceS) {
                        Image(systemName: move.direction == .increase
                            ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill")
                            .foregroundStyle(AppPalette.info)
                            .accessibilityLabel(move.direction == .increase ? "增持" : "减持")
                        Text(move.subjectKey)
                            .font(AppPalette.appFont(.footnote, weight: .medium))
                        Spacer(minLength: 0)
                        Text(IntelligencePresentationFormatter.percentText(abs(move.weightChange)))
                            .font(AppPalette.appFont(.footnote, design: .rounded))
                            .foregroundStyle(AppPalette.ink)
                        Text(IntelligencePresentationFormatter.provenanceText(move.provenanceKind))
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var operationFailure: IntelligenceUserFacingError? {
        if case let .failed(error) = model.intradayOperationState { return error }
        return nil
    }

    private var evalButtonHelp: String {
        if snapshot.readiness.blocker != nil {
            return "先完成准备工作（战略目标 / 持仓分类）"
        }
        return "运行盘中执行决策"
    }

    private var blockerHint: String {
        switch snapshot.readiness.blocker {
        case .missingTarget:
            return "设定战略配置目标后才能运行盘中评估。"
        case .unclassifiedHoldings:
            return "完成持仓归类后才能运行盘中评估。"
        case .staleValuation:
            return "更新持仓数据后才能运行盘中评估。"
        case nil:
            return ""
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(AppPalette.appFont(.subheadline))
            .foregroundStyle(AppPalette.muted)
            .padding(.vertical, AppPalette.spaceS)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 盘中详情 sheet（技术信息折叠区——Artifact ID 只在这里出现）

struct IntradayDecisionDetailSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var isTechnicalInfoExpanded = false

    private var summary: InvestmentIntelligenceDashboardSnapshot.IntradaySummary? {
        model.intelligenceDashboardSnapshot?.intraday
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            HStack {
                Text("盘中执行详情")
                    .font(AppPalette.appFont(.title3, weight: .bold))
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.appSecondary)
                    .controlSize(.small)
            }
            if let summary {
                detailContent(summary)
            } else {
                Text("暂无盘中执行报告。")
                    .foregroundStyle(AppPalette.muted)
            }
        }
        .padding(AppPalette.spaceL)
        .frame(width: 560, height: 420)
    }

    @ViewBuilder
    private func detailContent(
        _ summary: InvestmentIntelligenceDashboardSnapshot.IntradaySummary
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppPalette.spaceM) {
                LabeledValue(
                    title: "结论",
                    value: IntelligencePresentationFormatter.intradayDecisionLabel(summary.decision))
                LabeledValue(
                    title: "有效状态",
                    value: IntelligencePresentationFormatter.intradayValidityLabel(summary.validity))
                LabeledValue(
                    title: "评估时间",
                    value: IntelligencePresentationFormatter.dateTimeText(summary.producedAt))
                if !summary.holdReasons.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("持有理由")
                            .font(AppPalette.appFont(.footnote, weight: .medium))
                            .foregroundStyle(AppPalette.muted)
                        ForEach(summary.holdReasons, id: \.self) { reason in
                            Text("· \(reason)")
                                .font(AppPalette.appFont(.footnote))
                        }
                    }
                }
                if !summary.moves.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("计划动作（Δw 来源：规划器，非模型猜测）")
                            .font(AppPalette.appFont(.footnote, weight: .medium))
                            .foregroundStyle(AppPalette.muted)
                        ForEach(summary.moves, id: \.subjectKey) { move in
                            Text("· " + IntelligencePresentationFormatter.plannedMoveText(move))
                                .font(AppPalette.appFont(.footnote))
                        }
                    }
                }
                // 技术信息折叠区（内部 ID 只在此出现；用于排查与支持）
                DisclosureGroup("技术信息", isExpanded: $isTechnicalInfoExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("报告 ID \(summary.artifactID)")
                            .font(AppPalette.appFont(.caption, design: .monospaced))
                            .foregroundStyle(AppPalette.muted)
                            .textSelection(.enabled)
                        if let targetID = summary.targetID {
                            Text("目标 ID \(targetID)")
                                .font(AppPalette.appFont(.caption, design: .monospaced))
                                .foregroundStyle(AppPalette.muted)
                                .textSelection(.enabled)
                        }
                        ForEach(
                            Array(summary.moves.enumerated()), id: \.offset
                        ) { _, move in
                            Text("\(move.subjectKey) Δw=\(move.weightChange) provenance=\(move.provenanceKind)")
                                .font(AppPalette.appFont(.caption, design: .monospaced))
                                .foregroundStyle(AppPalette.muted)
                                .textSelection(.enabled)
                        }
                        Text("目标变更历史可在 App 数据目录的 user-intent/ 下查看")
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                    }
                    .padding(.top, 2)
                }
                .font(AppPalette.appFont(.footnote))
            }
        }
    }
}
