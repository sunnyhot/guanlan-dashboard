import XCTest
@testable import QiemanDashboard

final class PersonalAssetBrowserPresentationTests: XCTestCase {
    func testPortfolioSectionNoLongerRendersMonthlyReportPanel() throws {
        let source = try String(contentsOf: portfolioSectionSourceURL(), encoding: .utf8)

        XCTAssertFalse(source.contains("MonthlyReportPanel(summary:"))
        XCTAssertFalse(source.contains("didCopyMonthlyReport"))
        XCTAssertFalse(source.contains("private func copyMonthlyReport"))
    }

    func testPortfolioSectionOmitsReminderAndPlanSimulationPanels() throws {
        let source = try String(contentsOf: portfolioSectionSourceURL(), encoding: .utf8)

        XCTAssertFalse(source.contains("PortfolioReminderPanel("))
        XCTAssertFalse(source.contains("PlanSimulationPanel("))
        XCTAssertFalse(source.contains("SectionCard(title: \"提醒通知\""))
        XCTAssertFalse(source.contains("SectionCard(title: \"计划模拟\""))
    }

    func testEmptyPortfolioLeadsDirectlyToFirstHoldingForm() throws {
        let portfolioSource = try String(contentsOf: portfolioSectionSourceURL(), encoding: .utf8)
        let cardSource = try String(contentsOf: personalAssetCardsSourceURL(), encoding: .utf8)

        XCTAssertTrue(portfolioSource.contains("if hasAnyPersonalData"))
        XCTAssertTrue(portfolioSource.contains("PersonalPortfolioEmptyState()"))
        XCTAssertFalse(portfolioSource.contains("还没有可聚合的资产数据"))
        XCTAssertTrue(cardSource.contains("struct PersonalPortfolioEmptyState"))
        XCTAssertTrue(cardSource.contains("Text(\"添加第一笔持仓\")"))
        XCTAssertTrue(cardSource.contains("Label(\"添加第一笔持仓\", systemImage: \"plus\")"))
        XCTAssertTrue(cardSource.contains("isPresentingAddHoldingSheet = true"))
        XCTAssertTrue(cardSource.contains("PersonalAssetAddHoldingSheet()"))
    }

    func testPortfolioSectionFillsWideSummaryAndDiagnosticCards() throws {
        let source = try String(contentsOf: portfolioSectionSourceURL(), encoding: .utf8)

        XCTAssertTrue(source.contains("portfolioSummaryWideColumns"))
        XCTAssertTrue(source.contains("portfolioSummaryMediumColumns"))
        XCTAssertTrue(source.contains("portfolioDiagnosticWideColumns"))
        XCTAssertTrue(source.contains("portfolioDiagnosticMediumColumns"))
        XCTAssertTrue(source.contains("LazyVGrid(columns: portfolioSummaryWideColumns"))
        XCTAssertTrue(source.contains("LazyVGrid(columns: portfolioDiagnosticWideColumns"))
        XCTAssertFalse(source.contains("LazyVGrid(columns: [GridItem(.adaptive(minimum: 220)"))
        XCTAssertFalse(source.contains("LazyVGrid(columns: [GridItem(.adaptive(minimum: 168)"))
    }

    func testPortfolioDiagnosticsHeaderDoesNotRepeatPortfolioAmount() throws {
        let source = try String(contentsOf: portfolioSectionSourceURL(), encoding: .utf8)

        XCTAssertTrue(source.contains("SectionCard(title: \"组合诊断\", subtitle: summary.headline"))
        XCTAssertTrue(source.contains("Text(summary.headline)"))
        XCTAssertFalse(source.contains("ToolbarBadge(title: summary.totalExposureText"))
    }

