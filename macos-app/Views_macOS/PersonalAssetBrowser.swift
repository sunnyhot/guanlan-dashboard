import SwiftUI

private struct PersonalAssetGroupStats {
    let latestTime: String?
    let totalMarketValue: Double
}

struct PersonalAssetBrowser: View {
    let rows: [PersonalAssetAggregateRow]
    var trendReport: TrendAnalysisReport?

    private let comparisonMaxCount = 4

    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var filterScope: PersonalAssetFilterScope = .all
    @State private var sortOption: PersonalAssetSortOption = .defaultOption
    @State private var comparisonSelection: [String] = []
    @State private var selectedDetailRow: PersonalAssetAggregateRow?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let presentation: PersonalAssetBrowserPresentationModel = {
            let telemetryStart = PerformanceTelemetry.start()
            let presentation = PersonalAssetBrowserPresentationModel.make(
                rows: rows,
                keyword: debouncedSearchText,
                filterScope: filterScope,
                sortOption: sortOption,
                comparisonSelection: comparisonSelection,
                comparisonMaxCount: comparisonMaxCount
            )
            PerformanceTelemetry.record(
                "personalAsset.presentation",
                startedAt: telemetryStart,
                metadata: [
                    "rowCount": "\(rows.count)",
                    "visibleCount": "\(presentation.visibleRows.count)",
                    "filter": filterScope.rawValue,
                    "sort": sortOption.rawValue,
                    "hasKeyword": "\(!debouncedSearchText.isEmpty)"
                ]
            )
            return presentation
        }()
        let trendTagIndex = TrendAssetTagIndex(report: trendReport)
        let allowsInteraction = selectedDetailRow == nil

        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    browserToolbarContent(
                        counts: presentation.filterCounts,
                        includesFlexibleSpace: true
                    )
                }

                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 8) {
                        browserToolbarContent(
                            counts: presentation.filterCounts,
                            includesFlexibleSpace: false
                        )
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.visible, axes: .horizontal)
                .scrollIndicatorsFlash(onAppear: true)
            }

            if !presentation.comparisonSummary.items.isEmpty {
                PersonalAssetComparisonPanel(
                    summary: presentation.comparisonSummary,
                    onRemove: removeComparisonItem,
                    onClear: clearComparisonSelection
                )
            }

            if presentation.visibleRows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("当前筛选下没有标的。")
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text("可以试试切换筛选条件，或者清空搜索词。")
                        .font(AppPalette.appFont(.subheadline))
                        .foregroundStyle(AppPalette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
            } else {
                PersonalAssetGroupedTable(
                    rows: presentation.visibleRows,
                    trendTagIndex: trendTagIndex,
                    comparisonSelection: comparisonSelection,
                    comparisonMaxCount: comparisonMaxCount,
                    allowsHoverFeedback: allowsInteraction,
                    onToggleComparison: toggleComparison
                ) { row in
                    selectedDetailRow = row
                }
            }
        }
        .allowsHitTesting(allowsInteraction)
        .sheet(item: $selectedDetailRow) { row in
            PersonalAssetDetailSheet(row: row, trendSummary: trendTagIndex.summary(for: row))
        }
        .task(id: searchText) {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            debouncedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        .onChange(of: presentation.validComparisonSelection) { _, validSelection in
            comparisonSelection = validSelection
        }
        .onReceive(NotificationCenter.default.publisher(for: .qiemanFocusSearch)) { _ in
            isSearchFocused = true
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func browserToolbarContent(
        counts: [PersonalAssetFilterScope: Int],
        includesFlexibleSpace: Bool
    ) -> some View {
        browserSearchField

        Divider()
            .frame(height: 22)
            .overlay(AppPalette.line.opacity(0.38))
            .padding(.horizontal, 2)

        ForEach(PersonalAssetFilterScope.allCases) { scope in
            filterChip(scope: scope, counts: counts)
        }

        if includesFlexibleSpace {
            Spacer(minLength: 12)
        }

        Divider()
            .frame(height: 22)
            .overlay(AppPalette.line.opacity(0.38))
            .padding(.horizontal, 2)

        browserSortMenu
    }

    private var browserSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(AppPalette.appFont(.footnote, weight: .medium))
                .foregroundStyle(AppPalette.muted)
            TextField("搜索名称或代码", text: $searchText)
                .textFieldStyle(.plain)
                .font(AppPalette.appFont(.subheadline))
                .focused($isSearchFocused)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                .stroke(
                    isSearchFocused ? AppPalette.brand.opacity(0.72) : AppPalette.line.opacity(0.56),
                    lineWidth: 1
                )
        )
        .frame(width: 238)
        .animation(.easeOut(duration: 0.14), value: isSearchFocused)
    }

    private var browserSortMenu: some View {
        Menu {
            ForEach(PersonalAssetSortOption.allCases) { option in
                Button {
                    sortOption = option
                } label: {
                    HStack {
                        Text(option.rawValue)
                        if sortOption == option {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Label("排序 \(sortOption.rawValue)", systemImage: "arrow.up.arrow.down")
                .font(AppPalette.appFont(.footnote, weight: .semibold))
                .foregroundStyle(AppPalette.info)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                        .stroke(AppPalette.info.opacity(0.18), lineWidth: 1)
                )
        }
        .menuStyle(.borderlessButton)
    }

    private func filterChip(scope: PersonalAssetFilterScope, counts: [PersonalAssetFilterScope: Int]) -> some View {
        let isSelected = filterScope == scope
        let count = counts[scope, default: 0]
        return Button {
            withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.9)) {
                filterScope = scope
            }
        } label: {
            HStack(spacing: 5) {
                Text(scope.rawValue)
                Text("\(count)")
                    .font(AppPalette.appFont(.caption, weight: .bold, design: .rounded))
                    .foregroundStyle(isSelected ? AppPalette.onBrand.opacity(0.88) : AppPalette.muted)
            }
                .font(AppPalette.appFont(.footnote, weight: .semibold))
                .foregroundStyle(isSelected ? AppPalette.onBrand : AppPalette.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .interactiveSurface(
                    isSelected: isSelected,
                    tint: AppPalette.brand,
                    radius: AppPalette.controlRadius,
                    fill: AppPalette.cardStrong,
                    hoverFill: AppPalette.cardHover,
                    selectedFill: AppPalette.brand,
                    strokeOpacity: 0.42,
                    activeStrokeOpacity: 0.44,
                    lift: 0.6
                )
        }
        .buttonStyle(PressResponsiveButtonStyle())
        .contentShape(RoundedRectangle(cornerRadius: AppPalette.controlRadius))
    }

    private func toggleComparison(_ row: PersonalAssetAggregateRow) {
        withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.9)) {
            if let index = comparisonSelection.firstIndex(of: row.id) {
                comparisonSelection.remove(at: index)
            } else if comparisonSelection.count < comparisonMaxCount {
                comparisonSelection.append(row.id)
            }
        }
    }

    private func removeComparisonItem(_ id: String) {
        withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.9)) {
            comparisonSelection.removeAll { $0 == id }
        }
    }

    private func clearComparisonSelection() {
        withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.9)) {
            comparisonSelection.removeAll()
        }
    }
}

