import SwiftUI

// MARK: - 状态类通用视图（骨架 / 错误 / 概览卡；产品重构 §8.1-8.2）

/// 加载骨架（稳定占位，卡片不跳动）。
struct IntelligenceSkeletonContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: AppPalette.panelRadius)
                    .fill(AppPalette.panelBackground.opacity(0.5))
                    .frame(height: 96)
                    .overlay(
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在加载投资智能结果…")
                                .font(AppPalette.appFont(.footnote))
                                .foregroundStyle(AppPalette.muted)
                        }
                        .frame(maxWidth: .infinity)
                    )
            }
        }
    }
}

/// workflow 执行中的阶段行（展示阶段 + 已耗时；不重复提交同一任务）。
struct IntelligenceRunningRow: View {
    let stage: AppModel.IntelligenceOperationState.Stage

    private var stageText: String {
        switch stage {
        case .preparing: return "准备数据"
        case .collecting: return "收集证据"
        case .synthesizing: return "合成论点"
        case .evaluating: return "评估决策"
        case .persisting: return "写入结果"
        }
    }

    var body: some View {
        HStack(spacing: AppPalette.spaceS) {
            ProgressView()
                .controlSize(.small)
            Text("\(stageText)…")
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
        }
        .padding(.vertical, 2)
    }
}

/// 卡片内联错误（映射后的用户错误 + 恢复动作；不是 raw error）。
struct IntelligenceInlineError: View {
    let error: IntelligenceUserFacingError

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(error.title, systemImage: "exclamationmark.triangle")
                .font(AppPalette.appFont(.footnote, weight: .medium))
                .foregroundStyle(AppPalette.warning)
            Text(error.message)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("诊断码 \(error.diagnosticCode)")
                .font(AppPalette.appFont(.caption2, design: .monospaced))
                .foregroundStyle(AppPalette.muted)
                .textSelection(.enabled)
        }
        .padding(AppPalette.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.warning.opacity(0.06), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
    }
}

/// 加载失败卡（fail-closed 映射后的用户错误 + 恢复动作）。
struct IntelligenceErrorCard: View {
    let error: IntelligenceUserFacingError
    @ObservedObject var model: AppModel

    var body: some View {
        SectionCard(
            title: error.title,
            subtitle: "结果加载失败",
            icon: "exclamationmark.triangle"
        ) {
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                Text(error.message)
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.ink)
                HStack(spacing: AppPalette.spaceS) {
                    Button("重试") {
                        model.refreshIntelligenceDashboard()
                    }
                    .buttonStyle(.appPrimary)
                    .controlSize(.small)
                    Text("诊断码 \(error.diagnosticCode)")
                        .font(AppPalette.appFont(.caption, design: .monospaced))
                        .foregroundStyle(AppPalette.muted)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// 系统状态卡（1/3 宽：持仓分类 / 市场数据 / AI 模型）。
struct IntelligenceStatusCard: View {
    let snapshot: InvestmentIntelligenceDashboardSnapshot
    @Binding var activeSheet: IntelligenceSectionView.IntelligenceSheet?
    @ObservedObject var model: AppModel

    var body: some View {
        SectionCard(
            title: "系统状态",
            subtitle: "输入就绪度",
            icon: "checklist"
        ) {
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                statusRow(
                    title: "战略目标",
                    stateText: snapshot.allocation.targetConfigured
                        ? "已设定（\(IntelligencePresentationFormatter.dateText(snapshot.allocation.targetRecordedAt))）"
                        : "未设定",
                    isOK: snapshot.allocation.targetConfigured,
                    actionTitle: snapshot.allocation.targetConfigured ? "编辑" : "设定"
                ) { activeSheet = .editTarget }

                Divider()

                statusRow(
                    title: "持仓分类",
                    stateText: classificationText,
                    isOK: snapshot.readiness.blocker != .unclassifiedHoldings([]) && isClassificationOK,
                    actionTitle: "去归类"
                ) { activeSheet = .classifyHoldings }

                Divider()

                statusRow(
                    title: "市场数据",
                    stateText: snapshot.readiness.marketCoverage.map {
                        IntelligencePresentationFormatter.coverageText($0)
                    } ?? "暂无报告",
                    isOK: isMarketDataOK,
                    actionTitle: "更新数据"
                ) {
                    model.runMarketDiscovery()
                }

                Divider()

                statusRow(
                    title: "AI 模型",
                    stateText: snapshot.readiness.providerConfigured ? "已配置" : "未配置",
                    isOK: snapshot.readiness.providerConfigured,
                    actionTitle: "前往设置"
                ) {
                    model.requestSettingsSection(.intelligence)
                }
            }
        }
    }

    private var isClassificationOK: Bool {
        if case .unclassifiedHoldings = snapshot.readiness.blocker { return false }
        return true
    }

    private var isMarketDataOK: Bool {
        guard let coverage = snapshot.readiness.marketCoverage else { return false }
        return coverage.total > 0
    }

    private var classificationText: String {
        if case let .unclassifiedHoldings(subjects) = snapshot.readiness.blocker {
            return "\(subjects.count) 项待归类"
        }
        if case .staleValuation = snapshot.readiness.blocker { return "估值已过期" }
        return "已完成"
    }

    private func statusRow(
        title: String,
        stateText: String,
        isOK: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: AppPalette.spaceS) {
            Image(systemName: isOK ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(isOK ? AppPalette.positive : AppPalette.warning)
                .accessibilityLabel(isOK ? "已就绪" : "待处理")
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(AppPalette.appFont(.subheadline, weight: .medium))
                    .foregroundStyle(AppPalette.ink)
                Text(stateText)
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
            }
            Spacer(minLength: 0)
            Button(actionTitle, action: action)
                .buttonStyle(.appText)
                .controlSize(.small)
                .font(AppPalette.appFont(.caption, weight: .medium))
        }
    }
}
