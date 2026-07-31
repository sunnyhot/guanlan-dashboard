import SwiftUI

extension SettingsSectionView {
    var valuationAlertPanel: some View {
        SettingsPanel(title: "估值预警", subtitle: "持仓目标买卖提醒", icon: "target") {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    runtimeCard
                    summaryCard
                }
                VStack(spacing: 14) {
                    runtimeCard
                    summaryCard
                }
            }
        }
    }

    private var runtimeCard: some View {
        SettingsCardGroup(title: "运行", subtitle: "总开关与状态", icon: "power", tint: AppPalette.warning) {
            SettingsToggleRow(
                title: "启用估值预警",
                detail: "随持仓每 60 秒自动检查",
                icon: "bell.badge",
                tint: AppPalette.warning,
                isOn: Binding(
                    get: { model.portfolioValuationAlertSettings.isEnabled },
                    set: { model.setPortfolioValuationAlertEnabled($0) }
                )
            )
            SettingsDivider()
            SettingsRow(
                title: "已配置规则",
                value: "\(totalRuleCount) 条 / \(configuredFundCount) 只标的",
                detail: "在持仓详情抽屉中逐只设置",
                icon: "list.number",
                tint: AppPalette.info
            )
            SettingsDivider()
            SettingsActionRow {
                Button {
                    Task { await model.evaluatePortfolioValuationAlerts() }
                } label: {
                    Label("立即检查", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.appSecondary)
            }
        }
    }

    private var summaryCard: some View {
        SettingsCardGroup(title: "规则汇总", subtitle: "所有标的已配置的目标", icon: "scope", tint: AppPalette.brand) {
            if summaries.isEmpty {
                Text("暂无已配置的估值预警。打开持仓详情抽屉即可为目标值设置提醒。")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(summaries, id: \.fundCode) { item in
                    summaryRow(item)
                    if item.fundCode != summaries.last?.fundCode {
                        SettingsDivider()
                    }
                }
            }
        }
    }

    private func summaryRow(_ item: ValuationAlertSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.fundName)
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                if item.isAnyBreached {
                    Label("已触发", systemImage: "bell.badge.fill")
                        .font(AppPalette.appFont(.caption, weight: .semibold))
                        .foregroundStyle(AppPalette.warning)
                }
            }
            Text(item.fundCode)
                .font(AppPalette.appFont(.caption, design: .monospaced))
                .foregroundStyle(AppPalette.muted)
            Text(item.ruleText)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
                .lineLimit(2)
        }
        .padding(.vertical, 8)
    }

    private struct ValuationAlertSummary {
        let fundCode: String
        let fundName: String
        let ruleText: String
        let isAnyBreached: Bool
    }

    private var summaries: [ValuationAlertSummary] {
        guard let snapshot = model.userPortfolioSnapshot else {
            return model.portfolioValuationAlertProfiles.compactMap { code, profile in
                guard profile.hasActiveRules else { return nil }
                return ValuationAlertSummary(
                    fundCode: code, fundName: code,
                    ruleText: profile.rules.map { PortfolioValuationAlertSection.formatThreshold($0) }.joined(separator: " · "),
                    isAnyBreached: profile.isCurrentlyBreached
                )
            }.sorted { $0.fundCode < $1.fundCode }
        }
        let nameByCode = Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.holding.fundCode, $0.fundName) })
        return model.portfolioValuationAlertProfiles.compactMap { code, profile in
            guard profile.hasActiveRules else { return nil }
            return ValuationAlertSummary(
                fundCode: code,
                fundName: nameByCode[code] ?? code,
                ruleText: profile.rules.map { "\($0.metric.displayName) \($0.side.displayName) \(PortfolioValuationAlertSection.formatThreshold($0))" }.joined(separator: " · "),
                isAnyBreached: profile.isCurrentlyBreached
            )
        }.sorted { $0.fundCode < $1.fundCode }
    }

    private var totalRuleCount: Int {
        model.portfolioValuationAlertProfiles.values.reduce(0) { $0 + $1.rules.filter(\.isEnabled).count }
    }

    private var configuredFundCount: Int {
        model.portfolioValuationAlertProfiles.values.filter(\.hasActiveRules).count
    }
}
