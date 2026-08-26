import SwiftUI

// MARK: - 战略配置卡（2/3 宽；产品重构 §8.3）

struct StrategicAllocationCard: View {
    let snapshot: InvestmentIntelligenceDashboardSnapshot
    @Binding var activeSheet: IntelligenceSectionView.IntelligenceSheet?

    var body: some View {
        SectionCard(
            title: "战略配置与偏差",
            subtitle: snapshot.allocation.targetConfigured
                ? "目标 \(IntelligencePresentationFormatter.dateText(snapshot.allocation.targetRecordedAt)) 设定"
                : "尚未设定目标",
            icon: "target",
            trailing: {
                Button("编辑目标") { activeSheet = .editTarget }
                    .buttonStyle(.appSecondary)
                    .controlSize(.small)
            }
        ) {
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                ForEach(snapshot.allocation.rows, id: \.assetClass) { row in
                    allocationRow(row)
                }
                if !snapshot.allocation.targetConfigured {
                    Text("设定五类资产目标后，系统将对照当前配置给出偏差与调整建议。")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 单行：类名 + 当前 + 目标 + 偏差。
    /// 偏差用 warning/info 语义（不使用红绿——那是涨跌专用，中国市场惯例）。
    private func allocationRow(
        _ row: InvestmentIntelligenceDashboardSnapshot.AllocationSummary.Row
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppPalette.spaceM) {
            Text(IntelligencePresentationFormatter.assetClassName(row.assetClass))
                .font(AppPalette.appFont(.subheadline, weight: .medium))
                .foregroundStyle(AppPalette.ink)
                .frame(width: 44, alignment: .leading)
            Spacer(minLength: 0)
            weightColumn(
                title: "当前",
                value: IntelligencePresentationFormatter.percentText(row.currentWeight))
            weightColumn(
                title: "目标",
                value: snapshot.allocation.targetConfigured
                    ? IntelligencePresentationFormatter.percentText(row.targetWeight)
                    : "—")
            weightColumn(
                title: "偏差",
                value: IntelligencePresentationFormatter.deviationText(row.deviation),
                tint: deviationTint(row.deviation))
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(IntelligencePresentationFormatter.assetClassName(row.assetClass))，"
            + "当前 \(IntelligencePresentationFormatter.percentText(row.currentWeight))，"
            + "目标 \(IntelligencePresentationFormatter.percentText(row.targetWeight))，"
            + "偏差 \(IntelligencePresentationFormatter.deviationText(row.deviation))")
    }

    private func weightColumn(title: String, value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title)
                .font(AppPalette.appFont(.caption2))
                .foregroundStyle(AppPalette.muted)
            Text(value)
                .font(AppPalette.appFont(.subheadline, weight: .semibold, design: .rounded))
                .foregroundStyle(tint ?? AppPalette.ink)
        }
        .frame(minWidth: 56, alignment: .trailing)
    }

    /// 偏差着色：|deviation| > 5% warning，带内 muted；不用红绿。
    private func deviationTint(_ deviation: Decimal?) -> Color {
        guard let deviation else { return AppPalette.muted }
        return abs(deviation) > Decimal(string: "0.05")!
            ? AppPalette.warning : AppPalette.muted
    }
}
