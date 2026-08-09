import SwiftUI

private enum PersonalAssetAddTarget {
    case holding
    case pendingTrade
    case investmentPlan
}

struct PersonalAssetAddButtons: View {
    @State private var isShowingAddMenu = false
    @State private var isPresentingAddHoldingSheet = false
    @State private var isPresentingAddPendingTradeSheet = false
    @State private var isPresentingAddInvestmentPlanSheet = false

    var body: some View {
        Button {
            withAnimation(AppPalette.motionFast) {
                isShowingAddMenu.toggle()
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "plus")
                Text("添加")
                Image(systemName: "chevron.down")
                    .font(AppPalette.appFont(.caption2, weight: .bold))
                    .rotationEffect(.degrees(isShowingAddMenu ? 180 : 0))
            }
        }
        .buttonStyle(.appPrimary)
        .accessibilityValue(isShowingAddMenu ? "已展开" : "已折叠")
        .popover(isPresented: $isShowingAddMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                Text("添加资产记录")
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(AppPalette.muted)
                    .padding(.horizontal, 10)
                    .padding(.top, 5)

                addMenuItem(
                    title: "添加持仓",
                    subtitle: "记录已经持有的基金或股票",
                    icon: "briefcase",
                    target: .holding
                )
                addMenuItem(
                    title: "添加买入中",
                    subtitle: "记录尚未确认份额的交易",
                    icon: "clock.badge.exclamationmark",
                    target: .pendingTrade
                )
                addMenuItem(
                    title: "添加计划档案",
                    subtitle: "创建定投或涨跌幅计划",
                    icon: "calendar.badge.clock",
                    target: .investmentPlan
                )
            }
            .padding(8)
            .frame(width: 256)
            .background(AppPalette.card)
        }
        .sheet(isPresented: $isPresentingAddHoldingSheet) {
            PersonalAssetAddHoldingSheet()
        }
        .sheet(isPresented: $isPresentingAddPendingTradeSheet) {
            PersonalPendingTradeEditSheet()
        }
        .sheet(isPresented: $isPresentingAddInvestmentPlanSheet) {
            PersonalInvestmentPlanAddSheet()
        }
    }

    private func addMenuItem(
        title: String,
        subtitle: String,
        icon: String,
        target: PersonalAssetAddTarget
    ) -> some View {
        Button {
            present(target)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.brand)
                    .accentIconStyle(tint: AppPalette.brand, size: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(AppPalette.ink)
                    Text(subtitle)
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(AppPalette.appFont(.caption2, weight: .bold))
                    .foregroundStyle(AppPalette.muted)
            }
        }
        .buttonStyle(.appMenuItem)
    }

    private func present(_ target: PersonalAssetAddTarget) {
        isShowingAddMenu = false
        Task { @MainActor in
            await Task.yield()
            switch target {
            case .holding:
                isPresentingAddHoldingSheet = true
            case .pendingTrade:
                isPresentingAddPendingTradeSheet = true
            case .investmentPlan:
                isPresentingAddInvestmentPlanSheet = true
            }
        }
    }
}

struct PersonalPortfolioEmptyState: View {
    @State private var isPresentingAddHoldingSheet = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "briefcase.fill")
                .font(AppPalette.appFont(.largeTitle, weight: .semibold))
                .foregroundStyle(AppPalette.brand)
                .frame(width: 48, height: 48)
                .background(AppPalette.brand.opacity(0.10), in: RoundedRectangle(cornerRadius: AppPalette.iconBoxRadius))

            VStack(spacing: 6) {
                Text("添加第一笔持仓")
                    .font(AppPalette.appFont(.title2, weight: .bold))
                    .foregroundStyle(AppPalette.ink)

                Text("输入基金或股票代码、份额和成本，系统会自动识别并汇总市值与收益。")
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
                    .multilineTextAlignment(.center)
            }

            Button {
                isPresentingAddHoldingSheet = true
            } label: {
                Label("添加第一笔持仓", systemImage: "plus")
                    .font(AppPalette.appFont(.headline, weight: .semibold))
            }
            .buttonStyle(.appPrimary)
            .tint(AppPalette.brand)
            .controlSize(.large)
            .accessibilityHint("打开持仓录入表单")
        }
        .frame(maxWidth: .infinity, minHeight: 360)
        .padding(20)
        .sheet(isPresented: $isPresentingAddHoldingSheet) {
            PersonalAssetAddHoldingSheet()
        }
    }
}

struct PersonalAssetAddHoldingSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var codeText = ""
    @State private var unitsText = ""
    @State private var costPriceText = ""
    @State private var codeResolution: PersonalAssetCodeResolution?
    @State private var isResolvingName = false
    @State private var hasResolvedName = false
    @State private var inlineErrorMessage = ""
    @FocusState private var focusedField: HoldingField?

    private enum HoldingField: Hashable {
        case units, cost
    }

    private var lookupKey: String {
        codeText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: codeResolution?.assetType == .stock ? "chart.line.uptrend.xyaxis" : "chart.pie")
                    .font(AppPalette.appFont(.title, weight: .semibold))
                    .foregroundStyle(codeResolution?.assetType == .stock ? AppPalette.info : AppPalette.brand)
                VStack(alignment: .leading, spacing: 4) {
                    Text("添加持仓")
                        .font(AppPalette.appFont(.title2, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text("填写代码、份额和成本，系统会按代码自动判断场外基金、场内基金或股票。")
                        .font(AppPalette.appFont(.subheadline))
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("代码或名称")
                        .font(AppPalette.appFont(.subheadline, weight: .medium))
                        .foregroundStyle(AppPalette.muted)
                    FundSearchField(code: $codeText) { result in
                        codeText = result.code
                        codeResolution = PersonalAssetCodeResolution(
                            assetType: result.assetType,
                            code: result.code,
                            displayName: result.name
                        )
                        hasResolvedName = true
                    }
                }
                addHoldingField("份额", text: $unitsText, placeholder: "例如 100.00", field: .units)
                addHoldingField("成本", text: $costPriceText, placeholder: "例如 1.2345", field: .cost)
            }

            nameLookupStatus

            if !inlineErrorMessage.isEmpty {
                ToastBar(text: inlineErrorMessage, tint: AppPalette.danger, onDismiss: { inlineErrorMessage = "" })
            }

            HStack(spacing: 10) {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .buttonStyle(.appSecondary)
                .keyboardShortcut(.cancelAction)

                Button("添加") {
                    inlineErrorMessage = ""
                    guard let codeResolution else { return }
                    if model.addPersonalAssetHolding(
                        assetType: codeResolution.assetType,
                        codeText: codeResolution.code,
                        unitsText: unitsText,
                        costPriceText: costPriceText,
                        displayName: codeResolution.displayName,
                        stockMarket: codeResolution.stockMarket,
                        fundMarket: codeResolution.fundMarket
                    ) {
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
                .disabled(codeResolution == nil || isResolvingName)
                .buttonStyle(.appPrimary)
                .tint(codeResolution?.assetType == .stock ? AppPalette.info : AppPalette.brand)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 400)
        .task(id: lookupKey) {
            await resolveName(for: codeText)
        }
    }

    private var nameLookupStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: nameStatusIcon)
                .font(AppPalette.appFont(.body, weight: .semibold))
                .foregroundStyle(nameStatusTint)
            Text(nameStatusText)
                .font(AppPalette.appFont(.subheadline))
                .foregroundStyle(nameStatusTint)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(nameStatusTint.opacity(AppPalette.accentSubtle), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
    }

    private var nameStatusIcon: String {
        if codeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "magnifyingglass"
        }
        if isResolvingName {
            return "arrow.clockwise"
        }
        if codeResolution?.displayName != nil {
            return "checkmark.circle"
        }
        if codeResolution != nil {
            return "checkmark.circle"
        }
        return "exclamationmark.circle"
    }

    private var nameStatusText: String {
        if codeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "输入代码后自动判断类型并识别名称"
        }
        if isResolvingName {
            return "正在判断类型和识别名称…"
        }
        if let codeResolution {
            if let displayName = codeResolution.displayName, !displayName.isEmpty {
                return "判断为：\(resolutionTypeLabel(codeResolution)) · \(displayName)"
            }
            return "判断为：\(resolutionTypeLabel(codeResolution))，暂未识别到名称"
        }
        if hasResolvedName {
            return "暂时无法判断类型，请检查代码"
        }
        return "输入代码后自动判断类型并识别名称"
    }

    private var nameStatusTint: Color {
        if isResolvingName {
            return AppPalette.info
        }
        if codeResolution?.displayName != nil {
            return AppPalette.positive
        }
        if codeResolution != nil {
            return AppPalette.info
        }
        if hasResolvedName {
            return AppPalette.warning
        }
        return AppPalette.muted
    }

    private func resolutionTypeLabel(_ resolution: PersonalAssetCodeResolution) -> String {
        if resolution.assetType == .stock {
            return resolution.stockMarket?.displayName ?? resolution.assetType.displayName
        }
        return resolution.fundMarket?.displayName ?? resolution.assetType.displayName
    }

    private func addHoldingField(_ label: String, text: Binding<String>, placeholder: String, field: HoldingField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(AppPalette.appFont(.subheadline, weight: .medium))
                .foregroundStyle(AppPalette.muted)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .inputFieldStyle()
                .focused($focusedField, equals: field)
        }
    }

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
}

struct PersonalAssetEditHoldingSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let row: PersonalAssetAggregateRow

    @State private var codeText: String
    @State private var nameText: String
    @State private var unitsText: String
    @State private var costPriceText: String
    @State private var inlineErrorMessage = ""
    @FocusState private var focusedField: HoldingField?

    private enum HoldingField: Hashable {
        case name, code, units, cost
    }

    private var holding: UserPortfolioHolding? {
        row.rawHolding ?? row.holdingRow?.holding
    }

    init(row: PersonalAssetAggregateRow) {
        self.row = row
        let holding = row.rawHolding ?? row.holdingRow?.holding
        _codeText = State(initialValue: holding?.normalizedFundCode ?? row.fundCode ?? "")
        _nameText = State(initialValue: holding?.normalizedName ?? row.fundName)
        _unitsText = State(initialValue: holding.map { Self.formattedUnitsText($0.units) } ?? "")
        _costPriceText = State(initialValue: holding?.costPrice.map(decimalText) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(AppPalette.appFont(.title, weight: .semibold))
                    .foregroundStyle(AppPalette.brand)
                VStack(alignment: .leading, spacing: 4) {
                    Text("编辑持仓")
                        .font(AppPalette.appFont(.title2, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text(holdingMarketLabel)
                        .font(AppPalette.appFont(.subheadline))
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer()
            }

            if holding == nil {
                Text("这条资产没有已持有记录。")
                    .font(AppPalette.appFont(.body))
                    .foregroundStyle(AppPalette.muted)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    editField("名称", text: $nameText, placeholder: "可留空，按代码自动补全", field: .name)
                    editField("代码", text: $codeText, placeholder: "例如 021550 / ETF:510300 / HK:00700 / US:AAPL", field: .code)
                    editField("份额", text: $unitsText, placeholder: "例如 100.00", field: .units)
                    editField("成本价", text: $costPriceText, placeholder: "可留空", field: .cost)
                }
            }

            if !inlineErrorMessage.isEmpty {
                ToastBar(text: inlineErrorMessage, tint: AppPalette.danger, onDismiss: { inlineErrorMessage = "" })
            }

            HStack(spacing: 10) {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .buttonStyle(.appSecondary)
                .keyboardShortcut(.cancelAction)

                Button("保存") {
                    inlineErrorMessage = ""
                    if model.updatePersonalAssetHolding(
                        row,
                        codeText: codeText,
                        unitsText: unitsText,
                        costPriceText: costPriceText,
                        displayNameText: nameText
                    ) {
                        dismiss()
                    } else {
                        inlineErrorMessage = model.errorMessage.isEmpty ? "保存失败，请检查填写内容。" : model.errorMessage
                        model.errorMessage = ""
                        if codeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            focusedField = .code
                        } else if unitsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            focusedField = .units
                        } else {
                            focusedField = .cost
                        }
                    }
                }
                .buttonStyle(.appPrimary)
                .tint(AppPalette.brand)
                .disabled(holding == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private var holdingMarketLabel: String {
        if row.assetType == .stock {
            return holding?.detectedMarket?.displayName ?? row.detectedMarket?.displayName ?? row.assetType.displayName
        }
        return holding?.detectedFundMarket?.displayName ?? row.detectedFundMarket?.displayName ?? row.assetType.displayName
    }

    private func editField(_ label: String, text: Binding<String>, placeholder: String, field: HoldingField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(AppPalette.appFont(.subheadline, weight: .medium))
                .foregroundStyle(AppPalette.muted)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .inputFieldStyle()
                .focused($focusedField, equals: field)
        }
    }

    private static func formattedUnitsText(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.0000001 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.4f", value)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}

struct PersonalAssetUnitAdjustmentSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let row: PersonalAssetAggregateRow
    let mode: PersonalAssetUnitAdjustmentMode
    let onSubmit: (String, String) -> Bool

    @State private var adjustmentUnitsText: String
    @State private var adjustmentUnitNetValueText: String
    @State private var inlineErrorMessage = ""
    @FocusState private var focusedField: AdjustmentField?

    private enum AdjustmentField: Hashable {
        case units, netValue
    }

    init(
        row: PersonalAssetAggregateRow,
        mode: PersonalAssetUnitAdjustmentMode,
        onSubmit: @escaping (String, String) -> Bool
    ) {
        self.row = row
        self.mode = mode
        self.onSubmit = onSubmit
        _adjustmentUnitsText = State(initialValue: "")
        _adjustmentUnitNetValueText = State(initialValue: row.currentPrice.map(decimalText) ?? row.costPrice.map(decimalText) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: mode == .add ? "plus.circle" : "minus.circle")
                    .font(AppPalette.appFont(.title, weight: .semibold))
                    .foregroundStyle(mode == .add ? AppPalette.positive : AppPalette.warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode == .add ? "添加份额" : "删除份额")
                        .font(AppPalette.appFont(.title2, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text(row.fundCode.map { "\(row.fundName)（\($0)）" } ?? row.fundName)
                        .font(AppPalette.appFont(.subheadline))
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                adjustmentField("份额", text: $adjustmentUnitsText, placeholder: "例如 100.00", field: .units)
                adjustmentField("单位净值", text: $adjustmentUnitNetValueText, placeholder: "例如 1.2345", field: .netValue)
            }

            if !inlineErrorMessage.isEmpty {
                ToastBar(text: inlineErrorMessage, tint: AppPalette.danger, onDismiss: { inlineErrorMessage = "" })
            }

            if mode == .remove, let holdingUnits = row.holdingUnits {
                Text("当前份额 \(unitsText(holdingUnits))。删除份额会按填写的单位净值扣减成本金额。")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
            } else {
                Text("添加份额会用填写的单位净值和现有成本加权重算成本价。")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .buttonStyle(.appSecondary)
                .keyboardShortcut(.cancelAction)

                Button(mode == .add ? "添加" : "删除") {
                    inlineErrorMessage = ""
                    if onSubmit(adjustmentUnitsText, adjustmentUnitNetValueText) {
                        dismiss()
                    } else {
                        inlineErrorMessage = model.errorMessage.isEmpty ? "调整失败，请检查填写内容。" : model.errorMessage
                        model.errorMessage = ""
                        focusedField = adjustmentUnitsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .units : .netValue
                    }
                }
                .buttonStyle(mode == .add ? .appPrimary : .appDanger)
                .tint(mode == .add ? AppPalette.positive : AppPalette.warning)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 380)
    }

    private func adjustmentField(_ label: String, text: Binding<String>, placeholder: String, field: AdjustmentField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(AppPalette.appFont(.subheadline, weight: .medium))
                .foregroundStyle(AppPalette.muted)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .inputFieldStyle()
                .focused($focusedField, equals: field)
        }
    }
}

struct PlanArchiveGroup: View {
    @EnvironmentObject private var model: AppModel

    let title: String
    let tint: Color
    let plans: [PersonalInvestmentPlan]

    @State private var editingPlan: PersonalInvestmentPlan?
    @State private var deletingPlan: PersonalInvestmentPlan?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(AppPalette.appFont(.body, weight: .bold))
                    .foregroundStyle(tint)
                Text("\(plans.count) 条")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
            }

            LazyVStack(spacing: 10) {
                ForEach(plans) { plan in
                    InvestmentPlanCard(
                        plan: plan,
                        onEdit: { editingPlan = plan },
                        onDelete: { deletingPlan = plan }
                    )
                }
            }
        }
        .sheet(item: $editingPlan) { plan in
            PersonalInvestmentPlanEditSheet(plan: plan)
        }
        .alert("删除定投计划？", isPresented: deleteConfirmationBinding) {
            Button("删除", role: .destructive) {
                if let deletingPlan {
                    model.deleteInvestmentPlan(deletingPlan.id)
                }
                deletingPlan = nil
            }
            Button("取消", role: .cancel) {
                deletingPlan = nil
            }
        } message: {
            Text(deleteConfirmationMessage)
        }
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { deletingPlan != nil },
            set: { isPresented in
                if !isPresented {
                    deletingPlan = nil
                }
            }
        )
    }

    private var deleteConfirmationMessage: String {
        guard let deletingPlan else { return "" }
        let itemText = deletingPlan.fundCode.map { "\(deletingPlan.fundName)（\($0)）" } ?? deletingPlan.fundName
        return "会从本地保存的数据中删除 \(itemText) 的这条计划档案。"
    }
}