struct PersonalAssetComparisonPanel: View {
    let summary: PersonalAssetComparisonSummary
    let onRemove: (String) -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "rectangle.split.3x1")
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(AppPalette.brand)
                    .accentIconStyle(tint: AppPalette.brand, size: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text("基金对比")
                        .font(AppPalette.appFont(.headline, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text(summary.detail)
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                ToolbarBadge(title: summary.headline, tint: summary.items.count >= 2 ? AppPalette.brand : AppPalette.info)

                Button(action: onClear) {
                    Image(systemName: "xmark.circle")
                        .font(AppPalette.appFont(.headline, weight: .semibold))
                        .foregroundStyle(AppPalette.muted)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(PressResponsiveButtonStyle())
                .help("清空对比")
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 184), spacing: 10)], spacing: 10) {
                ForEach(summary.items) { item in
                    PersonalAssetComparisonCard(item: item) {
                        onRemove(item.id)
                    }
                }
            }
        }
        .padding(12)
        .background(AppPalette.cardStrong.opacity(0.68), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                .stroke(AppPalette.brand.opacity(0.18), lineWidth: 1)
        )
    }
}

struct PersonalAssetComparisonCard: View {
    let item: PersonalAssetComparisonItem
    let onRemove: () -> Void

    private var profitTint: Color {
        AppPalette.marketTint(for: item.profitValue)
    }

