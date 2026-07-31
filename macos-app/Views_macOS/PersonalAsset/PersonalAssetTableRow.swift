import SwiftUI

struct PersonalAssetTableRow: View {
    @EnvironmentObject private var model: AppModel

    let row: PersonalAssetAggregateRow
    var isCompact: Bool = false
    var colSpacing: CGFloat = 12
    var valuationWidth: CGFloat = 260
    var unitsWidth: CGFloat = 100
    var priceWidth: CGFloat = 120
    var fifthWidth: CGFloat = 150
    var sixthWidth: CGFloat = 190
    var actionWidth: CGFloat = 128
    var labelWidth: CGFloat = 260
    var trendSummary: TrendAssetTagSummary?
    var isSelectedForComparison = false
    var isComparisonToggleDisabled = false
    var allowsHoverFeedback = true
    var onToggleComparison: (() -> Void)?
    var onOpenDetail: (() -> Void)?

    @State private var pendingDeleteScope: PersonalAssetDeleteScope?
    @State private var pendingUnitAdjustmentMode: PersonalAssetUnitAdjustmentMode?
    @State private var isPresentingHoldingEditor = false
    @State private var isPresentingPlanManager = false

    private var profitTint: Color {
        AppPalette.marketTint(for: row.profitAmount)
    }

    private var changeTint: Color {
        AppPalette.marketTint(for: row.estimateChangeAmount)
    }

    var body: some View {
        HStack(alignment: .top, spacing: colSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(row.fundName)
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                        .help(row.fundName)
                    if row.assetType == .stock, let stockMarketLabel = row.detectedMarket?.displayName {
                        ToolbarBadge(title: stockMarketLabel, tint: AppPalette.info)
                    }
                    if row.hasArchivedHolding && !row.hasHolding {
                        ToolbarBadge(title: "已归档", tint: AppPalette.muted)
                    }
                    if row.hasPending {
                        ToolbarBadge(title: "待确认", tint: AppPalette.warning)
                    }
                    if row.activePlanCount > 0 {
                        ToolbarBadge(title: "计划中", tint: AppPalette.info)
                    } else if row.pausedPlanCount > 0 {
                        ToolbarBadge(title: "计划暂停", tint: AppPalette.warning)
                    }
                    if row.hasDrawdownPlan {
                        ToolbarBadge(title: "涨跌幅 \(row.drawdownPlanCount)", tint: AppPalette.info)
                    }
                }
                HStack(spacing: 8) {
                    if let fundCode = row.fundCode, !fundCode.isEmpty {
                        Text(fundCode)
                            .font(AppPalette.appFont(.footnote, design: .monospaced))
                    }
                    if row.pendingTradeCount > 0, let latest = row.pendingTrades.first?.occurredAt {
                        Text("最新待确认 \(latest)")
                    }
                    if row.hasDrawdownPlan {
                        Text("含 \(row.drawdownPlanCount) 条涨跌幅计划")
                    }
                    if let archivedAt = row.archivedHolding?.archivedAt {
                        Text("归档 \(archivedAt.prefix(10))")
                    }
                }
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
                if let trendSummary {
                    trendSignalBlock(trendSummary)
                        .padding(.top, 2)
                }
            }
            .frame(width: labelWidth, alignment: .leading)
            .modifier(AssetTableLabelColumnModifier(isCompact: isCompact, minWidth: labelWidth))

