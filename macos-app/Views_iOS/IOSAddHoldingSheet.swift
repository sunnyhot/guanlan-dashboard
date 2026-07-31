#if os(iOS)
import SwiftUI

// MARK: - iOS 添加持仓 Sheet
//
// 复用 AppModel.resolvePersonalAssetCode(代码→名称解析)和
// addPersonalAssetHolding。用户输入代码自动识别基金/股票 + 拉取名称,
// 再填份额和成本。对齐 macOS PersonalAssetAddHoldingSheet 逻辑。

struct IOSAddHoldingSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var codeText = ""
    @State private var unitsText = ""
    @State private var costPriceText = ""
    @State private var codeResolution: PersonalAssetCodeResolution?
    @State private var isResolvingName = false
    @State private var hasResolvedName = false
    @State private var inlineErrorMessage = ""
    @FocusState private var focusedField: Field?

    enum Field { case code, units, cost }

    private var lookupKey: String {
        codeText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基金/股票代码") {
                    TextField("例如 005818 或 600519", text: $codeText)
                        .focused($focusedField, equals: .code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !nameStatusText.isEmpty {
                        nameLookupStatus
                    }
                }

                Section("持仓信息") {
                    LabeledContent {
                        TextField("份额,如 1000", text: $unitsText)
                            .focused($focusedField, equals: .units)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text("持有份额")
                    }
                    LabeledContent {
                        TextField("成本价,如 1.2345", text: $costPriceText)
                            .focused($focusedField, equals: .cost)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text("成本单价")
                    }
                }

                if !inlineErrorMessage.isEmpty {
                    Section {
                        Label(inlineErrorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppPalette.marketGain)
                    }
                }
            }
            .navigationTitle("添加持仓")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("添加") { submit() }
                        .disabled(codeResolution == nil || isResolvingName)
                        .bold()
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }
                }
            }
            .task(id: lookupKey) {
                await resolveName(for: codeText)
            }
        }
    }

    // MARK: - 名称解析状态

    private var nameStatusText: String {
        if lookupKey.isEmpty { return "" }
        if isResolvingName { return "正在识别…" }
        guard let resolution = codeResolution else { return "" }
        let typeLabel = resolution.assetType == .stock ? "股票" : "基金"
        if let name = resolution.displayName, !name.isEmpty {
            return "✓ \(name)（\(typeLabel)）"
        }
        return "✓ 代码有效（\(typeLabel)）"
    }

    private var nameStatusTint: Color {
        if isResolvingName { return IOSDesign.muted }
        return IOSDesign.accent
    }

    private var nameLookupStatus: some View {
        HStack(spacing: 6) {
            Image(systemName: isResolvingName ? "arrow.clockwise" : "checkmark.circle.fill")
                .foregroundStyle(nameStatusTint)
            Text(nameStatusText)
                .foregroundStyle(nameStatusTint)
        }
        .font(IOSDesign.sansBody(13))
    }

    // MARK: - 解析与提交

    private func resolveName(for rawCode: String) async {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        codeResolution = nil
        hasResolvedName = false
        guard !code.isEmpty else {
            isResolvingName = false
            return
        }
        isResolvingName = true
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }
        let resolution = await model.resolvePersonalAssetCode(code)
        if Task.isCancelled { return }
        codeResolution = resolution
        hasResolvedName = true
        isResolvingName = false
    }

    private func submit() {
        inlineErrorMessage = ""
        guard let resolution = codeResolution else {
            inlineErrorMessage = "请先输入有效的代码。"
            return
        }
        let ok = model.addPersonalAssetHolding(
            assetType: resolution.assetType,
            codeText: resolution.code,
            unitsText: unitsText,
            costPriceText: costPriceText,
            displayName: resolution.displayName,
            stockMarket: resolution.stockMarket,
            fundMarket: resolution.fundMarket
        )
        if ok {
            dismiss()
        } else {
            inlineErrorMessage = model.errorMessage.isEmpty ? "添加失败，请检查填写内容。" : model.errorMessage
            model.errorMessage = ""
            if unitsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                focusedField = .units
            } else {
                focusedField = .cost
            }
        }
    }
}
#endif

// MARK: - iOS 编辑持仓 Sheet

struct IOSEditHoldingSheet: View {
    let row: PersonalAssetAggregateRow
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var codeText = ""
    @State private var nameText = ""
    @State private var unitsText = ""
    @State private var costPriceText = ""
    @State private var inlineErrorMessage = ""
    @FocusState private var focusedField: IOSAddHoldingSheet.Field?

    var body: some View {
        NavigationStack {
            Form {
                Section("代码") {
                    TextField("代码", text: $codeText)
                        .focused($focusedField, equals: .code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("显示名称(可选)", text: $nameText)
                }
                Section("持仓信息") {
                    LabeledContent {
                        TextField("份额", text: $unitsText)
                            .focused($focusedField, equals: .units)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    } label: { Text("持有份额") }
                    LabeledContent {
                        TextField("成本价", text: $costPriceText)
                            .focused($focusedField, equals: .cost)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    } label: { Text("成本单价") }
                }
                if !inlineErrorMessage.isEmpty {
                    Section {
                        Label(inlineErrorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppPalette.marketGain)
                    }
                }
            }
            .navigationTitle("编辑持仓")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { submit() }.bold()
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }
                }
            }
            .onAppear { loadInitial() }
        }
    }

    private func loadInitial() {
        let holding = row.rawHolding ?? row.holdingRow?.holding
        codeText = holding?.normalizedFundCode ?? row.fundCode ?? ""
        nameText = row.fundName
        unitsText = holding.map { decimalText($0.units) } ?? ""
        costPriceText = holding?.costPrice.map { decimalText($0) } ?? ""
    }

    private func submit() {
        inlineErrorMessage = ""
        let ok = model.updatePersonalAssetHolding(
            row,
            codeText: codeText,
            unitsText: unitsText,
            costPriceText: costPriceText,
            displayNameText: nameText
        )
        if ok {
            dismiss()
        } else {
            inlineErrorMessage = model.errorMessage.isEmpty ? "保存失败，请检查填写。" : model.errorMessage
            model.errorMessage = ""
        }
    }
}
