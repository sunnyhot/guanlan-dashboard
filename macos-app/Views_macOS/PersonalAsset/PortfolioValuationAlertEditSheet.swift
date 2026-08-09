import SwiftUI

private struct ValuationAlertDraftRule: Identifiable {
    let id = UUID()
    let metric: PortfolioValuationAlertMetric
    var isEnabled: Bool
    var side: PortfolioValuationAlertSide
    var direction: PortfolioValuationAlertDirection
    var thresholdText: String
}

struct PortfolioValuationAlertEditSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let row: PersonalAssetAggregateRow
    let fundCode: String

    @State private var drafts: [ValuationAlertDraftRule]
    @State private var inlineErrorMessage = ""

    init(row: PersonalAssetAggregateRow, fundCode: String) {
        self.row = row
        self.fundCode = fundCode
        _drafts = State(initialValue: Self.initialDrafts(assetType: row.assetType, profile: nil))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            ForEach($drafts) { $draft in
                ruleEditor(draft: $draft)
                if draft.id != drafts.last?.id { Divider().opacity(0.45) }
            }
            if !inlineErrorMessage.isEmpty {
                ToastBar(text: inlineErrorMessage, tint: AppPalette.danger, onDismiss: { inlineErrorMessage = "" })
            }
            Text("条件从「未达到」变为「达到」时通知一次；回到阈值另一侧后重新待命。")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
            actionButtons
        }
        .padding(18)
        .frame(width: 500)
        .onAppear { loadDrafts() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bell.badge.fill")
                .font(AppPalette.appFont(.title2, weight: .semibold))
                .foregroundStyle(AppPalette.warning)
                .accentIconStyle(tint: AppPalette.warning, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text("估值预警")
                    .font(AppPalette.appFont(.title2, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                Text("\(row.fundName) · \(fundCode)")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
            }
            Spacer()
        }
    }

    private func ruleEditor(draft: Binding<ValuationAlertDraftRule>) -> some View {
        let metric = draft.wrappedValue.metric
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: draft.isEnabled) {
                    Text(metric.displayName)
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                }
                .toggleStyle(.switch)
                Spacer()
            }
            if draft.wrappedValue.isEnabled {
                HStack(spacing: 10) {
                    Picker("方向", selection: draft.side) {
                        ForEach(PortfolioValuationAlertSide.allCases, id: \.self) { side in
                            Text(side.displayName).tag(side)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("条件", selection: draft.direction) {
                        ForEach(PortfolioValuationAlertDirection.allCases, id: \.self) { dir in
                            Text(dir.displayName).tag(dir)
                        }
                    }
                    .pickerStyle(.menu)
                    HStack(spacing: 4) {
                        TextField(metric == .estimatePrice ? "例如 1.5" : "例如 20", text: draft.thresholdText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 110)
                        Text(metric.unit).font(AppPalette.appFont(.caption)).foregroundStyle(AppPalette.muted)
                    }
                }
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            if model.portfolioValuationAlertProfiles[fundCode]?.hasActiveRules == true {
                Button("清除全部", role: .destructive) {
                    model.removePortfolioValuationAlertProfile(fundCode: fundCode)
                    dismiss()
                }
                .buttonStyle(.appDanger)
            }
            Spacer()
            Button("取消") { dismiss() }
                .buttonStyle(.appSecondary)
                .keyboardShortcut(.cancelAction)
            Button("保存") { save() }
                .buttonStyle(.appPrimary)
                .tint(AppPalette.warning)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func loadDrafts() {
        let profile = model.portfolioValuationAlertProfile(for: fundCode)
        drafts = Self.initialDrafts(assetType: row.assetType, profile: profile)
    }

    private func save() {
        var rules: [PortfolioValuationAlertRule] = []
        for draft in drafts {
            guard draft.isEnabled else { continue }
            guard let threshold = Double(draft.thresholdText.trimmingCharacters(in: .whitespaces)),
                  threshold.isFinite else {
                inlineErrorMessage = "「\(draft.metric.displayName)」的阈值无效，请输入数字。"
                return
            }
            rules.append(PortfolioValuationAlertRule(
                metric: draft.metric, side: draft.side,
                direction: draft.direction, threshold: threshold
            ))
        }
        let profile = PortfolioValuationAlertProfile(fundCode: fundCode, rules: rules)
        model.upsertPortfolioValuationAlertProfile(profile)
        dismiss()
    }

    private static func initialDrafts(
        assetType: PersonalAssetType,
        profile: PortfolioValuationAlertProfile?
    ) -> [ValuationAlertDraftRule] {
        let allMetrics = PortfolioValuationAlertMetric.allCases.filter {
            assetType == .stock ? $0.appliesToStock : true
        }
        let existingByID = Dictionary(profile?.rules.map { ($0.metric, $0) } ?? [], uniquingKeysWith: { a, _ in a })
        return allMetrics.map { metric in
            let existing = existingByID[metric]
            return ValuationAlertDraftRule(
                metric: metric,
                isEnabled: existing != nil,
                side: existing?.side ?? defaultSide(for: metric),
                direction: existing?.direction ?? defaultDirection(for: metric),
                thresholdText: existing.map { formatExistingThreshold($0) } ?? ""
            )
        }
    }

    private static func defaultSide(for metric: PortfolioValuationAlertMetric) -> PortfolioValuationAlertSide {
        // 默认：收益率正阈值/价格上穿 → 卖出；下穿 → 加仓
        switch metric {
        case .holdingProfitPct, .estimatePrice: return .sell
        case .estimateChangePct: return .sell
        }
    }

    private static func defaultDirection(for metric: PortfolioValuationAlertMetric) -> PortfolioValuationAlertDirection {
        switch metric {
        case .holdingProfitPct, .estimateChangePct, .estimatePrice: return .above
        }
    }

    private static func formatExistingThreshold(_ rule: PortfolioValuationAlertRule) -> String {
        rule.metric == .estimatePrice
            ? String(format: "%.4f", rule.threshold)
            : String(format: "%.2f", rule.threshold)
    }
}
