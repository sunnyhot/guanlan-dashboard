import SwiftUI

// MARK: - 市场机会卡（产品重构 §8.5）
//
// 「无候选」与「数据不足」是两个状态；覆盖缺口收纳进折叠组；主页面文案
// 不出现配置文件名；操作名「更新市场机会」（维护数据 + 运行筛选）。

struct MarketDiscoveryCard: View {
    let snapshot: InvestmentIntelligenceDashboardSnapshot
    @ObservedObject var model: AppModel
    @State private var isCoverageExpanded = false

    private var discovery: InvestmentIntelligenceDashboardSnapshot.DiscoverySummary? {
        snapshot.discovery
    }

    var body: some View {
        SectionCard(
            title: "市场机会",
            subtitle: "本地因子筛选，只为少数标的消耗研究预算",
            icon: "dot.radiowaves.left.and.right",
            trailing: {
                Button(
                    model.discoveryOperationState.isRunning ? "更新中…" : "更新市场机会"
                ) {
                    model.runMarketDiscovery()
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
                .disabled(model.discoveryOperationState.isRunning || model.intelligenceRuntime == nil)
                .help("维护市场数据并重新筛选机会")
            }
        ) {
            if case let .running(_, stage) = model.discoveryOperationState {
                IntelligenceRunningRow(stage: stage)
            }
            if case let .failed(error) = model.discoveryOperationState {
                IntelligenceInlineError(error: error)
            }
            if let discovery {
                content(discovery)
            } else {
                Text("尚未运行市场发现——点击「更新市场机会」开始。")
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
                    .padding(.vertical, AppPalette.spaceS)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func content(
        _ discovery: InvestmentIntelligenceDashboardSnapshot.DiscoverySummary
    ) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            switch discovery.state {
            case .insufficientData:
                Label(
                    "市场数据准备中——多数标的暂无足够行情，完成后自动参与筛选",
                    systemImage: "hourglass")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            case .noCandidates:
                Label("本期无候选——全部标的已参与筛选，无标的过阈值", systemImage: "checkmark.circle")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            case .hasCandidates:
                EmptyView()
            }

            ForEach(discovery.topCandidates, id: \.rank) { candidate in
                HStack(spacing: AppPalette.spaceS) {
                    Text("#\(candidate.rank)")
                        .font(AppPalette.appFont(.caption, weight: .bold, design: .rounded))
                        .foregroundStyle(AppPalette.brand)
                        .frame(width: 26, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(candidate.name)
                            .font(AppPalette.appFont(.subheadline, weight: .medium))
                            .lineLimit(1)
                        Text(candidate.factorsSummary)
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                    }
                    Spacer(minLength: 0)
                    Text(scoreText(candidate.score))
                        .font(AppPalette.appFont(.caption, design: .rounded))
                        .foregroundStyle(AppPalette.muted)
                }
                .accessibilityElement(children: .combine)
            }

            Text("\(IntelligencePresentationFormatter.coverageText(discovery.coverage)) · \(IntelligencePresentationFormatter.dateTimeText(discovery.producedAt))")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)

            DisclosureGroup("数据准备情况", isExpanded: $isCoverageExpanded) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("已启用数据源覆盖的标的参与排名；未启用通道的标的（如 A 股行情增强）暂不参与。")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("参与 \(discovery.coverage.covered) · 未参与 \(max(discovery.coverage.total - discovery.coverage.covered, 0))")
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                }
                .padding(.top, 2)
            }
            .font(AppPalette.appFont(.footnote))
        }
    }

    private func scoreText(_ score: Decimal) -> String {
        "评分 \(score.rounded(toScale: 3))"
    }
}
