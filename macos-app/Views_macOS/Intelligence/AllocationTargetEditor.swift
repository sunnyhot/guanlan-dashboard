import SwiftUI

// MARK: - 战略目标编辑器（sheet；产品重构 §8.3）
//
// 始终展示五个资产类；总和实时显示；只有精确 100% 才可保存；
// 保存 = 创建新 Target 事件（不覆盖旧目标）；Return 触发安全保存，Esc 取消。

struct AllocationTargetEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var weights: [AssetClass: String]
    @State private var changeReason = ""
    @State private var validationMessage: String?
    @FocusState private var focusedClass: AssetClass?

    init() {
        // 初值：已设定目标预填；未设定给一个保守的股债 50/50 起点（用户可改）
        _weights = State(initialValue: [:])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            header
            entryList
            footer
        }
        .padding(AppPalette.spaceL)
        .frame(width: 460)
        .onAppear(perform: seedInitialWeights)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("战略配置目标")
                .font(AppPalette.appFont(.title3, weight: .bold))
            Text("五个资产大类的目标占比（权重可为 0；保存后创建新目标，历史保留可回溯）")
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var entryList: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            ForEach(AssetClass.allCases, id: \.self) { assetClass in
                HStack(spacing: AppPalette.spaceM) {
                    Text(IntelligencePresentationFormatter.assetClassName(assetClass))
                        .font(AppPalette.appFont(.subheadline, weight: .medium))
                        .frame(width: 52, alignment: .leading)
                    TextField("0", text: binding(for: assetClass))
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedClass, equals: assetClass)
                        .onSubmit(save)
                        .accessibilityLabel(
                            "\(IntelligencePresentationFormatter.assetClassName(assetClass)) 目标百分比")
                    Text("%")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                    Spacer(minLength: 0)
                    Text(IntelligencePresentationFormatter.percentText(parsedWeight(assetClass)))
                        .font(AppPalette.appFont(.caption, design: .rounded))
                        .foregroundStyle(AppPalette.muted)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            HStack {
                Text("变更原因（可选）")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                TextField("如：年度再平衡", text: $changeReason)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            HStack(spacing: AppPalette.spaceS) {
                Text("合计")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                Text(totalText)
                    .font(AppPalette.appFont(.subheadline, weight: .bold, design: .rounded))
                    .foregroundStyle(totalIsValid ? AppPalette.positive : AppPalette.warning)
                Spacer(minLength: 0)
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.appSecondary)
                    .controlSize(.small)
                Button("保存目标", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.appPrimary)
                    .controlSize(.small)
                    .disabled(!totalIsValid || model.intelligenceRuntime == nil)
            }
            if let validationMessage {
                Text(validationMessage)
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let current = currentSummary {
                Text(current)
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
            }
        }
    }

    // MARK: - 数据

    private func seedInitialWeights() {
        guard weights.isEmpty else { return }
        var seeded: [AssetClass: String] = [:]
        if let snapshot = model.intelligenceDashboardSnapshot,
           snapshot.allocation.targetConfigured {
            for row in snapshot.allocation.rows {
                let percent = (row.targetWeight * 100).rounded(toScale: 0)
                seeded[row.assetClass] = "\(percent)"
            }
        } else {
            seeded[.equity] = "50"
            seeded[.fixedIncome] = "50"
            for assetClass in AssetClass.allCases where seeded[assetClass] == nil {
                seeded[assetClass] = "0"
            }
        }
        weights = seeded
    }

    private var currentSummary: String? {
        guard let snapshot = model.intelligenceDashboardSnapshot,
              snapshot.allocation.targetConfigured else { return nil }
        let current = snapshot.allocation.rows
            .compactMap { row -> String? in
                guard let current = row.currentWeight, current > 0 else { return nil }
                let name = IntelligencePresentationFormatter.assetClassName(row.assetClass)
                let text = IntelligencePresentationFormatter.percentText(current)
                return "\(name) \(text)"
            }
            .joined(separator: " · ")
        return current.isEmpty ? nil : "当前配置：\(current)"
    }

    private func binding(for assetClass: AssetClass) -> Binding<String> {
        Binding(
            get: { weights[assetClass] ?? "0" },
            set: { newValue in
                weights[assetClass] = newValue.filter { $0.isNumber || $0 == "." }
                validationMessage = nil
            }
        )
    }

    private func parsedWeight(_ assetClass: AssetClass) -> Decimal? {
        guard let raw = weights[assetClass],
              let percent = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        return percent / 100
    }

    private var parsedWeights: [AssetClass: Decimal]? {
        var result: [AssetClass: Decimal] = [:]
        for assetClass in AssetClass.allCases {
            guard let weight = parsedWeight(assetClass) else { return nil }
            result[assetClass] = weight
        }
        return result
    }

    private var totalPercent: Decimal {
        AssetClass.allCases
            .reduce(Decimal.zero) { $0 + (parsedWeight($1) ?? .nan) }
    }

    private var totalText: String {
        let percent = totalPercent * 100
        return "\(percent.rounded(toScale: 1))%"
    }

    private var totalIsValid: Bool {
        guard let parsed = parsedWeights else { return false }
        let sum = parsed.values.reduce(Decimal.zero, +)
        return sum == Decimal(1)
    }

    private func save() {
        guard let parsed = parsedWeights else {
            validationMessage = "存在无法解析的百分比输入。"
            return
        }
        let result = model.saveStrategicAllocationTarget(
            weights: parsed, changeReason: changeReason.isEmpty ? nil : changeReason)
        switch result {
        case .success:
            dismiss()
        case .failure(let error):
            validationMessage = error.message
        }
    }
}