    func testProfitAttributionUsesTwoDonutChartsAndKeepsDetailsCollapsible() throws {
        let source = try String(contentsOf: portfolioSectionSourceURL(), encoding: .utf8)

        XCTAssertTrue(source.contains("import Charts"))
        XCTAssertTrue(source.contains("@State private var isAttributionDetailExpanded = false"))
        XCTAssertTrue(source.contains("struct ProfitAttributionDonutSlice: Identifiable"))
        XCTAssertTrue(source.contains("struct ProfitAttributionDonutCard: View"))
        XCTAssertTrue(source.contains("title: \"收益贡献\""))
        XCTAssertTrue(source.contains("title: \"收益拖累\""))
        XCTAssertTrue(source.contains("SectorMark("))
        XCTAssertTrue(source.contains("innerRadius: .ratio(0.64)"))
        XCTAssertTrue(source.contains("let primaryEntries = Array(entries.prefix(4))"))
        XCTAssertTrue(source.contains("title: \"其他 \\(remaining.count) 项\""))
        XCTAssertTrue(source.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertFalse(source.contains("ProfitAttributionImpactSpectrum"))
        XCTAssertFalse(source.contains("ProfitAttributionImpactBar"))
        XCTAssertTrue(source.contains("isAttributionDetailExpanded ? \"收起明细\" : \"查看全部明细\""))
        XCTAssertFalse(source.contains("Image(systemName: \"list.bullet.rectangle\")"))
        XCTAssertTrue(source.contains("isAttributionDetailExpanded.toggle()"))
        XCTAssertTrue(source.contains("if isAttributionDetailExpanded"))
        XCTAssertTrue(source.contains("ForEach(summary.entries)"))
        XCTAssertFalse(source.contains("ForEach(summary.entries.prefix(6))"))
        XCTAssertTrue(source.contains(".rotationEffect(.degrees(isAttributionDetailExpanded ? 180 : 0))"))
        XCTAssertTrue(source.contains(".clipped()"))
        XCTAssertTrue(source.contains(".transition(.opacity)"))
        XCTAssertFalse(source.contains(".move(edge: .top)"))
    }

    func testPersonalAssetTableUsesNaturalVerticalHeight() throws {
        let source = try String(contentsOf: personalAssetBrowserSourceURL(), encoding: .utf8)

        XCTAssertFalse(source.contains(".frame(height: tableHeightEstimate)"))
        XCTAssertFalse(source.contains("private var tableHeightEstimate"))
        XCTAssertFalse(source.contains("PersonalAssetTableLayout"))
    }

    func testPersonalAssetToolbarStaysOnOneLineAndScrollsWhenNarrow() throws {
        let source = try String(contentsOf: personalAssetBrowserSourceURL(), encoding: .utf8)

        XCTAssertTrue(source.contains("browserToolbarContent(\n                        counts: presentation.filterCounts,\n                        includesFlexibleSpace: true"))
        XCTAssertTrue(source.contains("browserToolbarContent(\n                            counts: presentation.filterCounts,\n                            includesFlexibleSpace: false"))
        XCTAssertTrue(source.contains("ScrollView(.horizontal, showsIndicators: true)"))
        XCTAssertTrue(source.contains(".scrollIndicators(.visible, axes: .horizontal)"))
        XCTAssertTrue(source.contains(".scrollIndicatorsFlash(onAppear: true)"))
        XCTAssertTrue(source.contains("private func browserToolbarContent("))
        XCTAssertTrue(source.contains(".frame(width: 238)"))
        XCTAssertFalse(source.contains("LazyVGrid(columns: [GridItem(.adaptive(minimum: 92)"))
    }

    func testAddMenuLivesInAssetSectionHeaderWithoutRedundantStatusActions() throws {
        let portfolioSource = try String(contentsOf: portfolioSectionSourceURL(), encoding: .utf8)
        let browserSource = try String(contentsOf: personalAssetBrowserSourceURL(), encoding: .utf8)

        XCTAssertTrue(portfolioSource.contains("SectionCard(title: \"资产全貌总表\""))
        XCTAssertTrue(portfolioSource.contains("PersonalAssetAddButtons()"))
        XCTAssertFalse(portfolioSource.contains("Text(\"已录入\")"))
        XCTAssertFalse(portfolioSource.contains("Button(\"打开设置\")"))
        XCTAssertFalse(browserSource.contains("PersonalAssetAddButtons()"))
    }

    func testDrawdownFilterUsesPlainLanguageLabel() {
        XCTAssertEqual(PersonalAssetFilterScope.drawdownMode.rawValue, "涨跌幅计划")
    }

    func testPersonalAssetTableKeepsHorizontalScrollAvailableOnSmallScreens() throws {
        let source = try String(contentsOf: personalAssetBrowserSourceURL(), encoding: .utf8)

        XCTAssertEqual(PersonalAssetTable.compactThreshold, 1_304)
        XCTAssertTrue(source.contains("ScrollView(.horizontal, showsIndicators: true)"))
        XCTAssertTrue(source.contains(".scrollIndicators(.visible, axes: .horizontal)"))
        XCTAssertTrue(source.contains(".scrollIndicatorsFlash(onAppear: true)"))
        XCTAssertTrue(source.contains(".frame(minWidth: measuredWidth, alignment: .leading)"))
        XCTAssertFalse(source.contains("if isCompact {\n                ScrollView(.horizontal"))
    }

    func testPersonalAssetTableFillsWideWindows() throws {
        let browserSource = try String(contentsOf: personalAssetBrowserSourceURL(), encoding: .utf8)
        let rowSource = try String(contentsOf: personalAssetTableRowSourceURL(), encoding: .utf8)

        XCTAssertTrue(browserSource.contains("updateAvailableWidth(geometry.size.width)"))
        XCTAssertFalse(browserSource.contains("widthProbe"))
        XCTAssertFalse(browserSource.contains("PersonalAssetTableWidthPreferenceKey"))
        XCTAssertTrue(browserSource.contains("PersonalAssetTableColumnLayout.resolve("))
        XCTAssertTrue(browserSource.contains("AssetTableContainerFillModifier(isCompact: isCompact, tableWidth: layout.tableWidth)"))
        XCTAssertTrue(browserSource.contains("AssetTableLabelColumnModifier(isCompact: isCompact, minWidth: layout.labelWidth)"))
        XCTAssertTrue(browserSource.contains("labelWidth: layout.labelWidth"))
        XCTAssertFalse(browserSource.contains(".frame(width: layout.tableWidth, alignment: .leading)"))
        XCTAssertTrue(rowSource.contains("var labelWidth: CGFloat = 260"))
        XCTAssertTrue(rowSource.contains(".frame(width: labelWidth, alignment: .leading)"))
        XCTAssertTrue(rowSource.contains("AssetTableLabelColumnModifier(isCompact: isCompact, minWidth: labelWidth)"))
        XCTAssertTrue(rowSource.contains(".frame(maxWidth: .infinity, alignment: .leading)\n        .overlay(alignment: .leading)"))

        // compact 横向滚动保持固定宽度，常规宽度必须撑满容器避免右侧空白
        XCTAssertTrue(browserSource.contains("struct AssetTableContainerFillModifier"))
        XCTAssertTrue(browserSource.contains("content.frame(width: tableWidth, alignment: .leading)"))
        XCTAssertTrue(browserSource.contains("content.frame(maxWidth: .infinity, alignment: .leading)"))
    }

    func testPersonalAssetTableLayoutExpandsIntoWideContainer() {
        let layout = PersonalAssetTableColumnLayout.resolve(
            availableWidth: 1_720,
            fixedColumnsWidth: 1_044,
            minimumLabelWidth: 260
        )

        XCTAssertEqual(layout.tableWidth, 1_720)
        XCTAssertEqual(layout.labelWidth, 676)
    }

    func testPersonalAssetTableLayoutKeepsMinimumWidthForNarrowContainer() {
        let layout = PersonalAssetTableColumnLayout.resolve(
            availableWidth: 900,
            fixedColumnsWidth: 1_044,
            minimumLabelWidth: 260
        )

        XCTAssertEqual(layout.tableWidth, 1_304)
        XCTAssertEqual(layout.labelWidth, 260)
    }

    func testCompactAssetRowMovesUnitsIntoPriceColumn() throws {
        let browserSource = try String(contentsOf: personalAssetBrowserSourceURL(), encoding: .utf8)
        let rowSource = try String(contentsOf: personalAssetTableRowSourceURL(), encoding: .utf8)

        XCTAssertTrue(browserSource.contains("Text(isCompact ? \"价格/份额\" : \"现价 / 成本\")"))
        XCTAssertTrue(rowSource.contains("Text(\"份额 \\(unitsColumnValue)\")"))
        XCTAssertFalse(rowSource.contains("Text(\"\\(unitsColumnValue) 份\")"))
        XCTAssertFalse(rowSource.contains("// In compact mode, show shares inline under the name"))
    }

    func testAssetDetailUsesAIOpinionCopyAndKeepsConditionsVisible() throws {
        let source = try String(contentsOf: personalAssetDetailSourceURL(), encoding: .utf8)

        XCTAssertTrue(source.contains("detailSection(title: \"AI 观点\", icon: \"sparkles\")"))
        XCTAssertTrue(source.contains("trendDecisionHeader(summary)"))
        XCTAssertTrue(source.contains("trendActionBlock(summary.tradePlan)"))
        XCTAssertTrue(source.contains("trendEvidenceBlock(summary)"))
        XCTAssertTrue(source.contains("trendEvidenceTitle(summary)"))
        XCTAssertTrue(source.contains("trendEvidenceDetails(summary)"))
        XCTAssertTrue(source.contains("let accent = tone.detailAccentColor"))
        XCTAssertTrue(source.contains("let accent = plan.tone.detailAccentColor"))
        XCTAssertTrue(source.contains("var detailAccentColor: Color"))
        XCTAssertTrue(source.contains("self == .muted ? AppPalette.info : color"))
        XCTAssertTrue(source.contains("Text(trendEvidenceTitle(summary))\n                .font(.system(size: 10))"))
        XCTAssertTrue(source.contains(".lineSpacing(1)"))
        XCTAssertFalse(source.contains("Text(trendEvidenceTitle(summary))\n                .font(.system(size: 11, weight: .semibold))"))
        XCTAssertFalse(source.contains("private func trendHorizonRow"))
        let equalHeightFrame = ".frame(maxWidth: .infinity, minHeight: 174, maxHeight: .infinity, alignment: .topLeading)"
        XCTAssertEqual(source.components(separatedBy: equalHeightFrame).count - 1, 2)
        XCTAssertTrue(source.contains("trendInvalidationBlock(invalidationConditions)"))
        XCTAssertTrue(source.contains("title: \"执行前确认\""))
        XCTAssertTrue(source.contains("Text(\"什么情况下改变判断\")"))
        XCTAssertTrue(source.contains("summary.tradePlan.invalidatingConditions + summary.counterSignals"))
        XCTAssertTrue(source.contains("Text(\"数据截至 \\(summary.dataAsOf)\""))
        XCTAssertFalse(source.contains("Text(\"核心依据\")"))
        XCTAssertFalse(source.contains("ForEach(summary.tags)"))
        XCTAssertFalse(source.contains("trendListBlock(title: \"反证条件\""))
    }

    func testAssetDetailShowsInteractivePriceTrendBeforeSupportingSections() throws {
        let detailSource = try String(contentsOf: personalAssetDetailSourceURL(), encoding: .utf8)
        let chartSource = try String(contentsOf: personalAssetTrendChartSourceURL(), encoding: .utf8)

        XCTAssertTrue(detailSource.contains("PersonalAssetPriceTrendChart(row: row)"))
        XCTAssertTrue(chartSource.contains("import Charts"))
        XCTAssertTrue(chartSource.contains("Picker(\"走势区间\""))
        XCTAssertTrue(chartSource.contains("private var compactToolbar"))
        XCTAssertTrue(chartSource.contains("private var inlineSummary"))
        XCTAssertTrue(chartSource.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(chartSource.contains(".frame(width: 192)"))
        XCTAssertFalse(chartSource.contains("private var summaryStrip"))
        XCTAssertFalse(chartSource.contains("按已确认的单位净值展示"))
        XCTAssertTrue(chartSource.contains(".onContinuousHover"))
        XCTAssertTrue(chartSource.contains("Label(\"虚线：持仓成本\""))
        XCTAssertTrue(chartSource.contains("model.platformClient.fetchPersonalAssetPriceHistory"))
    }

    func testAssetDetailMergesPriceFactsIntoTopMetrics() throws {
        let source = try String(contentsOf: personalAssetDetailSourceURL(), encoding: .utf8)

        XCTAssertTrue(source.contains("detailMetricStrip(summary.metrics)"))
        XCTAssertTrue(source.contains("private func detailMetricStrip"))
        XCTAssertTrue(source.contains("HStack(alignment: .top, spacing: 0)"))
        XCTAssertTrue(source.contains(".frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)"))
        XCTAssertFalse(source.contains("metricColumns"))
        XCTAssertFalse(source.contains("detailMetricCard"))
        XCTAssertTrue(source.contains("\"总持仓 · \\(unitsText($0)) 份\""))
        XCTAssertTrue(source.contains("HStack(alignment: .top, spacing: 10)"))
        XCTAssertTrue(source.contains(".padding(.vertical, 14)"))
        XCTAssertFalse(source.contains("detailSection(title: \"价格与收益\""))
        XCTAssertFalse(source.contains("private var priceSection"))
    }

    func testTableRowKeepsOnlyNonRedundantAssetAndTrendMetadata() throws {
        let source = try String(contentsOf: personalAssetTableRowSourceURL(), encoding: .utf8)

        XCTAssertTrue(source.contains("if let trendSummary"))
        XCTAssertTrue(source.contains("trendSignalBlock(trendSummary)"))
        XCTAssertTrue(source.contains("summary.tradePlan.label"))
        XCTAssertTrue(source.contains("summary.primaryConfidence.label"))
        XCTAssertTrue(source.contains("Text(summary.tradePlan.method)"))
        XCTAssertTrue(source.contains("Text(\"·\")"))
        XCTAssertTrue(source.contains("Text(\"\\(summary.counterSignals.count) 条反证\")"))
        XCTAssertFalse(source.contains("private func trendTagChip"))
        XCTAssertTrue(source.contains("if row.assetType == .stock, let stockMarketLabel = row.detectedMarket?.displayName"))
        XCTAssertTrue(source.contains("ToolbarBadge(title: stockMarketLabel"))
        XCTAssertFalse(source.contains("rawHolding?.marketLabel"))
        XCTAssertFalse(source.contains("ToolbarBadge(title: row.combinedStatusText"))
        XCTAssertFalse(source.contains("Spacer(minLength: 4)\n                if !summary.counterSignals.isEmpty"))
        XCTAssertTrue(source.contains("ToolbarBadge(title: \"待确认\""))
        XCTAssertTrue(source.contains("ToolbarBadge(title: \"计划中\""))
    }

    func testPresentationBuildsCountsAndVisibleRowsFromScopeSearchAndSort() {
        let rows = [
            row(key: "wide", name: "沪深300", code: "000300", marketValue: 30_000, pendingAmount: 0),
            row(key: "dividend", name: "红利低波", code: "000922", marketValue: 10_000, pendingAmount: 500),
            row(key: "pending", name: "等待确认", code: "000001", marketValue: nil, pendingAmount: 800)
        ]

        let presentation = PersonalAssetBrowserPresentationModel.make(
            rows: rows,
            keyword: "000",
            filterScope: .pending,
            sortOption: .pendingAmount,
            comparisonSelection: ["pending", "wide"],
            comparisonMaxCount: 4
        )

        XCTAssertEqual(presentation.filterCounts[.all], 3)
        XCTAssertEqual(presentation.filterCounts[.holding], 2)
        XCTAssertEqual(presentation.filterCounts[.pending], 2)
        XCTAssertEqual(presentation.visibleRows.map(\.id), ["pending", "dividend"])
        XCTAssertEqual(presentation.comparisonSummary.items.map(\.id), ["pending", "wide"])
    }

    func testPresentationPrunesInvalidComparisonSelection() {
        let rows = [
            row(key: "wide", name: "沪深300", code: "000300", marketValue: 30_000, pendingAmount: 0)
        ]

        let presentation = PersonalAssetBrowserPresentationModel.make(
            rows: rows,
            keyword: "",
            filterScope: .all,
            sortOption: .name,
            comparisonSelection: ["missing", "wide"],
            comparisonMaxCount: 4
        )

        XCTAssertEqual(presentation.validComparisonSelection, ["wide"])
        XCTAssertEqual(presentation.comparisonSummary.items.map(\.id), ["wide"])
    }

    private func portfolioSectionSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Views/PortfolioSectionView.swift")
    }

    private func personalAssetBrowserSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Views/PersonalAssetBrowser.swift")
    }

