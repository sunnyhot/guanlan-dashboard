import SwiftUI

// MARK: - Menu Bar Panel

extension SettingsSectionView {
    var menuBarPanel: some View {
        let tickerEntries = model.menuBarTickerVisibleEntries

        return SettingsPanel(title: "菜单栏", subtitle: "选择常驻系统菜单栏的资产摘要、外观与轮播顺序", icon: "menubar.rectangle") {
            VStack(alignment: .leading, spacing: AppPalette.spaceXL) {
                SettingsToggleRow(
                    title: "启用菜单栏数据",
                    detail: "关闭后菜单栏恢复为普通持仓状态标题",
                    icon: "eye",
                    tint: model.menuBarTickerSettings.isEnabled ? AppPalette.info : AppPalette.muted,
                    isOn: menuBarTickerEnabledBinding
                )

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: AppPalette.spaceXL) {
                        menuBarStyleCard(entries: tickerEntries)
                            .frame(minWidth: 360, maxWidth: .infinity)
                        menuBarSelectionCard
                            .frame(minWidth: 420, maxWidth: .infinity)
                    }

                    VStack(spacing: AppPalette.spaceXL) {
                        menuBarStyleCard(entries: tickerEntries)
                        menuBarSelectionCard
                    }
                }
            }
        }
        .alert("恢复菜单栏默认设置？", isPresented: $isConfirmingMenuBarReset) {
            Button("恢复默认", role: .destructive) {
                model.resetMenuBarTickerSettings()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("显示项目、顺序和样式都会恢复为默认值。")
        }
        .alert("清空所有单标的？", isPresented: $isConfirmingHoldingSelectionClear) {
            Button("清空", role: .destructive) {
                model.clearMenuBarHoldingSelections()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("整体资产和大盘指数设置会保留，所有单个持仓指标将从菜单栏移除。")
        }
    }

    private func menuBarStyleCard(entries: [MenuBarTickerEntry]) -> some View {
        SettingsCardGroup(
            title: "菜单栏样式配置",
            subtitle: "预览、显示数量、颜色、字号、间距",
            icon: "paintbrush",
            tint: AppPalette.info
        ) {
            VStack(alignment: .leading, spacing: menuBarStyleSectionSpacing) {
                menuBarPreview(entries: entries)
                menuBarStyleOptions
            }
            .padding(.vertical, 12)
        }
    }

    private var menuBarSelectionCard: some View {
        SettingsCardGroup(
            title: "资产项选择",
            subtitle: "整体资产、大盘指数、基金分组、单个标的",
            icon: "chart.bar",
            tint: AppPalette.info
        ) {
            VStack(alignment: .leading, spacing: 0) {
                menuBarOptionGroup(title: "整体资产", subtitle: "总资产、整体今日涨跌和整体持有收益", kinds: MenuBarTickerKind.overallKinds)

                SettingsDivider(isInset: true)

                menuBarOptionGroup(title: "自动 Top 标的", subtitle: "自动把今日波动最大、收益率最高的单个标的放到菜单栏", kinds: MenuBarTickerKind.automaticKinds)

                SettingsDivider(isInset: true)

                menuBarOptionGroup(title: "AI 研判姿态", subtitle: "盘中研判的总体倾向;无报告或已过期会如实标注", kinds: [.aiPosture])

                SettingsDivider(isInset: true)

                menuBarMarketIndexOptions

                SettingsDivider(isInset: true)

                menuBarFundMarketOptions

                SettingsDivider(isInset: true)

                menuBarHoldingOptions

                if model.menuBarTickerSettings.selections.count > model.menuBarTickerSettings.maxVisibleItems {
                    SettingsDivider(isInset: true)
                    menuBarCarouselOrder
                }

                SettingsDivider(isInset: true)

                SettingsActionRow {
                    Button {
                        isConfirmingMenuBarReset = true
                    } label: {
                        Label("恢复默认", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.appSecondary)

                    Button {
                        isConfirmingHoldingSelectionClear = true
                    } label: {
                        Label("清空单标的", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.appSecondary)
                    .disabled(!model.menuBarTickerSettings.selections.contains(where: { $0.holdingValue != nil }))
                }
            }
        }
    }

    // MARK: - Style Options

    private var menuBarStyleSectionSpacing: CGFloat { 10 }

    private var menuBarStyleRowSpacing: CGFloat { 4 }

    private var menuBarStyleRowHeight: CGFloat { 28 }

    private var menuBarStyleGridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
        ]
    }

    private var menuBarStyleOptions: some View {
        let appearance = model.menuBarTickerSettings.appearance.normalized()

        func capsuleBtn(text: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Text(text)
                    .font(AppPalette.appFont(.caption, weight: .medium))
                    .foregroundStyle(isSelected ? AppPalette.onBrand : AppPalette.muted)
                    .padding(.horizontal, 9)
                    .frame(minHeight: 28)
                    .background(Capsule().fill(isSelected ? AppPalette.brand : AppPalette.card))
                    .overlay(Capsule().stroke(isSelected ? AppPalette.brand : AppPalette.line, lineWidth: 1))
            }
            .buttonStyle(PressResponsiveButtonStyle())
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .help(text)
        }

        return VStack(alignment: .leading, spacing: 0) {
            LazyVGrid(columns: menuBarStyleGridColumns, spacing: menuBarStyleRowSpacing) {
                menuBarStyleRow(icon: "square.on.square", title: "同时显示 \(model.menuBarTickerSettings.maxVisibleItems) 项") {
                    menuBarStyleStepper(label: "显示数量", value: model.menuBarTickerSettings.maxVisibleItems, minValue: 1, maxValue: MenuBarTickerSettings.maxVisibleItemsLimit,
                        decrement: { model.setMenuBarTickerMaxVisibleItems(max(1, model.menuBarTickerSettings.maxVisibleItems - 1)) },
                        increment: { model.setMenuBarTickerMaxVisibleItems(min(MenuBarTickerSettings.maxVisibleItemsLimit, model.menuBarTickerSettings.maxVisibleItems + 1)) }
                    )
                }

                if model.menuBarTickerConfiguredItemCount > model.menuBarTickerSettings.maxVisibleItems {
                    menuBarStyleRow(icon: "timer", title: "轮播间隔 \(Int(model.menuBarTickerSettings.carouselIntervalSeconds)) 秒") {
                        menuBarStyleStepper(label: "轮播间隔", value: Int(model.menuBarTickerSettings.carouselIntervalSeconds), minValue: Int(MenuBarTickerSettings.minCarouselInterval), maxValue: Int(MenuBarTickerSettings.maxCarouselInterval),
                            decrement: { model.setMenuBarTickerCarouselInterval(max(MenuBarTickerSettings.minCarouselInterval, model.menuBarTickerSettings.carouselIntervalSeconds - 1)) },
                            increment: { model.setMenuBarTickerCarouselInterval(min(MenuBarTickerSettings.maxCarouselInterval, model.menuBarTickerSettings.carouselIntervalSeconds + 1)) }
                        )
                    }
                } else {
                    Color.clear
                        .frame(height: menuBarStyleRowHeight)
                }

                menuBarStyleRow(icon: "paintpalette", title: "颜色") {
                    HStack(spacing: 4) {
                        capsuleBtn(text: "系统", isSelected: appearance.textColorMode == .system) {
                            model.updateMenuBarTickerAppearance { a in a.textColorMode = .system }
                        }
                        capsuleBtn(text: "自定", isSelected: appearance.textColorMode == .custom) {
                            model.updateMenuBarTickerAppearance { a in a.textColorMode = .custom }
                        }
                        if appearance.textColorMode == .custom {
                            ColorPicker("自定义文字颜色", selection: menuBarTickerCustomColorBinding, supportsOpacity: false)
                                .labelsHidden()
                                .controlSize(.mini)
                                .help("选择自定义文字颜色")
                        }
                    }
                }

                menuBarStyleRow(icon: "square.grid.2x2", title: "排列") {
                    HStack(spacing: 4) {
                        ForEach(MenuBarTickerLayoutMode.allCases) { mode in
                            Button {
                                model.updateMenuBarTickerAppearance { a in a.layoutMode = mode }
                            } label: {
                                Image(systemName: mode.icon)
                                    .font(AppPalette.appFont(.caption, weight: .semibold))
                                    .foregroundStyle(appearance.layoutMode == mode ? AppPalette.onBrand : AppPalette.muted)
                                    .frame(width: 32, height: 28)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(appearance.layoutMode == mode ? AppPalette.brand : AppPalette.card))
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(appearance.layoutMode == mode ? AppPalette.brand : AppPalette.line, lineWidth: 1))
                            }
                            .buttonStyle(PressResponsiveButtonStyle())
                            .accessibilityLabel("排列：\(mode.label)")
                            .accessibilityAddTraits(appearance.layoutMode == mode ? .isSelected : [])
                            .help(mode.label)
                        }
                    }
                }

                menuBarStyleRow(icon: "textformat.size", title: "字号") {
                    menuBarStyleStepper(label: "字号", value: Int(appearance.fontSize), minValue: Int(MenuBarTickerAppearance.minFontSize), maxValue: Int(MenuBarTickerAppearance.maxFontSize),
                        decrement: { model.updateMenuBarTickerAppearance { a in a.fontSize = max(MenuBarTickerAppearance.minFontSize, a.fontSize - 1) } },
                        increment: { model.updateMenuBarTickerAppearance { a in a.fontSize = min(MenuBarTickerAppearance.maxFontSize, a.fontSize + 1) } }
                    )
                }

                menuBarStyleRow(icon: "bold", title: "字重") {
                    capsuleBtn(text: appearance.isBold ? "加粗" : "常规", isSelected: appearance.isBold) {
                        model.updateMenuBarTickerAppearance { a in a.isBold.toggle() }
                    }
                }

                menuBarStyleRow(icon: "arrow.left.and.right", title: "间距") {
                    HStack(spacing: 4) {
                        capsuleBtn(text: "自动", isSelected: appearance.spacingMode == .automatic) {
                            model.updateMenuBarTickerAppearance { a in a.spacingMode = .automatic }
                        }
                        capsuleBtn(text: "手动", isSelected: appearance.spacingMode == .manual) {
                            model.updateMenuBarTickerAppearance { a in a.spacingMode = .manual }
                        }
                        if appearance.spacingMode == .manual {
                            menuBarStyleStepper(label: "间距", value: Int(appearance.manualSpacing), minValue: Int(MenuBarTickerAppearance.minManualSpacing), maxValue: Int(MenuBarTickerAppearance.maxManualSpacing),
                                decrement: { model.updateMenuBarTickerAppearance { a in a.manualSpacing = max(MenuBarTickerAppearance.minManualSpacing, a.manualSpacing - 1) } },
                                increment: { model.updateMenuBarTickerAppearance { a in a.manualSpacing = min(MenuBarTickerAppearance.maxManualSpacing, a.manualSpacing + 1) } }
                            )
                        }
                    }
                }

                menuBarStyleRow(icon: "rectangle", title: "宽度") {
                    HStack(spacing: 4) {
                        capsuleBtn(text: "自动", isSelected: appearance.widthMode == .automatic) {
                            model.updateMenuBarTickerAppearance { a in a.widthMode = .automatic }
                        }
                        capsuleBtn(text: "手动", isSelected: appearance.widthMode == .manual) {
                            model.updateMenuBarTickerAppearance { a in a.widthMode = .manual }
                        }
                        if appearance.widthMode == .manual {
                            menuBarStyleStepper(label: "宽度", value: Int(appearance.manualWidth), minValue: Int(MenuBarTickerAppearance.minManualWidth), maxValue: Int(MenuBarTickerAppearance.maxManualWidth),
                                decrement: { model.updateMenuBarTickerAppearance { a in a.manualWidth = max(MenuBarTickerAppearance.minManualWidth, a.manualWidth - 4) } },
                                increment: { model.updateMenuBarTickerAppearance { a in a.manualWidth = min(MenuBarTickerAppearance.maxManualWidth, a.manualWidth + 4) } }
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Carousel Order

    private var menuBarCarouselOrder: some View {
        let selections = model.menuBarTickerSettings.selections
        let rows = model.userPortfolioSnapshot?.rows ?? []
        let rowsByID = Dictionary(rows.map { ($0.holding.id, $0) }, uniquingKeysWith: { first, _ in first })

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.info)
                    .frame(width: 24, height: 24)
                    .background(AppPalette.info.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                Text("轮播顺序")
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Text("拖拽或按钮排序")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
            }
            FlowLayout(spacing: 6) {
                ForEach(selections) { selection in
                    carouselOrderPill(selection: selection, selections: selections, rowsByID: rowsByID)
                }
            }
        }
    }

    private func selectionLabel(_ selection: MenuBarTickerSelection, rowsByID: [UUID: UserPortfolioValuationRow]) -> String {
        switch selection {
        case .kind(let kind):
            return kind.label
        case .holding(let sel):
            let name = rowsByID[sel.holdingID].map { compactAssetName($0.fundName) } ?? "标的"
            return "\(name) \(sel.metric.label)"
        }
    }

    private func carouselOrderPill(selection: MenuBarTickerSelection, selections: [MenuBarTickerSelection], rowsByID: [UUID: UserPortfolioValuationRow]) -> some View {
        let isSource = draggedTickerSelectionID == selection.id
        let isTarget = tickerDropTargetID == selection.id
        let label = selectionLabel(selection, rowsByID: rowsByID)

        let selectionIndex = selections.firstIndex(where: { $0.id == selection.id }) ?? 0

        return HStack(spacing: 2) {
            Button {
                moveCarouselSelection(selection, in: selections, offset: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(AppPalette.appFont(.caption2, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(selectionIndex == 0)
            .opacity(selectionIndex == 0 ? 0.35 : 1)
            .accessibilityLabel("向前移动 \(label)")
            .help("向前移动")

            Text(label)
                .font(AppPalette.appFont(.footnote, weight: .medium))
                .foregroundStyle(isSource ? AppPalette.muted : AppPalette.ink)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .draggable(selection.id) {
                    Text(label)
                        .font(AppPalette.appFont(.footnote, weight: .medium))
                        .foregroundStyle(AppPalette.onBrand)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(AppPalette.brand.opacity(0.25)))
                        .overlay(Capsule().stroke(AppPalette.brand, lineWidth: 1))
                        .onAppear { draggedTickerSelectionID = selection.id }
                }
                .accessibilityLabel("\(label)，第 \(selectionIndex + 1) 项")
                .accessibilityHint("可拖拽，或使用两侧按钮调整顺序")

            Button {
                moveCarouselSelection(selection, in: selections, offset: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(AppPalette.appFont(.caption2, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(selectionIndex == selections.count - 1)
            .opacity(selectionIndex == selections.count - 1 ? 0.35 : 1)
            .accessibilityLabel("向后移动 \(label)")
            .help("向后移动")
        }
            .background(Capsule().fill(isTarget ? AppPalette.brand.opacity(0.12) : AppPalette.card))
            .overlay(
                Capsule()
                    .stroke(isTarget ? AppPalette.brand.opacity(0.6) : AppPalette.line.opacity(0.5), lineWidth: isTarget ? 1.5 : 1)
            )
            .overlay(alignment: .leading) {
                if isTarget {
                    Capsule()
                        .fill(AppPalette.brand)
                        .frame(width: 3, height: 14)
                        .offset(x: -6)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .dropDestination(for: String.self) { items, _ in
                draggedTickerSelectionID = nil
                tickerDropTargetID = nil
                guard let droppedID = items.first else { return false }
                guard let fromIndex = selections.firstIndex(where: { $0.id == droppedID }) else { return false }
                guard let toIndex = selections.firstIndex(where: { $0.id == selection.id }) else { return false }
                if fromIndex == toIndex { return false }
                model.moveMenuBarTickerSelection(from: IndexSet(integer: fromIndex), to: toIndex > fromIndex ? toIndex + 1 : toIndex)
                return true
            } isTargeted: { isTarget in
                withAnimation(.easeInOut(duration: 0.15)) {
                    tickerDropTargetID = isTarget ? selection.id : nil
                }
            }
    }

    private func moveCarouselSelection(_ selection: MenuBarTickerSelection, in selections: [MenuBarTickerSelection], offset: Int) {
        guard let sourceIndex = selections.firstIndex(where: { $0.id == selection.id }) else { return }
        let targetIndex = sourceIndex + offset
        guard selections.indices.contains(targetIndex) else { return }
        let destination = offset > 0 ? targetIndex + 1 : targetIndex
        model.moveMenuBarTickerSelection(from: IndexSet(integer: sourceIndex), to: destination)
    }

    // MARK: - Fund Market Options

    private var menuBarFundMarketOptions: some View {
        DisclosureGroup(isExpanded: $isMenuBarFundMarketExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("场外")
                        .font(AppPalette.appFont(.footnote, weight: .semibold))
                        .foregroundStyle(AppPalette.muted)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], alignment: .leading, spacing: 8) {
                        fundMarketToggle(.offExchangeDailyAmount, "场外涨跌额")
                        fundMarketToggle(.offExchangeDailyPct, "场外涨跌率")
                        fundMarketToggle(.offExchangeProfitAmount, "场外收益额")
                        fundMarketToggle(.offExchangeProfitPct, "场外收益率")
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("场内")
                        .font(AppPalette.appFont(.footnote, weight: .semibold))
                        .foregroundStyle(AppPalette.muted)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], alignment: .leading, spacing: 8) {
                        fundMarketToggle(.onExchangeDailyAmount, "场内涨跌额")
                        fundMarketToggle(.onExchangeDailyPct, "场内涨跌率")
                        fundMarketToggle(.onExchangeProfitAmount, "场内收益额")
                        fundMarketToggle(.onExchangeProfitPct, "场内收益率")
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("基金分组")
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text("按场外基金、场内基金聚合涨跌与收益")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer()
            }
        }
        .disclosureGroupStyle(FullRowDisclosureGroupStyle())
        .padding(.vertical, 14)
    }

    private func menuBarTickerSelectionToggle(isOn: Binding<Bool>, label: String) -> some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.checkbox)
            .font(AppPalette.appFont(.footnote, weight: .medium))
            .foregroundStyle(AppPalette.muted)
            .fixedSize()
    }

    private func fundMarketToggle(_ kind: MenuBarTickerKind, _ label: String) -> some View {
        menuBarTickerSelectionToggle(
            isOn: Binding(
                get: { model.isMenuBarTickerKindEnabled(kind) },
                set: { model.setMenuBarTickerKind(kind, isEnabled: $0) }
            ),
            label: label
        )
    }

    // MARK: - Market Index Options

    private var menuBarMarketIndexOptions: some View {
        DisclosureGroup(isExpanded: $isMenuBarMarketIndexExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                menuBarIndexGroupToggles(title: "A股", kinds: [.sseComposite, .csi300, .chinext])
                menuBarIndexGroupToggles(title: "港股", kinds: [.hsi])
                menuBarIndexGroupToggles(title: "美股", kinds: [.nasdaq, .sp500, .dowJones])

                HStack(spacing: 10) {
                    Text(model.isRefreshingMarketIndices ? "大盘行情刷新中…" : "行情来自腾讯指数报价，开启任一项后自动刷新。")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        Task { await model.refreshMarketIndices(kinds: MarketIndexKind.allCases, updateNotice: true) }
                    } label: {
                        Label(model.isRefreshingMarketIndices ? "刷新中" : "刷新大盘", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.appSecondary)
                    .controlSize(.small)
                    .disabled(model.isRefreshingMarketIndices)
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("大盘指数")
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text("按指数开启点位、涨跌点或涨跌率")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer()
            }
        }
        .disclosureGroupStyle(FullRowDisclosureGroupStyle())
        .padding(.vertical, 14)
    }

    private func menuBarIndexGroupToggles(title: String, kinds: [MarketIndexKind]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(AppPalette.appFont(.footnote, weight: .semibold))
                .foregroundStyle(AppPalette.muted)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(kinds) { indexKind in
                    ForEach([
                        (MarketIndexMetric.changePct, "涨跌率"),
                        (MarketIndexMetric.changeAmount, "涨跌点"),
                        (MarketIndexMetric.level, "点位"),
                    ], id: \.0) { metric, label in
                        if let kind = MenuBarTickerKind.tickerKind(indexKind: indexKind, metric: metric) {
                            menuBarTickerSelectionToggle(
                                isOn: Binding(
                                    get: { model.isMenuBarTickerKindEnabled(kind) },
                                    set: { model.setMenuBarTickerKind(kind, isEnabled: $0) }
                                ),
                                label: "\(indexKind.compactLabel)\(label)"
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Preview

    private func menuBarPreview(entries: [MenuBarTickerEntry]) -> some View {
        let appearance = model.menuBarTickerSettings.appearance.normalized()

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("当前菜单栏")
                    .font(AppPalette.appFont(.footnote, weight: .medium))
                    .foregroundStyle(AppPalette.muted)
                ToolbarBadge(title: "已选 \(model.menuBarTickerConfiguredItemCount)", tint: AppPalette.info)
                ToolbarBadge(title: "显示 \(entries.count)", tint: entries.isEmpty ? AppPalette.muted : AppPalette.positive)
                if model.menuBarTickerConfiguredItemCount > model.menuBarTickerSettings.maxVisibleItems {
                    ToolbarBadge(title: "轮播中", tint: AppPalette.brand)
                }
                Spacer()
            }

            if entries.isEmpty {
                Text(model.menuBarTickerSettings.isEnabled ? "当前选择项暂时没有可用数据。刷新持仓估值后会自动显示。" : "菜单栏数据展示已关闭。")
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(AppPalette.card, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
            } else {
                menuBarPreviewStrip(entries: entries, appearance: appearance)
            }
        }
        .padding(12)
        .background(AppPalette.cardStrong.opacity(0.62), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                .stroke(AppPalette.line.opacity(0.42), lineWidth: 1)
        )
    }

    private func menuBarPreviewStrip(entries: [MenuBarTickerEntry], appearance: MenuBarTickerAppearance) -> some View {
        let width = appearance.widthMode == .manual ? CGFloat(appearance.manualWidth) : nil
        let spacing = appearance.spacingMode == .manual
            ? CGFloat(appearance.manualSpacing)
            : MenuBarTickerLayoutMetrics.automaticStatusSpacing(for: appearance)

        @ViewBuilder func entryItem(_ entry: MenuBarTickerEntry) -> some View {
            HStack(spacing: 6) {
                Circle()
                    .fill(menuBarToneColor(entry.tone))
                    .frame(width: 6, height: 6)
                Text(entry.compactText)
                    .font(.system(size: CGFloat(appearance.fontSize), weight: appearance.isBold ? .bold : .medium, design: .rounded))
                    .foregroundStyle(appearance.swiftUIColor)
                    .lineLimit(1)
                    .monospacedDigit()
            }
        }

        let content: AnyView
        switch appearance.layoutMode {
        case .horizontal:
            content = AnyView(
                HStack(spacing: spacing) {
                    ForEach(entries) { entryItem($0) }
                }
            )
        case .vertical:
            content = AnyView(
                VStack(alignment: .leading, spacing: spacing) {
                    ForEach(entries) { entryItem($0) }
                }
            )
        }

        return content
            .padding(.horizontal, MenuBarTickerLayoutMetrics.previewHorizontalPadding)
            .padding(.vertical, MenuBarTickerLayoutMetrics.previewVerticalPadding)
            .frame(width: width, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                    .stroke(AppPalette.line.opacity(0.44), lineWidth: 1)
            )
            .clipped()
    }

    // MARK: - Option Groups

    private func menuBarOptionGroup(title: String, subtitle: String, kinds: [MenuBarTickerKind]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(subtitle)
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 174), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(kinds) { kind in
                    menuBarKindToggle(kind)
                }
            }
        }
        .padding(.vertical, 14)
    }

    private func menuBarKindToggle(_ kind: MenuBarTickerKind) -> some View {
        Toggle(isOn: Binding(
            get: { model.isMenuBarTickerKindEnabled(kind) },
            set: { model.setMenuBarTickerKind(kind, isEnabled: $0) }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.label)
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                Text(kind.detail)
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .background(AppPalette.card.opacity(0.72), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                .stroke(AppPalette.line.opacity(0.34), lineWidth: 1)
        )
    }

    // MARK: - Holding Options

    private var menuBarHoldingOptions: some View {
        DisclosureGroup(isExpanded: $isMenuBarHoldingOptionsExpanded) {
            menuBarHoldingOptionsContent
                .padding(.top, 10)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("单个基金 / 股票")
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text("需要精确到单个标的时再展开，避免一次渲染过多配置项。")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer()
                ToolbarBadge(title: "\(model.userPortfolioSnapshot?.rows.count ?? 0) 个标的", tint: AppPalette.info)
                if model.menuBarTickerSettings.selections.contains(where: { $0.holdingValue != nil }) {
                    let holdingCount = model.menuBarTickerSettings.selections.filter { $0.holdingValue != nil }.count
                    ToolbarBadge(title: "已选 \(holdingCount)", tint: AppPalette.positive)
                }
            }
        }
        .disclosureGroupStyle(FullRowDisclosureGroupStyle())
        .padding(.vertical, 14)
    }

    private var menuBarHoldingOptionsContent: some View {
        Group {
            if let snapshot = model.userPortfolioSnapshot, !snapshot.rows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("可为任意持仓选择涨跌、收益、现价或市值；菜单栏最终仍受最多显示项限制。")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                    LazyVStack(spacing: 8) {
                        ForEach(snapshot.rows) { row in
                            menuBarHoldingRow(row)
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Text(model.hasPersonalPortfolio ? "还没有持仓估值结果，刷新后可选择单标的。" : "添加持仓后可选择单标的。")
                        .font(AppPalette.appFont(.subheadline))
                        .foregroundStyle(AppPalette.muted)
                    Spacer()
                    Button {
                        Task { try? await model.refreshUserPortfolio() }
                    } label: {
                        Label("刷新估值", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.appSecondary)
                    .controlSize(.small)
                    .disabled(!model.hasPersonalPortfolio || model.isRefreshingPortfolio)
                }
                .padding(12)
                .background(AppPalette.card.opacity(0.72), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
            }
        }
    }

    private func menuBarHoldingRow(_ row: UserPortfolioValuationRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            menuBarHoldingIdentity(row)
            menuBarHoldingMetricToggles(row)
        }
        .padding(10)
        .background(AppPalette.card.opacity(0.72), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                .stroke(AppPalette.line.opacity(0.34), lineWidth: 1)
        )
    }

    private func menuBarHoldingIdentity(_ row: UserPortfolioValuationRow) -> some View {
        let quote = row.dropdownQuote

        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.fundName)
                        .font(AppPalette.appFont(.subheadline, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                        .help(row.fundName)
                    if let marketLabel = row.holding.marketLabel {
                        ToolbarBadge(title: marketLabel, tint: AppPalette.info)
                    }
                }
                Text(row.holding.normalizedFundCode)
                    .font(AppPalette.appFont(.footnote, design: .monospaced))
                    .foregroundStyle(AppPalette.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(quote.price.map(decimalText) ?? "—")
                    .font(AppPalette.appFont(.subheadline, weight: .bold, design: .rounded))
                    .foregroundStyle(AppPalette.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                Text(quote.label)
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
            }
            .frame(minWidth: 88, alignment: .trailing)
        }
    }

    private func menuBarHoldingMetricToggles(_ row: UserPortfolioValuationRow) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 8)], alignment: .leading, spacing: 8) {
            menuBarHoldingMetricToggle(row, .dailyAmount)
            menuBarHoldingMetricToggle(row, .dailyPct)
            menuBarHoldingMetricToggle(row, .profitAmount)
            menuBarHoldingMetricToggle(row, .profitPct)
            menuBarHoldingMetricToggle(row, .price)
            menuBarHoldingMetricToggle(row, .marketValue)
        }
    }

    private func menuBarHoldingMetricToggle(_ row: UserPortfolioValuationRow, _ metric: MenuBarHoldingMetric) -> some View {
        menuBarTickerSelectionToggle(
            isOn: Binding(
                get: { model.isMenuBarHoldingMetricEnabled(holdingID: row.holding.id, metric: metric) },
                set: { model.setMenuBarHoldingMetric(holdingID: row.holding.id, metric: metric, isEnabled: $0) }
            ),
            label: metric.label
        )
    }

    // MARK: - Style Row Helpers

    private func menuBarStyleRow<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.info)
                .frame(width: 24, height: 24)
                .background(AppPalette.info.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            Text(title)
                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
                .frame(minWidth: 52, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .frame(height: menuBarStyleRowHeight, alignment: .center)
    }

    private func menuBarStyleStepper(label: String, value: Int, minValue: Int, maxValue: Int, decrement: @escaping () -> Void, increment: @escaping () -> Void) -> some View {
        HStack(spacing: 3) {
            Button(action: decrement) {
                Image(systemName: "minus")
                    .font(AppPalette.appFont(.caption2, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 4).fill(AppPalette.card))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(AppPalette.line, lineWidth: 1))
            }
            .buttonStyle(PressResponsiveButtonStyle())
            .disabled(value <= minValue)
            .accessibilityLabel("减少\(label)")
            .help("减少\(label)")
            Text("\(value)")
                .font(AppPalette.appFont(.footnote, weight: .semibold, design: .rounded))
                .foregroundStyle(AppPalette.ink)
                .frame(width: 22)
            Button(action: increment) {
                Image(systemName: "plus")
                    .font(AppPalette.appFont(.caption2, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 4).fill(AppPalette.card))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(AppPalette.line, lineWidth: 1))
            }
            .buttonStyle(PressResponsiveButtonStyle())
            .disabled(value >= maxValue)
            .accessibilityLabel("增加\(label)")
            .help("增加\(label)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(label)，当前值 \(value)")
    }

    // MARK: - Helpers

    private func menuBarToneColor(_ tone: MenuBarTickerTone) -> Color {
        switch tone {
        case .positive:
            return AppPalette.marketGain
        case .negative:
            return AppPalette.marketLoss
        case .neutral:
            return AppPalette.muted
        }
    }
}