            VStack(alignment: .leading, spacing: 4) {
                Text(row.marketValue.map { currencyText($0, market: row.detectedMarket) } ?? "—")
                    .font(AppPalette.appFont(isCompact ? .subheadline : .body, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                if isCompact {
                    // Compact: combine profit and today change on fewer lines
                    Text("收益 \(signedCurrencyText(row.profitAmount, market: row.detectedMarket)) · \(percentOptional(row.profitPct))")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(profitTint)
                    Text(dailyChangeLine(compact: true))
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(changeTint)
                } else {
                    Text("总收益 \(signedCurrencyText(row.profitAmount, market: row.detectedMarket)) · \(percentOptional(row.profitPct))")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(profitTint)
                    Text(dailyChangeLine(compact: false))
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(changeTint)
                }
            }
            .frame(width: valuationWidth, alignment: .leading)

            if !isCompact {
                VStack(alignment: .leading, spacing: 4) {
                    Text(unitsColumnValue)
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    if let unitsColumnCaption {
                        Text(unitsColumnCaption)
                            .font(AppPalette.appFont(.footnote))
                            .foregroundStyle(AppPalette.muted)
                    }
                }
                .frame(width: unitsWidth, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("\(row.usesMarketTradeColumns ? "现价" : "净值") \(row.currentPrice.map(decimalText) ?? "—")")
                    .font(AppPalette.appFont(isCompact ? .footnote : .subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                if let estimatePrice = row.currentEstimatePrice {
                    if isCompact {
                        Text("估\(decimalText(estimatePrice)) \(percentOptional(row.estimateChangePct))")
                            .font(AppPalette.appFont(.footnote))
                            .foregroundStyle(changeTint)
                    } else {
                        Text("估值 \(decimalText(estimatePrice)) · \(percentOptional(row.estimateChangePct))")
                            .font(AppPalette.appFont(.footnote))
                            .foregroundStyle(changeTint)
                    }
                }
                Text("成本 \(row.costPrice.map(decimalText) ?? "—")")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                if isCompact {
                    Text("份额 \(unitsColumnValue)")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(1)
                }
            }
            .frame(width: priceWidth, alignment: .leading)

            if row.usesMarketTradeColumns {
                Group {
                    if let changePct = row.estimateChangePct {
                        Text(String(format: "%+.2f%%", changePct))
                            .font(AppPalette.appFont(isCompact ? .body : .title3, weight: .bold, design: .rounded))
                            .foregroundStyle(AppPalette.marketTint(for: changePct))
                    } else {
                        Text("—")
                            .font(AppPalette.appFont(.body, weight: .semibold))
                            .foregroundStyle(AppPalette.ink)
                    }
                }
                .frame(width: fifthWidth, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if row.pendingTradeCount > 0 {
                        Text(row.pendingCashAmount > 0 ? currencyText(row.pendingCashAmount, market: row.detectedMarket) : "\(unitsText(row.pendingUnitAmount)) 份")
                            .font(AppPalette.appFont(isCompact ? .subheadline : .body, weight: .semibold))
                            .foregroundStyle(AppPalette.ink)
                        Text("\(row.pendingTradeCount) 笔 · \(row.pendingTrades.first?.actionLabel ?? "待确认")")
                            .font(AppPalette.appFont(.footnote))
                            .foregroundStyle(AppPalette.muted)
                    } else {
                        Text("—")
                            .font(AppPalette.appFont(.body, weight: .semibold))
                            .foregroundStyle(AppPalette.ink)
                        if !isCompact {
                            Text("暂无")
                                .font(AppPalette.appFont(.footnote))
                                .foregroundStyle(AppPalette.muted)
                        }
                    }
                }
                .frame(width: fifthWidth, alignment: .leading)
            }

            if row.usesMarketTradeColumns {
                Group {
                    if let changeAmt = row.estimateChangeAmount {
                        Text(signedCurrencyText(changeAmt, market: row.detectedMarket))
                            .font(AppPalette.appFont(isCompact ? .body : .title3, weight: .bold, design: .rounded))
                            .foregroundStyle(AppPalette.marketTint(for: changeAmt))
                    } else {
                        Text("—")
                            .font(AppPalette.appFont(.body, weight: .semibold))
                            .foregroundStyle(AppPalette.ink)
                    }
                }
                .frame(width: sixthWidth, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                if row.totalPlanCount > 0 {
                    Text("进行中 \(row.activePlanCount) · 暂停 \(row.pausedPlanCount) · 终止 \(row.endedPlanCount)")
                        .font(AppPalette.appFont(isCompact ? .footnote : .subheadline, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    if isCompact {
                        Text("累计 \(currencyText(row.totalCumulativePlanAmount, market: row.detectedMarket))")
                            .font(AppPalette.appFont(.footnote))
                            .foregroundStyle(AppPalette.muted)
                    } else {
                        Text("下次估算 \(currencyText(row.estimatedNextPlanAmount, market: row.detectedMarket)) · 累计 \(currencyText(row.totalCumulativePlanAmount, market: row.detectedMarket))\(row.hasDrawdownPlan ? " · 涨跌幅 \(row.drawdownPlanCount)" : "")")
                            .font(AppPalette.appFont(.footnote))
                            .foregroundStyle(AppPalette.muted)
                    }
                } else {
                    Text("—")
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    if !isCompact {
                        Text("暂无")
                            .font(AppPalette.appFont(.footnote))
                            .foregroundStyle(AppPalette.muted)
                    }
                }
            }
            .frame(width: sixthWidth, alignment: .leading)
            }

            HStack {
                Spacer()
                Button {
                    onToggleComparison?()
                } label: {
                    Image(systemName: isSelectedForComparison ? "checkmark.square.fill" : "square.grid.2x2")
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(isSelectedForComparison ? AppPalette.onBrand : AppPalette.brand)
                        .frame(width: 28, height: 28)
                        .background(isSelectedForComparison ? AppPalette.brand : AppPalette.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                }
                .buttonStyle(PressResponsiveButtonStyle())
                .disabled(isComparisonToggleDisabled)
                .opacity(isComparisonToggleDisabled ? 0.42 : 1)
                .help(isSelectedForComparison ? "移出对比" : "加入对比")
                .accessibilityLabel(isSelectedForComparison ? "将 \(row.fundName) 移出对比" : "将 \(row.fundName) 加入对比")

                Button {
                    onOpenDetail?()
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(AppPalette.info)
                        .frame(width: 28, height: 28)
                        .background(AppPalette.info.opacity(0.08), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                }
                .buttonStyle(PressResponsiveButtonStyle())
                .help("查看详情")
                .accessibilityLabel("查看 \(row.fundName) 详情")

                if hasRowActions {
                    actionMenu
                }
            }
            .frame(width: actionWidth, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            Button {
                onOpenDetail?()
            } label: {
                Color.clear
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.trailing, actionWidth + colSpacing)
            .disabled(onOpenDetail == nil)
            .accessibilityLabel("查看 \(row.fundName) 详情")
            .accessibilityHint("打开资产详情抽屉")
            .help("查看 \(row.fundName) 详情")
        }
        .contentShape(RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .interactiveSurface(
            isSelected: isSelectedForComparison,
            tint: isSelectedForComparison ? AppPalette.brand : AppPalette.info,
            fill: AppPalette.card,
            hoverFill: AppPalette.cardHover,
            selectedFill: AppPalette.brandSoft.opacity(0.76),
            strokeOpacity: 0.28,
            activeStrokeOpacity: 0.62,
            lift: AppPalette.hoverLift,
            allowsHoverFeedback: allowsHoverFeedback
        )
        .alert(deleteConfirmationTitle, isPresented: deleteConfirmationBinding) {
            Button("删除", role: .destructive) {
                if let pendingDeleteScope {
                    model.deletePersonalAssetEntry(row, scope: pendingDeleteScope)
                }
                pendingDeleteScope = nil
            }
            Button("取消", role: .cancel) {
                pendingDeleteScope = nil
            }
        } message: {
            Text(deleteConfirmationMessage)
        }
        .sheet(item: $pendingUnitAdjustmentMode) { mode in
            PersonalAssetUnitAdjustmentSheet(row: row, mode: mode) { unitsText, unitNetValueText in
                model.adjustPersonalAssetHoldingUnits(
                    row,
                    mode: mode,
                    unitsText: unitsText,
                    unitNetValueText: unitNetValueText
                )
            }
        }
        .sheet(isPresented: $isPresentingHoldingEditor) {
            PersonalAssetEditHoldingSheet(row: row)
        }
        .sheet(isPresented: $isPresentingPlanManager) {
            PersonalInvestmentPlanManagementSheet(row: row)
        }
        .contextMenu {
            Button("编辑持仓…") { isPresentingHoldingEditor = true }
            Button("管理计划…") { isPresentingPlanManager = true }
            Divider()
            Button("查看详情…") { onOpenDetail?() }
            if let summary = trendSummary {
                Button("复制趋势摘要") {
                    let text = "\(row.fundName)(\(row.fundCode ?? "-"))：\(summary.impactText)"
                    PasteboardHelper.copy(text)
                }
            }
            Divider()
            Button("删除", role: .destructive) {
                pendingDeleteScope = .all
            }
        }
    }

    private func dailyChangeLine(compact: Bool) -> String {
        guard row.estimateChangeAmount != nil || row.estimateChangePct != nil else {
            if row.usesMarketTradeColumns {
                return compact ? "今日行情待更新" : "今日涨跌 待行情更新"
            }
            return compact ? "今日净值待公布" : "今日涨跌 待净值公布"
        }
        let prefix = compact
            ? (row.changePeriodTitle == "今日涨跌" ? "今日" : "最近")
            : row.changePeriodTitle
        return "\(prefix) \(dailyChangeCurrencyText(row.estimateChangeAmount, market: row.detectedMarket)) · \(dailyChangePercentText(row.estimateChangePct))"
    }

    private func trendSignalBlock(_ summary: TrendAssetTagSummary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(AppPalette.appFont(.caption, weight: .bold))
                    .foregroundStyle((summary.primaryDirection?.assetTagTone ?? .brand).color)
                Text(primaryTrendText(summary))
                    .font(AppPalette.appFont(.footnote, weight: .bold))
                    .foregroundStyle((summary.primaryDirection?.assetTagTone ?? .brand).color)
                    .lineLimit(1)
                Text(summary.impactText)
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }

            HStack(spacing: 6) {
                Text(summary.tradePlan.method)
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
                if !summary.counterSignals.isEmpty {
                    Text("·")
                        .foregroundStyle(AppPalette.muted)
                    Text("\(summary.counterSignals.count) 条反证")
                        .foregroundStyle(AppPalette.warning)
                        .lineLimit(1)
                }
            }
            .font(AppPalette.appFont(.caption, weight: .medium))
        }
    }

    private func primaryTrendText(_ summary: TrendAssetTagSummary) -> String {
        guard let direction = summary.primaryDirection else { return summary.tradePlan.label }
        return "\(summary.tradePlan.label) · \(direction.assetTagText) · \(summary.primaryConfidence.label)"
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteScope != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeleteScope = nil
                }
            }
        )
    }

    private var sourceDeleteScopes: [PersonalAssetDeleteScope] {
        var scopes: [PersonalAssetDeleteScope] = []
        if row.rawHolding != nil || row.holdingRow != nil {
            scopes.append(.holding)
        } else if row.archivedHolding != nil {
            scopes.append(.holding)
        }
        if !row.pendingTrades.isEmpty {
            scopes.append(.pendingTrades)
        }
        if !row.plans.isEmpty {
            scopes.append(.investmentPlans)
        }
        return scopes
    }

    private var canAddHoldingUnits: Bool {
        guard let fundCode = row.fundCode else { return false }
        return !fundCode.isEmpty
    }

    private var canEditHolding: Bool {
        row.rawHolding != nil || row.holdingRow != nil
    }

    private var canArchiveHolding: Bool {
        canEditHolding
    }

    private var canRestoreArchivedHolding: Bool {
        row.archivedHolding != nil && !row.hasHolding
    }

    private var canRemoveHoldingUnits: Bool {
        (row.holdingUnits ?? 0) > 0 && (row.rawHolding != nil || row.holdingRow != nil)
    }

    private var canArchivePlans: Bool {
        row.totalPlanCount > 0
    }

    private var hasRowActions: Bool {
        canEditHolding || canArchiveHolding || canRestoreArchivedHolding || canAddHoldingUnits || canRemoveHoldingUnits || canArchivePlans || !sourceDeleteScopes.isEmpty
    }

    private var unitsColumnValue: String {
        if let holdingUnits = row.holdingUnits {
            return unitsText(holdingUnits)
        }
        if let archivedUnits = row.archivedHolding?.units {
            return unitsText(archivedUnits)
        }
        return "—"
    }

    private var unitsColumnCaption: String? {
        if row.holdingUnits != nil {
            return "持有份额"
        }
        if row.archivedHolding != nil {
            return "归档份额"
        }
        return nil
    }

    private var actionMenu: some View {
        Menu {
            if canEditHolding {
                Button {
                    isPresentingHoldingEditor = true
                } label: {
                    Label("编辑持仓", systemImage: "square.and.pencil")
                }
            }

            if canAddHoldingUnits {
                Button {
                    pendingUnitAdjustmentMode = .add
                } label: {
                    Label("添加份额", systemImage: "plus.circle")
                }
            }

            if canRemoveHoldingUnits {
                Button {
                    pendingUnitAdjustmentMode = .remove
                } label: {
                    Label("删除份额", systemImage: "minus.circle")
                }
            }

            if canArchiveHolding {
                Button {
                    model.archivePersonalAssetHolding(row)
                } label: {
                    Label("归档持仓", systemImage: "archivebox")
                }
            }

            if canRestoreArchivedHolding {
                Button {
                    model.restorePersonalAssetHolding(row)
                } label: {
                    Label("恢复归档持仓", systemImage: "arrow.uturn.backward.circle")
                }
            }

            if (canEditHolding || canAddHoldingUnits || canRemoveHoldingUnits || canArchiveHolding || canRestoreArchivedHolding) && canArchivePlans {
                Divider()
            }

            if canArchivePlans {
                Button {
                    isPresentingPlanManager = true
                } label: {
                    Label("管理定投计划", systemImage: "calendar.badge.clock")
                }

                if row.activePlanCount > 0 {
                    Button {
                        model.updateInvestmentPlansStatus(row, status: "已暂停", activeOnly: true)
                    } label: {
                        Label("暂停进行中计划", systemImage: "pause.circle")
                    }
                    Button {
                        model.updateInvestmentPlansStatus(row, status: "已终止", activeOnly: true)
                    } label: {
                        Label("终止进行中计划", systemImage: "archivebox")
                    }
                }
                if row.pausedPlanCount > 0 || row.endedPlanCount > 0 {
                    Button {
                        model.updateInvestmentPlansStatus(row, status: "进行中", archivedOnly: true)
                    } label: {
                        Label("恢复归档计划", systemImage: "arrow.uturn.backward.circle")
                    }
                }
            }

            if (canAddHoldingUnits || canRemoveHoldingUnits || canArchiveHolding || canRestoreArchivedHolding || canArchivePlans) && !sourceDeleteScopes.isEmpty {
                Divider()
            }

            ForEach(sourceDeleteScopes) { scope in
                Button(role: .destructive) {
                    pendingDeleteScope = scope
                } label: {
                    Label(deleteTitle(for: scope), systemImage: deleteIcon(for: scope))
                }
            }

            if sourceDeleteScopes.count > 1 {
                Divider()
                Button(role: .destructive) {
                    pendingDeleteScope = .all
                } label: {
                    Label(deleteTitle(for: .all), systemImage: deleteIcon(for: .all))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "ellipsis.circle")
                    .font(AppPalette.appFont(.body, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(AppPalette.appFont(.caption2, weight: .bold))
            }
            .foregroundStyle(AppPalette.brand)
            .frame(width: 42, height: 28)
            .background(AppPalette.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("调整条目")
    }

    private var deleteConfirmationTitle: String {
        guard let pendingDeleteScope else { return "删除条目" }
        return "\(deleteTitle(for: pendingDeleteScope))？"
    }

    private var deleteConfirmationMessage: String {
        guard let pendingDeleteScope else { return "" }
        let itemText = row.fundCode.map { "\(row.fundName)（\($0)）" } ?? row.fundName
        return "会从本地保存的数据中删除 \(itemText) 的\(deleteDescription(for: pendingDeleteScope))。这个操作不会影响且慢账户。"
    }

    private func deleteTitle(for scope: PersonalAssetDeleteScope) -> String {
        switch scope {
        case .holding:
            return row.hasArchivedHolding && !row.hasHolding ? "删除归档持仓" : "删除已持有"
        case .pendingTrades:
            return row.pendingTradeCount > 1 ? "删除买入中 \(row.pendingTradeCount) 条" : "删除买入中"
        case .investmentPlans:
            return row.totalPlanCount > 1 ? "删除计划档案 \(row.totalPlanCount) 条" : "删除计划档案"
        case .all:
            return "删除整条明细"
        }
    }

    private func deleteDescription(for scope: PersonalAssetDeleteScope) -> String {
        switch scope {
        case .holding:
            return row.hasArchivedHolding && !row.hasHolding ? "归档持仓记录" : "已持有记录"
        case .pendingTrades:
            return row.pendingTradeCount > 1 ? "\(row.pendingTradeCount) 条买入中记录" : "买入中记录"
        case .investmentPlans:
            return row.totalPlanCount > 1 ? "\(row.totalPlanCount) 条计划档案" : "计划档案"
        case .all:
            return "所有本地明细记录"
        }
    }

    private func deleteIcon(for scope: PersonalAssetDeleteScope) -> String {
        switch scope {
        case .holding:
            return "briefcase"
        case .pendingTrades:
            return "clock"
        case .investmentPlans:
            return "calendar"
        case .all:
            return "trash"
        }
    }
}

private extension TrendAssetTagTone {
    var color: Color {
        switch self {
        case .brand:
            return AppPalette.brand
        case .positive:
            return AppPalette.positive
        case .info:
            return AppPalette.info
        case .warning:
            return AppPalette.warning
        case .danger:
            return AppPalette.danger
        case .muted:
            return AppPalette.muted
        }
    }
}