    private func personalAssetCardsSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Views/PersonalAssetCards.swift")
    }

    private func personalAssetDetailSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Views/PersonalAsset/PersonalAssetDetailSheet.swift")
    }

    private func personalAssetTrendChartSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Views/PersonalAsset/PersonalAssetPriceTrendChart.swift")
    }

    private func personalAssetTableRowSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Views/PersonalAsset/PersonalAssetTableRow.swift")
    }

    private func row(
        key: String,
        name: String,
        code: String,
        marketValue: Double?,
        pendingAmount: Double
    ) -> PersonalAssetAggregateRow {
        let holding = marketValue.map { _ in
            UserPortfolioHolding(fundCode: code, assetType: .fund, units: 10_000, costPrice: 1, displayName: name)
        }
        let valuationRow = holding.map {
            UserPortfolioValuationRow(
                holding: $0,
                fundName: name,
                currentPrice: nil,
                priceTime: nil,
                priceSource: nil,
                officialNav: nil,
                officialNavDate: nil,
                estimatePrice: nil,
                estimatePriceTime: nil,
                marketValue: marketValue,
                costValue: nil,
                profitAmount: nil,
                profitPct: nil,
                estimateChangePct: nil
            )
        }
        let pendingTrades = pendingAmount > 0
            ? [
                PersonalPendingTrade(
                    occurredAt: "2026-06-05",
                    actionLabel: "买入",
                    fundName: name,
                    fundCode: code,
                    amountText: "\(pendingAmount)",
                    amountValue: pendingAmount,
                    status: "待确认"
                )
            ]
            : []
        return PersonalAssetAggregateRow(
            key: key,
            assetType: .fund,
            fundName: name,
            fundCode: code,
            holdingRow: valuationRow,
            rawHolding: holding,
            archivedHolding: nil,
            pendingTrades: pendingTrades,
            plans: []
        )
    }
}
