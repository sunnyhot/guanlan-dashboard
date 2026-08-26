import SwiftUI

// MARK: - 今日结论卡（产品重构 §8.2）
//
// 页面视觉第一层，只显示一个结论：状态 + 一句话主因 + 有效期 + 数据更新
// 时间；主动作根据 readiness 动态变化（设置目标 / 完善分类 / 更新数据 /
// 开始研究 / 重新评估）。

/// 今日结论卡（页面视觉第一层，只显示一个结论）。
struct IntelligenceOverviewCard: View {
    let snapshot: InvestmentIntelligenceDashboardSnapshot
    @Binding var activeSheet: IntelligenceSectionView.IntelligenceSheet?
    @ObservedObject var model: AppModel

    private var statusColor: Color {
        switch snapshot.headline.status {
        case .rebalanceSuggested: return AppPalette.warning
        case .holdConfigured: return AppPalette.positive
        case .undecidable: return AppPalette.info
        case .notReady: return AppPalette.muted
        }
    }

    var body: some View {
        SectionCard(
            title: "今日结论",
            subtitle: IntelligencePresentationFormatter.headlineStatusLabel(snapshot.headline.status),
            icon: "sparkles.rectangle.stack"
        ) {
            VStack(alignment: .leading, spacing: AppPalette.spaceM) {
                HStack(alignment: .firstTextBaseline, spacing: AppPalette.spaceM) {
                    Text(IntelligencePresentationFormatter.headlineStatusLabel(snapshot.headline.status))
                        .font(AppPalette.appFont(.title3, weight: .bold))
                        .foregroundStyle(statusColor)
                    Spacer(minLength: 0)
                    primaryAction
                }
                Text(snapshot.headline.reason)
                    .font(AppPalette.appFont(.body))
                    .foregroundStyle(AppPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: AppPalette.spaceL) {
                    if let validity = snapshot.headline.validityNote {
                        Label(validity, systemImage: "clock")
                            .foregroundStyle(AppPalette.muted)
                    }
                    if let dataAsOf = snapshot.headline.dataAsOf {
                        Label(
                            "数据更新 \(IntelligencePresentationFormatter.dateTimeText(dataAsOf))",
                            systemImage: "database")
                            .foregroundStyle(AppPalette.muted)
                    }
                    if let coverage = snapshot.readiness.marketCoverage {
                        Label(
                            IntelligencePresentationFormatter.coverageText(coverage),
                            systemImage: "chart.bar.doc.horizontal")
                            .foregroundStyle(AppPalette.muted)
                    }
                }
                .font(AppPalette.appFont(.footnote))
            }
        }
    }

    /// 主动作按 readiness 动态变化（设置目标 / 完善分类 / 更新数据 / 重新评估）。
    @ViewBuilder
    private var primaryAction: some View {
        switch snapshot.readiness.blocker {
        case .missingTarget:
            Button("设置目标") { activeSheet = .editTarget }
                .buttonStyle(.appPrimary)
                .controlSize(.small)
        case .unclassifiedHoldings:
            Button("完善分类") { activeSheet = .classifyHoldings }
                .buttonStyle(.appPrimary)
                .controlSize(.small)
        case .staleValuation:
            Button("更新持仓数据") {
                Task { try? await model.refreshLatest(updateNotice: true) }
            }
                .buttonStyle(.appPrimary)
                .controlSize(.small)
        case nil:
            if snapshot.intraday?.validity == .expired {
                Button("重新评估") { model.runIntradayDecision() }
                    .buttonStyle(.appPrimary)
                    .controlSize(.small)
                    .disabled(model.intradayOperationState.isRunning)
            } else {
                Button(
                    model.intradayOperationState.isRunning ? "评估中…" : "评估持仓"
                ) {
                    model.runIntradayDecision()
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
                .disabled(model.intradayOperationState.isRunning)
            }
        }
    }
}