    private var dailyTint: Color {
        AppPalette.marketTint(for: item.dailyChangeValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(AppPalette.appFont(.body, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                    HStack(spacing: 6) {
                        ToolbarBadge(title: item.codeText, tint: AppPalette.info)
                        ToolbarBadge(title: item.statusText, tint: AppPalette.brand)
                    }
                }

                Spacer(minLength: 0)

                Button(action: onRemove) {
                    Image(systemName: "minus.circle")
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(AppPalette.muted)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(PressResponsiveButtonStyle())
                .help("移出对比")
                .accessibilityLabel("将 \(item.title) 移出对比")
            }

            VStack(spacing: 7) {
                comparisonMetric(title: "综合占用", value: item.exposureText, tint: AppPalette.ink)
                comparisonMetric(title: "实时市值", value: item.marketValueText, tint: AppPalette.ink)
                comparisonMetric(title: "总收益", value: "\(item.profitText) · \(item.profitRateText)", tint: profitTint)
                comparisonMetric(title: "今日涨跌", value: "\(item.dailyChangeText) · \(item.dailyChangeRateText)", tint: dailyTint)
                comparisonMetric(title: "待确认", value: item.pendingText, tint: AppPalette.warning)
                comparisonMetric(title: "计划档案", value: item.planText, tint: AppPalette.info)
            }

            FlowLayout(spacing: 6) {
                if item.isLargestExposure {
                    SnapshotMiniBadge(text: "市值最大", tint: AppPalette.brand)
                }
                if item.isBestProfitRate {
                    SnapshotMiniBadge(text: "收益率最高", tint: AppPalette.marketGain)
                }
                if item.isLargestDailyMover {
                    SnapshotMiniBadge(text: "波动最大", tint: AppPalette.warning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 212, alignment: .topLeading)
        .padding(12)
        .staticSurface(
            tint: AppPalette.brand,
            fill: AppPalette.card.opacity(0.86),
            strokeOpacity: 0.36,
            activeStrokeOpacity: 0.48
        )
    }

    private func comparisonMetric(title: String, value: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(AppPalette.appFont(.caption, weight: .medium))
                .foregroundStyle(AppPalette.muted)
                .frame(width: 48, alignment: .leading)
            Text(value)
                .font(AppPalette.appFont(.footnote, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Spacer(minLength: 0)
        }
    }
}

struct PersonalAssetGroupedTable: View {
    let offExchangeFundRows: [PersonalAssetAggregateRow]
    private let offExchangeFundStats: PersonalAssetGroupStats
    let onExchangeFundRows: [PersonalAssetAggregateRow]
    private let onExchangeFundStats: PersonalAssetGroupStats
    let stockRows: [PersonalAssetAggregateRow]
    private let stockStats: PersonalAssetGroupStats
    let trendTagIndex: TrendAssetTagIndex
    let comparisonSelection: [String]
    let comparisonMaxCount: Int
    let allowsHoverFeedback: Bool
    let onToggleComparison: (PersonalAssetAggregateRow) -> Void
    let onOpenDetail: (PersonalAssetAggregateRow) -> Void

    init(
        rows: [PersonalAssetAggregateRow],
        trendTagIndex: TrendAssetTagIndex = TrendAssetTagIndex(report: nil),
        comparisonSelection: [String] = [],
        comparisonMaxCount: Int = 4,
        allowsHoverFeedback: Bool = true,
        onToggleComparison: @escaping (PersonalAssetAggregateRow) -> Void = { _ in },
        onOpenDetail: @escaping (PersonalAssetAggregateRow) -> Void = { _ in }
    ) {
        var offExchangeFundRows: [PersonalAssetAggregateRow] = []
        var onExchangeFundRows: [PersonalAssetAggregateRow] = []
        var stockRows: [PersonalAssetAggregateRow] = []

        for row in rows {
            if row.assetType == .stock {
                stockRows.append(row)
            } else if row.isOnExchangeFund {
                onExchangeFundRows.append(row)
            } else if row.assetType == .fund {
                offExchangeFundRows.append(row)
            }
        }

        self.offExchangeFundRows = offExchangeFundRows
        self.offExchangeFundStats = Self.groupStats(rows: offExchangeFundRows)
        self.onExchangeFundRows = onExchangeFundRows
        self.onExchangeFundStats = Self.groupStats(rows: onExchangeFundRows)
        self.stockRows = stockRows
        self.stockStats = Self.groupStats(rows: stockRows)
        self.trendTagIndex = trendTagIndex
        self.comparisonSelection = comparisonSelection
        self.comparisonMaxCount = comparisonMaxCount
        self.allowsHoverFeedback = allowsHoverFeedback
        self.onToggleComparison = onToggleComparison
        self.onOpenDetail = onOpenDetail
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            if !offExchangeFundRows.isEmpty {
                group(title: "场外基金", rows: offExchangeFundRows, stats: offExchangeFundStats, tint: AppPalette.brand, usesMarketTradeColumns: false)
            }
            if !onExchangeFundRows.isEmpty {
                group(title: "场内基金", rows: onExchangeFundRows, stats: onExchangeFundStats, tint: AppPalette.accentWarm, usesMarketTradeColumns: true)
            }
            if !stockRows.isEmpty {
                group(title: "股票", rows: stockRows, stats: stockStats, tint: AppPalette.info, usesMarketTradeColumns: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func group(title: String, rows: [PersonalAssetAggregateRow], stats: PersonalAssetGroupStats, tint: Color, usesMarketTradeColumns: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // ── Group header bar with colored accent ──
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: AppPalette.swatchRadius)
                    .fill(tint)
                    .frame(width: 3, height: 18)

                Text(title)
                    .font(AppPalette.appFont(.headline, weight: .bold))
                    .foregroundStyle(tint)

                ToolbarBadge(title: "\(rows.count) 只", tint: tint)

                Spacer()

                Text("市值 \(currencyText(stats.totalMarketValue))")
                    .font(AppPalette.appFont(.subheadline, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppPalette.muted)

                if let time = stats.latestTime {
                    Text("估值 \(time)")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted.opacity(0.7))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(tint.opacity(0.06))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(tint.opacity(0.18))
                    .frame(height: 1)
            }

            PersonalAssetTable(
                rows: rows,
                usesMarketTradeColumns: usesMarketTradeColumns,
                trendTagIndex: trendTagIndex,
                comparisonSelection: comparisonSelection,
                comparisonMaxCount: comparisonMaxCount,
                allowsHoverFeedback: allowsHoverFeedback,
                onToggleComparison: onToggleComparison,
                onOpenDetail: onOpenDetail
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func groupStats(rows: [PersonalAssetAggregateRow]) -> PersonalAssetGroupStats {
        var latestTime: String?
        var totalMarketValue = 0.0

        for row in rows {
            totalMarketValue += row.marketValue ?? 0
            if let time = row.holdingRow?.resolvedPriceTime,
               latestTime.map({ time > $0 }) ?? true {
                latestTime = time
            }
        }

        return PersonalAssetGroupStats(latestTime: latestTime, totalMarketValue: totalMarketValue)
    }
}

struct PersonalAssetTableColumnLayout: Equatable {
    let tableWidth: CGFloat
    let labelWidth: CGFloat

    static func resolve(
        availableWidth: CGFloat,
        fixedColumnsWidth: CGFloat,
        minimumLabelWidth: CGFloat
    ) -> PersonalAssetTableColumnLayout {
        let minimumTableWidth = fixedColumnsWidth + minimumLabelWidth
        let tableWidth = max(availableWidth, minimumTableWidth)
        return PersonalAssetTableColumnLayout(
            tableWidth: tableWidth,
            labelWidth: max(minimumLabelWidth, tableWidth - fixedColumnsWidth)
        )
    }
}

struct PersonalAssetTable: View {
    let rows: [PersonalAssetAggregateRow]
    let usesMarketTradeColumns: Bool
    let trendTagIndex: TrendAssetTagIndex
    let comparisonSelection: [String]
    let comparisonMaxCount: Int
    let allowsHoverFeedback: Bool
    let onToggleComparison: (PersonalAssetAggregateRow) -> Void
    let onOpenDetail: (PersonalAssetAggregateRow) -> Void

    @State private var availableWidth: CGFloat = Self.compactThreshold

    /// 完整列布局的最小宽度；低于此宽度时切换紧凑列，并允许横向滚动。
    static let compactThreshold: CGFloat = 1_304

    init(
        rows: [PersonalAssetAggregateRow],
        usesMarketTradeColumns: Bool = false,
        trendTagIndex: TrendAssetTagIndex = TrendAssetTagIndex(report: nil),
        comparisonSelection: [String] = [],
        comparisonMaxCount: Int = 4,
        allowsHoverFeedback: Bool = true,
        onToggleComparison: @escaping (PersonalAssetAggregateRow) -> Void = { _ in },
        onOpenDetail: @escaping (PersonalAssetAggregateRow) -> Void = { _ in }
    ) {
        self.rows = rows
        self.usesMarketTradeColumns = usesMarketTradeColumns
        self.trendTagIndex = trendTagIndex
        self.comparisonSelection = comparisonSelection
        self.comparisonMaxCount = comparisonMaxCount
        self.allowsHoverFeedback = allowsHoverFeedback
        self.onToggleComparison = onToggleComparison
        self.onOpenDetail = onOpenDetail
    }

    var body: some View {
        let measuredWidth = max(availableWidth, 1)
        let isCompact = measuredWidth < Self.compactThreshold

        ScrollView(.horizontal, showsIndicators: true) {
            tableContent(availableWidth: measuredWidth, isCompact: isCompact)
                .frame(minWidth: measuredWidth, alignment: .leading)
        }
        .scrollIndicators(.visible, axes: .horizontal)
        .scrollIndicatorsFlash(onAppear: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        updateAvailableWidth(geometry.size.width)
                    }
                    .onChange(of: geometry.size.width) { _, width in
                        updateAvailableWidth(width)
                    }
            }
        }
    }

    private func updateAvailableWidth(_ width: CGFloat) {
        guard width > 0, abs(width - availableWidth) > 0.5 else { return }
        availableWidth = width
    }

    // MARK: - Column widths adapt to available space

    private func valuationColWidth(isCompact: Bool) -> CGFloat {
        isCompact ? 200 : 260
    }

    private func unitsColWidth(isCompact: Bool) -> CGFloat {
        isCompact ? 80 : 100
    }

    private func priceColWidth(isCompact: Bool) -> CGFloat {
        isCompact ? 100 : 120
    }

    private func fifthColWidth(isCompact: Bool) -> CGFloat {
        isCompact ? 110 : 150
    }

    private func sixthColWidth(isCompact: Bool) -> CGFloat {
        isCompact ? 130 : 190
    }

    private func actionColWidth(isCompact: Bool) -> CGFloat {
        isCompact ? 118 : 128
    }

    @ViewBuilder
    private func tableContent(availableWidth: CGFloat, isCompact: Bool) -> some View {
        let colSpacing: CGFloat = isCompact ? 8 : 12
        let visibleColumnCount = isCompact ? 6 : 7
        let labelColMinWidth: CGFloat = isCompact ? 160 : 260
        let fixedColumnsWidth = valuationColWidth(isCompact: isCompact)
            + (isCompact ? 0 : unitsColWidth(isCompact: isCompact))
            + priceColWidth(isCompact: isCompact)
            + fifthColWidth(isCompact: isCompact)
            + sixthColWidth(isCompact: isCompact)
            + actionColWidth(isCompact: isCompact)
            + colSpacing * CGFloat(visibleColumnCount - 1)
            + 24              // horizontal padding (12*2)
        let layout = PersonalAssetTableColumnLayout.resolve(
            availableWidth: availableWidth,
            fixedColumnsWidth: fixedColumnsWidth,
            minimumLabelWidth: labelColMinWidth
        )

        VStack(spacing: 0) {
            HStack(spacing: colSpacing) {
                Text("标的")
                    .modifier(AssetTableLabelColumnModifier(isCompact: isCompact, minWidth: layout.labelWidth))
                Text(isCompact ? "估值/收益" : "实时估值 / 收益")
                    .frame(width: valuationColWidth(isCompact: isCompact), alignment: .leading)
                if !isCompact {
                    Text("持有份额")
                        .frame(width: unitsColWidth(isCompact: isCompact), alignment: .leading)
                }
                Text(isCompact ? "价格/份额" : "现价 / 成本")
                    .frame(width: priceColWidth(isCompact: isCompact), alignment: .leading)
                if usesMarketTradeColumns {
                    Text("涨跌幅")
                        .frame(width: fifthColWidth(isCompact: isCompact), alignment: .leading)
                    Text("涨跌额")
                        .frame(width: sixthColWidth(isCompact: isCompact), alignment: .leading)
                } else {
                    Text("待确认")
                        .frame(width: fifthColWidth(isCompact: isCompact), alignment: .leading)
                    Text("计划档案")
                        .frame(width: sixthColWidth(isCompact: isCompact), alignment: .leading)
                }
                Text("操作")
                    .frame(width: actionColWidth(isCompact: isCompact), alignment: .trailing)
            }
            .modifier(AssetTableContainerFillModifier(isCompact: isCompact, tableWidth: layout.tableWidth))
            .font(AppPalette.appFont(.footnote, weight: .semibold))
            .foregroundStyle(AppPalette.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(AppPalette.line.opacity(0.42))
                    .frame(height: 1)
            }

            LazyVStack(spacing: 8) {
                ForEach(rows) { row in
                    let isSelectedForComparison = comparisonSelection.contains(row.id)
                    PersonalAssetTableRow(
                        row: row,
                        isCompact: isCompact,
                        colSpacing: colSpacing,
                        valuationWidth: valuationColWidth(isCompact: isCompact),
                        unitsWidth: unitsColWidth(isCompact: isCompact),
                        priceWidth: priceColWidth(isCompact: isCompact),
                        fifthWidth: fifthColWidth(isCompact: isCompact),
                        sixthWidth: sixthColWidth(isCompact: isCompact),
                        actionWidth: actionColWidth(isCompact: isCompact),
                        labelWidth: layout.labelWidth,
                        trendSummary: trendTagIndex.summary(for: row),
                        isSelectedForComparison: isSelectedForComparison,
                        isComparisonToggleDisabled: !isSelectedForComparison && comparisonSelection.count >= comparisonMaxCount,
                        allowsHoverFeedback: allowsHoverFeedback,
                        onToggleComparison: {
                            onToggleComparison(row)
                        },
                        onOpenDetail: {
                            onOpenDetail(row)
                        }
                    )
                }
            }
            .padding(.top, 10)
        }
        .modifier(AssetTableContainerFillModifier(isCompact: isCompact, tableWidth: layout.tableWidth))
    }
}

/// 在 compact 模式下保持固定表格宽度以支持横向滚动；
/// 在常规宽度下让表格铺满容器，避免右侧出现空白列。
struct AssetTableContainerFillModifier: ViewModifier {
    let isCompact: Bool
    let tableWidth: CGFloat

    func body(content: Content) -> some View {
        if isCompact {
            content.frame(width: tableWidth, alignment: .leading)
        } else {
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 标的列在 compact 下用固定宽度配合横向滚动；
/// 在常规宽度下吸收剩余空间，避免列表右侧出现空白。
struct AssetTableLabelColumnModifier: ViewModifier {
    let isCompact: Bool
    let minWidth: CGFloat

    func body(content: Content) -> some View {
        if isCompact {
            content.frame(width: minWidth, alignment: .leading)
        } else {
            content
                .frame(minWidth: minWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
