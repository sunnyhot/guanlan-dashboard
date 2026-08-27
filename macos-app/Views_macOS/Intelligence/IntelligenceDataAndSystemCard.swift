import SwiftUI

/// V2 基础能力的次级入口。正常使用时保持收起，避免技术准备状态挤占主决策链。
struct IntelligenceDataAndSystemCard: View {
    let snapshot: InvestmentIntelligenceDashboardSnapshot?
    @Binding var activeSheet: IntelligenceSectionView.IntelligenceSheet?
    @ObservedObject var model: AppModel
    @State private var isExpanded = false

    var body: some View {
        SectionCard(
            title: "数据与系统",
            subtitle: "战略目标、持仓分类、数据覆盖与 Agent 准备状态",
            icon: "externaldrive.badge.checkmark",
            trailing: {
                Button(isExpanded ? "收起" : "查看") {
                    withAnimation(AppPalette.motionStandard) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.appText)
                .controlSize(.small)
            }
        ) {
            VStack(alignment: .leading, spacing: AppPalette.spaceM) {
                if let blocker = snapshot?.readiness.blocker {
                    preparationNotice(blocker)
                } else {
                    Label("核心数据已就绪，研判卡可直接使用", systemImage: "checkmark.circle.fill")
                        .font(AppPalette.appFont(.footnote, weight: .medium))
                        .foregroundStyle(AppPalette.positive)
                }

                if isExpanded {
                    VStack(alignment: .leading, spacing: AppPalette.spaceM) {
                        Divider()
                        readinessDetails
                        allocationDetails
                        historyDetails
                        HStack(spacing: AppPalette.spaceS) {
                            Button("编辑战略目标") { activeSheet = .editTarget }
                                .buttonStyle(.appSecondary)
                                .controlSize(.small)
                            Button("持仓归类") { activeSheet = .classifyHoldings }
                                .buttonStyle(.appSecondary)
                                .controlSize(.small)
                            Button("AI 与数据设置") {
                                model.requestSettingsSection(.intelligence)
                            }
                            .buttonStyle(.appText)
                            .controlSize(.small)
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    @ViewBuilder
    private func preparationNotice(
        _ blocker: InvestmentIntelligenceDashboardSnapshot.ReadinessSummary.Blocker
    ) -> some View {
        HStack(alignment: .top, spacing: AppPalette.spaceS) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppPalette.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text(blockerTitle(blocker))
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(blockerDetail(blocker))
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                blockerAction(blocker)
            }
        }
    }

    @ViewBuilder
    private func blockerAction(
        _ blocker: InvestmentIntelligenceDashboardSnapshot.ReadinessSummary.Blocker
    ) -> some View {
        switch blocker {
        case .missingTarget:
            Button("设定战略目标") { activeSheet = .editTarget }
                .buttonStyle(.appPrimary)
                .controlSize(.small)
        case .unclassifiedHoldings:
            Button("完成持仓归类") { activeSheet = .classifyHoldings }
                .buttonStyle(.appPrimary)
                .controlSize(.small)
        case .staleValuation:
            Button("更新持仓数据") {
                Task { try? await model.refreshLatest(updateNotice: true) }
            }
            .buttonStyle(.appPrimary)
            .controlSize(.small)
        }
    }

    private var readinessDetails: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("准备状态")
                .font(AppPalette.appFont(.footnote, weight: .semibold))
                .foregroundStyle(AppPalette.muted)
            LabeledValue(
                title: "战略目标",
                value: snapshot?.allocation.targetConfigured == true ? "已设定" : "未设定"
            )
            LabeledValue(
                title: "AI 模型",
                value: snapshot?.readiness.providerConfigured == true ? "已配置" : "未配置"
            )
            if let coverage = snapshot?.readiness.marketCoverage {
                LabeledValue(
                    title: "市场数据",
                    value: IntelligencePresentationFormatter.coverageText(coverage)
                )
            }
            Text(IntelligenceScheduleEvaluator.scheduleSummaryText)
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var allocationDetails: some View {
        if let snapshot, snapshot.allocation.targetConfigured {
            VStack(alignment: .leading, spacing: 5) {
                Text("当前与目标")
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(AppPalette.muted)
                ForEach(snapshot.allocation.rows, id: \.assetClass) { row in
                    HStack(spacing: AppPalette.spaceS) {
                        Text(IntelligencePresentationFormatter.assetClassName(row.assetClass))
                            .font(AppPalette.appFont(.footnote, weight: .medium))
                            .frame(width: 44, alignment: .leading)
                        Text("当前 \(IntelligencePresentationFormatter.percentText(row.currentWeight))")
                            .foregroundStyle(AppPalette.muted)
                        Text("目标 \(IntelligencePresentationFormatter.percentText(row.targetWeight))")
                            .foregroundStyle(AppPalette.muted)
                        Spacer(minLength: 0)
                        Text(IntelligencePresentationFormatter.deviationText(row.deviation))
                            .foregroundStyle(deviationTint(row.deviation))
                    }
                    .font(AppPalette.appFont(.caption, design: .rounded))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder
    private var historyDetails: some View {
        if let history = snapshot?.history, !history.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("最近记录")
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(AppPalette.muted)
                ForEach(history.prefix(5)) { item in
                    HStack(spacing: AppPalette.spaceS) {
                        Text(IntelligencePresentationFormatter.historyKindLabel(item.kind))
                            .font(AppPalette.appFont(.caption, weight: .medium))
                        Text(item.conclusionText)
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(IntelligencePresentationFormatter.dateTimeText(item.producedAt))
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func blockerTitle(
        _ blocker: InvestmentIntelligenceDashboardSnapshot.ReadinessSummary.Blocker
    ) -> String {
        switch blocker {
        case .missingTarget: return "先设定战略目标"
        case let .unclassifiedHoldings(subjects): return "还有 \(subjects.count) 项持仓待归类"
        case .staleValuation: return "持仓估值需要更新"
        }
    }

    private func blockerDetail(
        _ blocker: InvestmentIntelligenceDashboardSnapshot.ReadinessSummary.Blocker
    ) -> String {
        switch blocker {
        case .missingTarget:
            return "V2 不再用“维持当前配置”冒充用户目标；目标只由你设定。"
        case .unclassifiedHoldings:
            return "分类完成前不会生成执行计划，避免错误资产归类污染结论。"
        case let .staleValuation(latestAsOf):
            return "最新估值为 \(IntelligencePresentationFormatter.dateText(latestAsOf))，更新后再评估。"
        }
    }

    private func deviationTint(_ deviation: Decimal?) -> Color {
        guard let deviation else { return AppPalette.muted }
        return abs(deviation) > Decimal(string: "0.05")! ? AppPalette.warning : AppPalette.muted
    }
}
