import SwiftUI

/// 资产详情抽屉中的「估值预警」区块
struct PortfolioValuationAlertSection: View {
    @EnvironmentObject private var model: AppModel
    let row: PersonalAssetAggregateRow
    @State private var isEditing = false

    private var fundCode: String? { row.fundCode }
    private var profile: PortfolioValuationAlertProfile? {
        guard let fundCode else { return nil }
        return model.portfolioValuationAlertProfiles[fundCode]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bell.badge")
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.warning)
                    .accentIconStyle(tint: AppPalette.warning, size: 22)
                Text("估值预警")
                    .font(AppPalette.appFont(.headline, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                Button {
                    isEditing = true
                } label: {
                    Label(profile == nil ? "设置目标" : "编辑", systemImage: "slider.horizontal.3")
                        .font(AppPalette.appFont(.footnote, weight: .semibold))
                }
                .buttonStyle(.appSecondary)
            }

            snapshotStrip

            if let profile, !profile.rules.isEmpty {
                VStack(spacing: 6) {
                    ForEach(profile.rules) { rule in
                        ruleRow(rule, isBreached: profile.breachedRuleIDs.contains(rule.id))
                    }
                }
            } else {
                Text("未设置目标。达到目标值时发通知提醒卖出或加仓（不会自动下单）。")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
            }

            Text("条件从「未达到」变为「达到」时通知一次；回到阈值另一侧后重新待命。数据缺失时不解除已触发态。")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
        }
        .padding(14)
        .background(AppPalette.card.opacity(0.82), in: RoundedRectangle(cornerRadius: AppPalette.panelRadius))
        .panelStroke(opacity: 0.36)
        .sheet(isPresented: $isEditing) {
            if let fundCode {
                PortfolioValuationAlertEditSheet(row: row, fundCode: fundCode)
            }
        }
    }

    private var snapshotStrip: some View {
        HStack(spacing: 0) {
            snapshotMetric("持有收益率", row.profitPct.map { Self.formatPct($0) })
            Divider().frame(height: 40).overlay(AppPalette.line.opacity(0.46))
            snapshotMetric("盘中估算涨跌", row.estimateChangePct.map { Self.formatPct($0) })
            Divider().frame(height: 40).overlay(AppPalette.line.opacity(0.46))
            snapshotMetric("估算净值", row.currentEstimatePrice.map { String(format: "%.4f", $0) })
        }
        .padding(.vertical, 6)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .cardStroke(opacity: 0.32)
    }

    private func snapshotMetric(_ title: String, _ value: String?) -> some View {
        LabeledValue(
            title: title,
            value: value ?? "—",
            titleSize: .caption,
            titleWeight: .medium,
            valueWeight: .bold,
            valueDesign: .rounded,
            spacing: 3,
            minimumScaleFactor: 0.7
        )
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
        .padding(.horizontal, 8)
    }

    private func ruleRow(_ rule: PortfolioValuationAlertRule, isBreached: Bool) -> some View {
        let sideTint: Color = rule.side == .sell ? AppPalette.marketGain : AppPalette.marketLoss
        return HStack(alignment: .center, spacing: 10) {
            TintedCapsuleBadge(
                text: rule.side == .sell ? "卖出" : "加仓",
                tint: sideTint,
                style: .solid,
                font: AppPalette.appFont(.caption, weight: .bold),
                horizontalPadding: 7,
                verticalPadding: 3
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("\(rule.metric.displayName) \(rule.direction.displayName) \(Self.formatThreshold(rule))")
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(rule.isEnabled ? AppPalette.ink : AppPalette.muted)
                if isBreached {
                    Text("● 当前已触发")
                        .font(AppPalette.appFont(.caption, weight: .semibold))
                        .foregroundStyle(AppPalette.warning)
                }
            }
            Spacer()
            if !rule.isEnabled {
                Text("已禁用")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
            }
        }
        .padding(10)
        .background(AppPalette.cardStrong.opacity(0.72), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
    }

    static func formatPct(_ value: Double) -> String {
        "\(value >= 0 ? "+" : "")\(String(format: "%.2f", value))%"
    }

    static func formatThreshold(_ rule: PortfolioValuationAlertRule) -> String {
        switch rule.metric {
        case .holdingProfitPct, .estimateChangePct:
            return "\(rule.threshold >= 0 ? "+" : "")\(String(format: "%.2f", rule.threshold))%"
        case .estimatePrice:
            return String(format: "%.4f", rule.threshold)
        }
    }
}
