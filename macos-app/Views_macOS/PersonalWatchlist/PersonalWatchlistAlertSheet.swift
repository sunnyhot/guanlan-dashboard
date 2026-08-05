import SwiftUI

struct PersonalWatchlistAlertSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let row: PersonalWatchlistQuoteRow

    @State private var priceAboveEnabled: Bool
    @State private var priceAboveText: String
    @State private var priceBelowEnabled: Bool
    @State private var priceBelowText: String
    @State private var gainEnabled: Bool
    @State private var gainText: String
    @State private var lossEnabled: Bool
    @State private var lossText: String
    @State private var inlineErrorMessage = ""
    @State private var isSaving = false

    init(row: PersonalWatchlistQuoteRow) {
        self.row = row
        let rules = row.record.alertRules
        _priceAboveEnabled = State(initialValue: rules?.priceAbove != nil)
        _priceAboveText = State(initialValue: alertEditableNumber(rules?.priceAbove))
        _priceBelowEnabled = State(initialValue: rules?.priceBelow != nil)
        _priceBelowText = State(initialValue: alertEditableNumber(rules?.priceBelow))
        _gainEnabled = State(initialValue: rules?.gainSinceFollowPct != nil)
        _gainText = State(initialValue: alertEditableNumber(rules?.gainSinceFollowPct))
        _lossEnabled = State(initialValue: rules?.lossSinceFollowPct != nil)
        _lossText = State(initialValue: alertEditableNumber(rules?.lossSinceFollowPct))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: row.record.hasActiveAlerts ? "bell.fill" : "bell")
                    .font(AppPalette.appFont(.title2, weight: .semibold))
                    .foregroundStyle(categoryTint)
                    .accentIconStyle(tint: categoryTint, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text("价格提醒")
                        .font(AppPalette.appFont(.title2, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text("\(row.displayName) · \(row.item.normalizedCode) · \(row.item.marketLabel)")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer()
                if let state = row.record.alertState, state.isTriggered {
                    Label("当前已触发", systemImage: "bell.badge.fill")
                        .font(AppPalette.appFont(.footnote, weight: .semibold))
                        .foregroundStyle(AppPalette.warning)
                }
            }

            HStack(spacing: 0) {
                alertMetric("关注价", watchlistPriceText(row.record.baseline?.price, item: row.item))
                alertMetricDivider
                alertMetric("当前", watchlistPriceText(row.currentPrice, item: row.item))
                alertMetricDivider
                alertMetric("关注以来", percentOptional(row.changeSinceFollowPct))
            }

            Divider()

            alertSectionHeader("价格监控", detail: "按当前价格判断")
            VStack(spacing: 0) {
                alertRuleEditor(
                    title: "涨到或高于",
                    icon: "arrow.up.right",
                    tint: AppPalette.marketGain,
                    enabled: $priceAboveEnabled,
                    text: $priceAboveText,
                    placeholder: pricePlaceholder,
                    unit: priceUnit
                )
                Divider().opacity(0.45)
                alertRuleEditor(
                    title: "跌到或低于",
                    icon: "arrow.down.right",
                    tint: AppPalette.marketLoss,
                    enabled: $priceBelowEnabled,
                    text: $priceBelowText,
                    placeholder: pricePlaceholder,
                    unit: priceUnit
                )
            }

            alertSectionHeader("涨跌幅监控", detail: "相对首次关注价判断")
            VStack(spacing: 0) {
                alertRuleEditor(
                    title: "上涨达到",
                    icon: "chart.line.uptrend.xyaxis",
                    tint: AppPalette.marketGain,
                    enabled: $gainEnabled,
                    text: $gainText,
                    placeholder: "例如 8",
                    unit: "%"
                )
                Divider().opacity(0.45)
                alertRuleEditor(
                    title: "下跌达到",
                    icon: "chart.line.downtrend.xyaxis",
                    tint: AppPalette.marketLoss,
                    enabled: $lossEnabled,
                    text: $lossText,
                    placeholder: "例如 5",
                    unit: "%"
                )
            }

            if !inlineErrorMessage.isEmpty {
                ToastBar(
                    text: inlineErrorMessage,
                    tint: AppPalette.danger,
                    onDismiss: { inlineErrorMessage = "" }
                )
            } else if let warningMessage {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(warningMessage)
                    Spacer(minLength: 0)
                }
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.warning)
                .padding(9)
                .background(AppPalette.warning.opacity(0.09), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
            }

            Text("应用运行期间随行情自动检查。条件从未达到变为达到时通知一次；回到阈值另一侧后会重新待命。")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)

            HStack(spacing: 10) {
                if row.record.hasActiveAlerts {
                    Button("清除全部", role: .destructive) {
                        clearDraft()
                    }
                    .buttonStyle(.appDanger)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.appSecondary)
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("保存中…")
                        }
                    } else {
                        Text(hasAnyEnabledRule || !row.record.hasActiveAlerts ? "保存提醒" : "关闭提醒")
                    }
                }
                .buttonStyle(.appPrimary)
                .tint(categoryTint)
                .disabled(isSaving || (!hasAnyEnabledRule && !row.record.hasActiveAlerts))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 500)
    }

    private var hasAnyEnabledRule: Bool {
        priceAboveEnabled || priceBelowEnabled || gainEnabled || lossEnabled
    }

    private var pricePlaceholder: String {
        row.currentPrice.map { alertEditableNumber($0) } ?? "目标价格"
    }

    private var priceUnit: String {
        guard row.item.assetType == .stock else { return "净值" }
        return row.item.detectedStockMarket?.currencySymbol ?? "价格"
    }

    private var warningMessage: String? {
        guard hasAnyEnabledRule else { return nil }
        guard let currentPrice = row.currentPrice, currentPrice.isFinite, currentPrice > 0 else {
            return "当前行情暂不可用；提醒会保存，取得有效价格后开始判断。"
        }
        if (gainEnabled || lossEnabled) && row.record.baseline == nil {
            return "关注价尚未锁定；首次成功刷新后开始判断涨跌幅。"
        }

        var reached: [String] = []
        if priceAboveEnabled, let value = alertDouble(priceAboveText), currentPrice >= value {
            reached.append("高价")
        }
        if priceBelowEnabled, let value = alertDouble(priceBelowText), currentPrice <= value {
            reached.append("低价")
        }
        if let change = row.changeSinceFollowPct {
            if gainEnabled, let value = alertDouble(gainText), change >= value {
                reached.append("涨幅")
            }
            if lossEnabled, let value = alertDouble(lossText), change <= -value {
                reached.append("跌幅")
            }
        }
        guard !reached.isEmpty else { return nil }
        return "当前行情已达到\(reached.joined(separator: "、"))条件；保存后会立即提醒一次。"
    }

    private var categoryTint: Color {
        switch row.category {
        case .offExchangeFund: return AppPalette.brand
        case .onExchangeFund: return AppPalette.accentWarm
        case .stock: return AppPalette.info
        }
    }

    private var alertMetricDivider: some View {
        Rectangle()
            .fill(AppPalette.line.opacity(0.42))
            .frame(width: 1, height: 34)
    }

    private func alertMetric(_ title: String, _ value: String) -> some View {
        LabeledValue(
            title: title,
            value: value,
            titleSize: .caption,
            spacing: 3
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }

    private func alertSectionHeader(_ title: String, detail: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(AppPalette.appFont(.subheadline, weight: .bold))
                .foregroundStyle(AppPalette.ink)
            Text(detail)
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
            Spacer()
        }
    }

    private func alertRuleEditor(
        title: String,
        icon: String,
        tint: Color,
        enabled: Binding<Bool>,
        text: Binding<String>,
        placeholder: String,
        unit: String
    ) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            Image(systemName: icon)
                .font(AppPalette.appFont(.footnote, weight: .semibold))
                .foregroundStyle(enabled.wrappedValue ? tint : AppPalette.muted)
                .frame(width: 15)
            Text(title)
                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                .foregroundStyle(enabled.wrappedValue ? AppPalette.ink : AppPalette.muted)
                .frame(width: 86, alignment: .leading)
            Spacer(minLength: 8)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(AppPalette.appFont(.subheadline, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .inputFieldStyle()
                .frame(width: 142)
                .disabled(!enabled.wrappedValue)
                .opacity(enabled.wrappedValue ? 1 : 0.5)
            Text(unit)
                .font(AppPalette.appFont(.footnote, weight: .medium))
                .foregroundStyle(AppPalette.muted)
                .frame(width: 34, alignment: .leading)
        }
        .padding(.vertical, 5)
    }

    private func clearDraft() {
        priceAboveEnabled = false
        priceBelowEnabled = false
        gainEnabled = false
        lossEnabled = false
        inlineErrorMessage = ""
    }

    private func save() async {
        inlineErrorMessage = ""
        let priceAbove = validatedValue(
            enabled: priceAboveEnabled,
            text: priceAboveText,
            label: "高价提醒"
        )
        guard inlineErrorMessage.isEmpty else { return }
        let priceBelow = validatedValue(
            enabled: priceBelowEnabled,
            text: priceBelowText,
            label: "低价提醒"
        )
        guard inlineErrorMessage.isEmpty else { return }
        let gain = validatedValue(enabled: gainEnabled, text: gainText, label: "上涨幅度")
        guard inlineErrorMessage.isEmpty else { return }
        let loss = validatedValue(enabled: lossEnabled, text: lossText, label: "下跌幅度")
        guard inlineErrorMessage.isEmpty else { return }

        if let priceAbove, let priceBelow, priceBelow >= priceAbove {
            inlineErrorMessage = "低价提醒必须小于高价提醒。"
            return
        }
        if let loss, loss >= 100 {
            inlineErrorMessage = "下跌幅度需大于 0 且小于 100%。"
            return
        }

        let rules = PersonalWatchlistAlertRules(
            priceAbove: priceAbove,
            priceBelow: priceBelow,
            gainSinceFollowPct: gain,
            lossSinceFollowPct: loss
        )
        isSaving = true
        defer { isSaving = false }
        if await model.setPersonalWatchlistAlertRules(rules.isEmpty ? nil : rules, for: row.id) {
            dismiss()
        } else {
            inlineErrorMessage = model.errorMessage.isEmpty ? "提醒保存失败，请稍后重试。" : model.errorMessage
            model.errorMessage = ""
        }
    }

    private func validatedValue(enabled: Bool, text: String, label: String) -> Double? {
        guard enabled else { return nil }
        guard let value = alertDouble(text), value.isFinite, value > 0 else {
            inlineErrorMessage = "\(label)请输入大于 0 的数字。"
            return nil
        }
        return value
    }
}

private func alertEditableNumber(_ value: Double?) -> String {
    guard let value else { return "" }
    var text = String(format: "%.4f", value)
    while text.contains(".") && text.last == "0" {
        text.removeLast()
    }
    if text.last == "." {
        text.removeLast()
    }
    return text
}

private func alertDouble(_ text: String) -> Double? {
    Double(
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
    )
}
