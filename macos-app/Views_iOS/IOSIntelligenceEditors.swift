#if os(iOS)
import SwiftUI

// MARK: - iOS 编辑器（战略目标 / 持仓归类；产品重构 §10）
//
// 与 macOS 编辑器共享 AppModel 的保存入口与校验语义；iOS 用 Form 呈现，
// 主要按钮触控面积 ≥44×44。

struct IOSAllocationTargetEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var weights: [AssetClass: String] = [:]
    @State private var changeReason = ""
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(AssetClass.allCases, id: \.self) { assetClass in
                        HStack {
                            Text(IntelligencePresentationFormatter.assetClassName(assetClass))
                            Spacer()
                            TextField("0", text: binding(for: assetClass))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 84)
                                .accessibilityLabel(
                                    "\(IntelligencePresentationFormatter.assetClassName(assetClass)) 目标百分比")
                            Text("%")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("目标占比（合计需为 100%，权重可为 0）")
                }
                Section {
                    TextField("变更原因（可选）", text: $changeReason)
                    LabeledContent("合计") {
                        Text(totalText)
                            .foregroundStyle(totalIsValid ? AppPalette.positive : AppPalette.warning)
                            .monospacedDigit()
                    }
                    if let validationMessage {
                        Text(validationMessage)
                            .font(.footnote)
                            .foregroundStyle(AppPalette.warning)
                    }
                }
            }
            .navigationTitle("战略配置目标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!totalIsValid || model.intelligenceRuntime == nil)
                }
            }
            .onAppear(perform: seedInitialWeights)
        }
    }

    private func seedInitialWeights() {
        guard weights.isEmpty else { return }
        var seeded: [AssetClass: String] = [:]
        if let snapshot = model.intelligenceDashboardSnapshot,
           snapshot.allocation.targetConfigured {
            for row in snapshot.allocation.rows {
                seeded[row.assetClass] = "\((row.targetWeight * 100).rounded(toScale: 0))"
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

    private func binding(for assetClass: AssetClass) -> Binding<String> {
        Binding(
            get: { weights[assetClass] ?? "0" },
            set: { newValue in
                weights[assetClass] = newValue.filter { $0.isNumber || $0 == "." }
                validationMessage = nil
            }
        )
    }

    private var parsedWeights: [AssetClass: Decimal]? {
        var result: [AssetClass: Decimal] = [:]
        for assetClass in AssetClass.allCases {
            guard let raw = weights[assetClass],
                  let percent = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX"))
            else { return nil }
            result[assetClass] = percent / 100
        }
        return result
    }

    private var totalPercent: Decimal {
        AssetClass.allCases.reduce(Decimal.zero) {
            $0 + ((weights[$1].flatMap {
                Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX"))
            } ?? .nan) )
        }
    }

    private var totalText: String {
        "\(totalPercent.rounded(toScale: 1))%"
    }

    private var totalIsValid: Bool {
        guard let parsed = parsedWeights else { return false }
        return parsed.values.reduce(Decimal.zero, +) == Decimal(1)
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

struct IOSAssetClassAssignmentEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    struct Row: Identifiable {
        let id: String
        let name: String
        let code: String
        let assetType: PersonalAssetType
        let current: StrategicAssetClassification
    }

    @State private var rows: [Row] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(row.name.isEmpty ? row.code : row.name)
                                    .font(.subheadline.weight(.medium))
                                Text(row.code)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Text(originText(row.current))
                                .font(.caption)
                                .foregroundStyle(
                                    row.current == .unresolved ? AppPalette.warning : .secondary)
                            if row.assetType == .stock {
                                LabeledContent("分类") { Text("股票（规则）") }
                            } else {
                                Picker(
                                    "分类",
                                    selection: Binding(
                                        get: { row.current.assetClass ?? .equity },
                                        set: { newValue in
                                            _ = model.saveAssetClassAssignment(
                                                subjectKey: row.id, assetClass: newValue)
                                            reload()
                                        }
                                    )
                                ) {
                                    ForEach(AssetClass.allCases, id: \.self) { assetClass in
                                        Text(IntelligencePresentationFormatter.assetClassName(assetClass))
                                            .tag(assetClass)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    if rows.isEmpty {
                        Text("暂无正权重持仓。")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("持仓归类")
                } footer: {
                    Text("待归类的持仓完成前不生成执行计划；你的选择不会被系统识别覆盖。")
                }
            }
            .navigationTitle("持仓归类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear(perform: reload)
        }
    }

    private func reload() {
        guard let runtime = model.intelligenceRuntime else { return }
        let rowsInput = model.personalAssetRows
        let disclosures = model.portfolioLookThroughSnapshot?.disclosures ?? [:]
        Task.detached(priority: .userInitiated) {
            let assignments = (try? runtime.assignmentStore.currentAssignments()) ?? [:]
            let resolved = StrategicAssetClassificationResolver.resolve(
                rows: rowsInput, assignments: assignments,
                disclosures: disclosures, now: Date())
            let pending = rowsInput
                .filter { $0.effectiveHoldingAmount > 0 && !($0.fundCode ?? "").isEmpty }
                .sorted { ($0.fundName, $0.key) < ($1.fundName, $1.key) }
                .map { row in
                    Row(
                        id: "fund|\(row.fundCode ?? "")",
                        name: row.fundName,
                        code: row.fundCode ?? "",
                        assetType: row.assetType,
                        current: resolved.classification["fund|\(row.fundCode ?? "")"] ?? .unresolved)
                }
            await MainActor.run {
                self.rows = pending
            }
        }
    }

    private func originText(_ classification: StrategicAssetClassification) -> String {
        switch classification {
        case let .resolved(_, origin):
            switch origin {
            case .user: return "你选择的分类"
            case .stockRule: return "股票（规则）"
            case .systemInferred(let date): return "系统识别（披露 \(date)）"
            }
        case .unresolved:
            return "待归类——不生成执行计划"
        }
    }
}
#endif
