import XCTest
@testable import QiemanDashboard

final class UIExperienceRegressionTests: XCTestCase {
    func testPresentedAssetSheetDisablesBackgroundInteractionAndHover() throws {
        let browser = try source(at: "Views/PersonalAssetBrowser.swift")
        let row = try source(at: "Views/PersonalAsset/PersonalAssetTableRow.swift")
        let components = try source(at: "Views/SharedComponents.swift")

        XCTAssertTrue(browser.contains("let allowsInteraction = selectedDetailRow == nil"))
        XCTAssertTrue(browser.contains(".allowsHitTesting(allowsInteraction)"))
        XCTAssertTrue(browser.contains("allowsHoverFeedback: allowsInteraction"))
        XCTAssertTrue(row.contains("allowsHoverFeedback: allowsHoverFeedback"))
        XCTAssertTrue(components.contains(".onChange(of: allowsHoverFeedback)"))
        XCTAssertTrue(components.contains("isHovering = false"))
    }

    func testSharedInteractionPrimitivesSupportStaticSurfacesDismissibleToastsAndReducedMotion() throws {
        let source = try source(at: "Views/SharedComponents.swift")

        XCTAssertTrue(source.contains("func staticSurface("))
        XCTAssertTrue(source.contains("accessibilityReduceMotion"))
        XCTAssertTrue(source.contains("let onDismiss: (() -> Void)?"))
    }

    func testResponsiveCardHoverDoesNotExpandPastScrollBounds() throws {
        let source = try source(at: "Views/SharedComponents.swift")

        XCTAssertTrue(source.contains("configuration.isPressed ? 0.965 : 1"))
        XCTAssertTrue(source.contains(".brightness(isHovering ? 0.025 : 0)"))
        XCTAssertFalse(source.contains("isHovering ? 1.018"))
    }

    func testVisibleActionsUseTheUnifiedAppButtonSystem() throws {
        let components = try source(at: "Views/SharedComponents.swift")
        let views = try sourceTree(at: "Views")

        XCTAssertTrue(components.contains("enum AppActionButtonKind: Equatable"))
        XCTAssertTrue(components.contains("struct AppActionButtonStyle: ButtonStyle"))
        XCTAssertTrue(components.contains("static var appPrimary"))
        XCTAssertTrue(components.contains("static var appSecondary"))
        XCTAssertTrue(components.contains("static var appText"))
        XCTAssertTrue(components.contains("static var appDanger"))
        XCTAssertTrue(components.contains("static var appIcon"))
        XCTAssertTrue(components.contains("static var appMenuItem"))

        XCTAssertFalse(views.contains(".buttonStyle(.borderedProminent)"))
        XCTAssertFalse(views.contains(".buttonStyle(.bordered)"))
        XCTAssertFalse(views.contains(".buttonStyle(.link)"))
        XCTAssertFalse(views.contains(".buttonStyle(.borderless)"))
    }

    func testPrimaryModuleTabsUseOneSharedVisualSystem() throws {
        let components = try source(at: "Views/SharedComponents.swift")
        let portfolio = try source(at: "Views/PortfolioSectionView.swift")
        let platform = try source(at: "Views/PlatformSectionView.swift")
        let enhancement = try source(at: "Views/EnhancementCenterView.swift")

        XCTAssertTrue(components.contains("struct ModuleTabBar<"))
        XCTAssertTrue(components.contains("private func moduleTabButton"))
        XCTAssertTrue(components.contains("selectedFill: AppPalette.brand"))
        XCTAssertTrue(components.contains("fill: AppPalette.cardStrong"))
        XCTAssertTrue(components.contains("hoverFill: AppPalette.cardHover"))

        XCTAssertTrue(portfolio.contains("ModuleTabBar("))
        XCTAssertTrue(platform.contains("ModuleTabBar("))
        XCTAssertTrue(enhancement.contains("ModuleTabBar("))

        XCTAssertFalse(portfolio.contains(".pickerStyle(.segmented)"))
        XCTAssertFalse(platform.contains("isSelected ? AppPalette.brand : AppPalette.cardStrong"))
        XCTAssertFalse(enhancement.contains("workbenchSegmentButton"))
    }

    func testAssetAddControlUsesACustomPopoverInsteadOfTheSystemMenu() throws {
        let source = try source(at: "Views/PersonalAssetCards.swift")
        let addStart = try XCTUnwrap(source.range(of: "struct PersonalAssetAddButtons"))
        let emptyStateStart = try XCTUnwrap(
            source.range(of: "struct PersonalPortfolioEmptyState", range: addStart.upperBound..<source.endIndex)
        )
        let addControl = String(source[addStart.lowerBound..<emptyStateStart.lowerBound])

        XCTAssertTrue(addControl.contains("@State private var isShowingAddMenu"))
        XCTAssertTrue(addControl.contains(".popover(isPresented: $isShowingAddMenu"))
        XCTAssertTrue(addControl.contains(".buttonStyle(.appPrimary)"))
        XCTAssertTrue(addControl.contains(".buttonStyle(.appMenuItem)"))
        XCTAssertTrue(addControl.contains("Text(\"添加资产记录\")"))
        XCTAssertFalse(addControl.contains("Menu {"))
        XCTAssertFalse(addControl.contains(".menuStyle(.borderlessButton)"))
    }

    func testPersonalAssetPrimaryContentOpensDetailWithoutRequiringIconButton() throws {
        let source = try source(at: "Views/PersonalAsset/PersonalAssetTableRow.swift")

        XCTAssertTrue(source.contains("Button {\n                onOpenDetail?()"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"查看 \\(row.fundName) 详情\")"))

        let fullRowButton = try XCTUnwrap(source.range(of: ".overlay(alignment: .leading)"))
        let hoverSurface = try XCTUnwrap(source.range(of: ".interactiveSurface("))
        XCTAssertLessThan(
            source.distance(from: source.startIndex, to: fullRowButton.lowerBound),
            source.distance(from: source.startIndex, to: hoverSurface.lowerBound),
            "hover surface must wrap the transparent full-row button so it receives pointer events"
        )
        XCTAssertTrue(source.contains("lift: AppPalette.hoverLift"))
        XCTAssertTrue(source.contains(".contentShape(RoundedRectangle(cornerRadius: AppPalette.cardRadius))"))
    }

    func testSettingsControlsHaveSemanticsKeyboardSortingAndSafeResetConfirmation() throws {
        let components = try source(at: "Views/SettingsComponents.swift")
        let menuBar = try source(at: "Views/SettingsMenuBarPanel.swift")

        XCTAssertTrue(components.contains("Toggle(title, isOn: isOn)"))
        XCTAssertTrue(menuBar.contains("isConfirmingMenuBarReset"))
        XCTAssertTrue(menuBar.contains("向前移动"))
        XCTAssertTrue(menuBar.contains("向后移动"))
        XCTAssertFalse(menuBar.contains(".frame(width: 18, height: 18)"))
    }

    @MainActor
    func testAppearanceSelectionBroadcastsNativeWindowRefreshAndUsesAGeneralSettingsLabel() throws {
        let model = AppModel()
        let originalAppearance = model.appearance
        defer { model.appearance = originalAppearance }
        model.appearance = .system

        let notification = expectation(forNotification: .qiemanAppearanceDidChange, object: nil)
        model.appearance = .dark
        wait(for: [notification], timeout: 1)

        XCTAssertEqual(model.appearance, .dark)

        let settings = try source(at: "Views/SettingsSectionView.swift")
        let appSettings = try source(at: "Views/SettingsAppPanel.swift")
        let content = try source(at: "Views/ContentView.swift")
        let menuBar = try source(at: "Views/MenuBarPortfolioView.swift")
        let appModel = try source(at: "Core/AppModel.swift")
        XCTAssertTrue(settings.contains("case general"))
        XCTAssertTrue(settings.contains("return \"通用\""))
        XCTAssertTrue(settings.contains("settingsNavigation"))
        XCTAssertTrue(settings.contains("availableWidth >= 1_120"))
        XCTAssertTrue(settings.contains("case sidebar"))
        XCTAssertFalse(settings.contains("overviewMetrics"))
        XCTAssertFalse(settings.contains("?? \"当前构建\""))
        XCTAssertTrue(appSettings.contains("Picker(\"外观\", selection: $model.appearance)"))
        XCTAssertTrue(appSettings.contains("title: \"开机时启动\""))
        XCTAssertTrue(appSettings.contains("title: \"在 Dock 中显示\""))
        XCTAssertTrue(appSettings.contains("SettingsCardGroup"))
        XCTAssertTrue(content.contains(".preferredColorScheme(model.appearance.colorScheme)"))
        XCTAssertTrue(menuBar.contains(".preferredColorScheme(model.appearance.colorScheme)"))
        XCTAssertTrue(appModel.contains("appDelegate?.syncWindowAppearances()"))
    }

    func testEditorsKeepValidationFeedbackInsideThePresentedSheet() throws {
        let sources = try [
            source(at: "Views/PersonalAsset/PersonalPendingTradeEditSheet.swift"),
            source(at: "Views/PersonalAsset/PersonalInvestmentPlanEditor.swift"),
            source(at: "Views/PersonalAssetCards.swift"),
        ]

        for source in sources {
            XCTAssertTrue(source.contains("inlineErrorMessage"))
        }
    }

    func testHiddenHorizontalOverflowIsNotUsedForPrimaryInformation() throws {
        let content = try source(at: "Views/ContentView.swift")
        let forum = try source(at: "Views/ForumSectionView.swift")

        XCTAssertFalse(content.contains("ScrollView(.horizontal, showsIndicators: false)"))
        XCTAssertFalse(forum.contains("ScrollView(.horizontal, showsIndicators: false)"))
    }

    func testWorkspaceListsUseBoundedScrollViewportsWithoutDrawingPastTheirCards() throws {
        let fixedViewportSources = try [
            source(at: "Views/PlatformSectionView.swift"),
            source(at: "Views/Platform/AlfaPlatformPanel.swift"),
        ]

        for source in fixedViewportSources {
            XCTAssertFalse(source.contains(".fixedSize(horizontal: false, vertical: true)"))
            XCTAssertTrue(source.contains(".frame(height: PlatformWorkspaceLayout.actionListHeight)"))
            XCTAssertTrue(source.contains(".clipped()"))
        }

        let forum = try source(at: "Views/ForumSectionView.swift")
        XCTAssertFalse(forum.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertTrue(forum.contains("availableHeight: proxy.size.height"))
        XCTAssertTrue(forum.contains(".frame(height: PlatformWorkspaceLayout.forumListHeight(for: availableHeight))"))
        XCTAssertTrue(forum.contains(".clipped()"))
    }

    func testAdjustmentWorkspaceKeepsColumnsAlignedAndDetailConcise() throws {
        let platform = try source(at: "Views/PlatformSectionView.swift")
        let detail = try source(at: "Views/Platform/PlatformActionDetailCard.swift")

        XCTAssertTrue(platform.contains("PlatformWorkspaceLayout.adjustmentWorkspaceHeight"))
        XCTAssertTrue(platform.contains("platformDetailPanel(isCompact: false)"))
        XCTAssertTrue(platform.contains("minHeight: isCompact ? nil : PlatformWorkspaceLayout.adjustmentWorkspaceHeight"))
        XCTAssertFalse(platform.contains("Text(action.txnDate ?? action.createdAt ?? \"未知时间\")"))

        XCTAssertFalse(detail.contains("Label(\"调仓概览\""))
        XCTAssertFalse(detail.contains("Label(\"来源与记录\""))
        XCTAssertFalse(detail.contains("detailMetric(\"净值\""))
        XCTAssertFalse(detail.contains("detailMetric(\"调仓单\""))
        XCTAssertTrue(detail.contains("sourceSummaryText"))
        XCTAssertTrue(detail.contains("actionDescriptionText"))
        XCTAssertTrue(detail.contains("Text(\"调仓说明\")"))
    }

    func testPlatformAdjustmentListUsesWiderFourColumnCards() throws {
        let platform = try source(at: "Views/PlatformSectionView.swift")
        let actionRow = try source(at: "Views/Platform/PlatformActionRow.swift")

        XCTAssertTrue(platform.contains("availableWidth * 0.36"))
        XCTAssertTrue(platform.contains("showsFourColumnMetrics: !isCompact"))
        XCTAssertTrue(actionRow.contains("showsFourColumnMetrics"))
        XCTAssertTrue(actionRow.contains("compactFourColumnLayout"))
        XCTAssertTrue(actionRow.contains("count: 4"))
    }

    func testPlatformHoldingsShowsAssetClassAndAssetTypeAllocationByUnits() throws {
        let platform = try source(at: "Views/PlatformSectionView.swift")
        let chart = try source(at: "Views/Platform/PlatformHoldingsPieChart.swift")
        let holdingsSectionStart = try XCTUnwrap(platform.range(of: "// MARK: - Current Holdings"))
        let listSectionStart = try XCTUnwrap(platform.range(of: "// MARK: - List Panel"))
        let holdingsSection = String(platform[holdingsSectionStart.lowerBound..<listSectionStart.lowerBound])
        let remainingSections = String(platform[listSectionStart.lowerBound..<platform.endIndex])

        XCTAssertEqual(platform.components(separatedBy: "PlatformHoldingsPieChart(").count - 1, 1)
        XCTAssertTrue(holdingsSection.contains("PlatformHoldingsPieChart("))
        XCTAssertTrue(holdingsSection.contains("@State private var isHoldingDetailsExpanded = false"))
        XCTAssertTrue(holdingsSection.contains("title: \"持仓明细\""))
        XCTAssertTrue(holdingsSection.contains("countText: \"\\(model.platformHoldings.count) 只\""))
        XCTAssertTrue(holdingsSection.contains("isExpanded: isHoldingDetailsExpanded"))
        XCTAssertFalse(remainingSections.contains("PlatformHoldingsPieChart("))
        XCTAssertFalse(chart.contains("Text(\"持仓分布\")"))
        XCTAssertTrue(platform.contains("\"\\(model.platformHoldings.count) 只 · 按当前份数统计\""))
        XCTAssertTrue(chart.contains("distributionPanel(title: \"资产大类\""))
        XCTAssertTrue(chart.contains("distributionPanel(title: \"资产类型\""))
        XCTAssertTrue(chart.contains("slices(for: .assetType)"))
        XCTAssertTrue(chart.contains("holding.largeClass"))
        XCTAssertTrue(chart.contains("holding.currentUnits"))
        XCTAssertFalse(chart.contains("按持仓金额"))
    }

    func testAlfaPanelUsesThePlatformWorkspaceScrollAndWidthContext() throws {
        let platform = try source(at: "Views/PlatformSectionView.swift")
        let alfa = try source(at: "Views/Platform/AlfaPlatformPanel.swift")

        XCTAssertTrue(platform.contains("AlfaPlatformPanel("))
        XCTAssertTrue(platform.contains("isCompact: isCompact"))
        XCTAssertTrue(platform.contains("availableWidth: proxy.size.width"))
        XCTAssertTrue(platform.contains("scrollProxy: scrollProxy"))
        XCTAssertFalse(alfa.contains("GeometryReader { proxy in"))
        XCTAssertFalse(alfa.contains("ScrollViewReader { scrollProxy in"))
        XCTAssertFalse(alfa.contains("ScrollView(showsIndicators: false)"))
    }

    func testAlfaPanelUsesSinglePortfolioDataAndAdaptiveHoldingCards() throws {
        let panel = try source(at: "Views/Platform/AlfaPlatformPanel.swift")
        let holding = try source(at: "Views/Platform/AlfaHoldingCard.swift")
        let model = try source(at: "Core/AppModel/Alfa.swift")

        XCTAssertTrue(panel.contains("model.selectedAlfaPoCode == portfolio.poCode"))
        XCTAssertTrue(panel.contains("await model.selectAlfaPortfolio(portfolio.poCode)"))
        XCTAssertTrue(panel.contains("if let selectedPortfolio, !holdings.isEmpty"))
        XCTAssertTrue(panel.contains("LazyVGrid("))
        XCTAssertTrue(panel.contains(".adaptive(minimum: isCompact ? 280 : 340, maximum: 520)"))
        XCTAssertFalse(panel.contains("portfolioPrefix(for:"))
        XCTAssertFalse(panel.contains("selectedAlfaPoCodes"))

        XCTAssertTrue(holding.contains("ProgressView(value:"))
        XCTAssertTrue(holding.contains("Text(\"目标占比\")"))
        XCTAssertTrue(holding.contains("title: \"最新净值\""))
        XCTAssertTrue(holding.contains("title: \"日涨跌\""))

        XCTAssertTrue(model.contains("inactiveAlfaPortfolioCodes"))
        XCTAssertFalse(model.contains("mergeAlfaPayloads"))
        XCTAssertFalse(model.contains("prodCode: \"aggregate\""))
    }

    func testMainNavigationHasKeyboardShortcuts() throws {
        let source = try source(at: "QiemanDashboardApp.swift")

        XCTAssertEqual(AppSection.enhancement.rawValue, "AI研判")
        XCTAssertTrue(source.contains("Button(\"AI研判\")"))
        XCTAssertFalse(source.contains("Button(\"工作台\")"))
        XCTAssertTrue(source.contains("CommandMenu(\"导航\")"))
        XCTAssertTrue(source.contains(".keyboardShortcut(\"1\")"))
        XCTAssertTrue(source.contains(".keyboardShortcut(\"6\")"))
        XCTAssertTrue(source.contains("NotificationCenter.default.post(name: .qiemanFocusSearch"))
        XCTAssertTrue(source.contains(".keyboardShortcut(\"f\")"))
    }

    func testPlatformAdjustmentsAndForumShareOneTopLevelActivityTab() throws {
        let content = try source(at: "Views/ContentView.swift")
        let activity = try source(at: "Views/PlatformSectionView.swift")
        let overview = try source(at: "Views/Overview/OverviewSectionView.swift")
        let managerWatch = try source(at: "Core/AppModel/ManagerWatch.swift")

        XCTAssertEqual(
            AppSection.allCases.map(\.rawValue),
            ["总览", "我的持仓", "平台动态", "AI研判", "设置"]
        )
        XCTAssertEqual(PlatformActivityTab.allCases.map(\.rawValue), ["调仓动态", "论坛发言"])
        XCTAssertTrue(content.contains("PlatformActivitySectionView()"))
        XCTAssertFalse(content.contains("case .forum:"))
        XCTAssertTrue(activity.contains("struct PlatformActivitySectionView"))
        XCTAssertTrue(activity.contains("PlatformSectionView()"))
        XCTAssertTrue(activity.contains("ForumSectionView()"))
        XCTAssertTrue(overview.contains("model.selectedPlatformActivityTab = .forum"))
        XCTAssertTrue(managerWatch.contains("selectedPlatformActivityTab = .forum"))
        XCTAssertFalse(overview.contains("model.selectedSection = .forum"))
        XCTAssertFalse(managerWatch.contains("selectedSection = .forum"))
    }

    func testOverviewUsesCompactRecentPlatformActionCards() throws {
        let overview = try source(at: "Views/Overview/OverviewSectionView.swift")
        let actionRow = try source(at: "Views/Platform/PlatformActionRow.swift")

        XCTAssertTrue(overview.contains("isCompact: true"))
        XCTAssertTrue(overview.contains("showsCompactArticleLink: true"))
        XCTAssertTrue(actionRow.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(actionRow.contains("compactWideLayout"))
        XCTAssertTrue(actionRow.contains("compactStackedLayout"))
        XCTAssertTrue(actionRow.contains("Label(\"平台原文\", systemImage: \"arrow.up.right\")"))
        XCTAssertFalse(actionRow.contains("compactMetricPill"))
    }

    func testOverviewGroupsManagerActivityIntoOneSection() throws {
        let overview = try source(at: "Views/Overview/OverviewSectionView.swift")

        XCTAssertEqual(overview.components(separatedBy: "SectionCard(").count - 1, 1)
        XCTAssertTrue(overview.contains("title: \"主理人动态\""))
        XCTAssertTrue(overview.contains("subtitle: \"调仓动作与最新发言\""))
        XCTAssertTrue(overview.contains("managerActivityGroup("))
        XCTAssertTrue(overview.contains("managerActivityCountText"))
        XCTAssertTrue(overview.contains(".background(AppPalette.cardStrong"))
        XCTAssertTrue(overview.contains("Label(\"查看全部\", systemImage: \"chevron.right\")"))
        XCTAssertTrue(overview.contains("action: openAllPlatformActions"))
        XCTAssertTrue(overview.contains("action: openAllForumPosts"))
        XCTAssertFalse(overview.contains("managerActivityHeader("))
    }

    func testQuitApplicationIsReachableFromMenuBarPopoverAndSettings() throws {
        let appModel = try source(at: "Core/AppModel/Auth.swift")
        let menuBar = try source(at: "Views/MenuBarPortfolioView.swift")
        let settings = try source(at: "Views/SettingsAppPanel.swift")

        XCTAssertTrue(appModel.contains("func quitApplication()"))
        XCTAssertTrue(appModel.contains("NSApplication.shared.terminate(nil)"))

        XCTAssertTrue(menuBar.contains("Button(\"退出应用\")"))
        XCTAssertTrue(menuBar.contains("model.quitApplication()"))

        XCTAssertTrue(settings.contains("title: \"退出且慢主理人\""))
        XCTAssertTrue(settings.contains("Button(\"退出应用\")"))
        XCTAssertTrue(settings.contains("model.quitApplication()"))
    }

    func testMenuBarPopoverShowsAndRefreshesPersonalWatchlist() throws {
        let menuBar = try source(at: "Views/MenuBarPortfolioView.swift")

        XCTAssertTrue(menuBar.contains("Text(\"我的关注\")"))
        XCTAssertTrue(menuBar.contains("MenuBarWatchlistRow(row: row)"))
        XCTAssertTrue(menuBar.contains("percentOptional(row.changeSinceFollowPct)"))
        XCTAssertTrue(menuBar.contains("try? await model.refreshPersonalWatchlist(updateNotice: false)"))
        XCTAssertTrue(menuBar.contains("@AppStorage(\"menu.bar.popover.top-section\")"))
        XCTAssertTrue(menuBar.contains("Text(\"\\(section.title)在上\")"))
        XCTAssertTrue(menuBar.contains("ForEach(orderedSections)"))
    }

    func testMenuBarPopoverChecksForUpdatesInsteadOfOpeningTheDataDirectory() throws {
        let menuBar = try source(at: "Views/MenuBarPortfolioView.swift")
        let updateButtonStart = try XCTUnwrap(
            menuBar.range(of: "Button(model.isCheckingForUpdates ? \"检测中…\" : \"检测更新\")")
        )
        let quitButtonStart = try XCTUnwrap(
            menuBar.range(of: "Button(\"退出应用\")", range: updateButtonStart.upperBound..<menuBar.endIndex)
        )
        let updateButton = String(menuBar[updateButtonStart.lowerBound..<quitButtonStart.lowerBound])

        XCTAssertTrue(updateButton.contains("model.showMainWindow(section: .settings)"))
        XCTAssertTrue(updateButton.contains("await model.checkForUpdates(userInitiated: true)"))
        XCTAssertTrue(updateButton.contains(".disabled(model.isCheckingForUpdates)"))
        XCTAssertFalse(menuBar.contains("Button(\"数据目录\")"))
        XCTAssertFalse(menuBar.contains("model.openDataDirectory()"))
    }

    func testWatchlistLookupKeepsLocalResolutionWhileRefreshingTheName() throws {
        let watchlist = try source(at: "Views/PersonalWatchlistView.swift")

        XCTAssertTrue(watchlist.contains("model.preparePersonalWatchlistCode("))
        XCTAssertTrue(watchlist.contains(".onChange(of: lookupKey, initial: true)"))
        XCTAssertTrue(watchlist.contains("requestID == lookupRequestID"))
        XCTAssertTrue(watchlist.contains("resolution = resolved ?? prepared"))
        XCTAssertTrue(watchlist.contains(".disabled(resolution == nil || isSaving)"))
        XCTAssertFalse(watchlist.contains(".disabled(resolution == nil || isResolving || isSaving)"))
    }

    func testPortfolioAllocationPanelUsesCompactSummaryAndPopoverDetail() throws {
        let panel = try source(at: "Views/PortfolioAllocationPanel.swift")

        // 明细通过 Popover 呈现，主页不再直接铺开行业 / 重仓长列表
        XCTAssertTrue(panel.contains(".popover(isPresented:"))
        XCTAssertTrue(panel.contains("查看明细…"))

        // 旧的长列表面板与大环形图已移除
        XCTAssertFalse(panel.contains("PortfolioRankedExposurePanel"))
        XCTAssertFalse(panel.contains("SectorMark"))
        XCTAssertFalse(panel.contains("allocationDonut"))

        // 进度条不再按“相对最大项”绘制（避免被误读为 100%）
        XCTAssertFalse(panel.contains("total: maximumWeight"))

        // 基金穿透模式不再使用四个 StatChip
        XCTAssertFalse(panel.contains("StatChip("))

        // 新的紧凑组件已落地
        XCTAssertTrue(panel.contains("PortfolioAllocationStackedBar"))
        XCTAssertTrue(panel.contains("PortfolioAllocationCompactLegend"))
        XCTAssertTrue(panel.contains("PortfolioAllocationDetailPopover"))
    }

    private func source(at relativePath: String) throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func sourceTree(at relativePath: String) throws -> String {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return try fileURLs
            .flatMap { url -> [URL] in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                if values.isDirectory == true {
                    let nestedPath = url.path.replacingOccurrences(of: rootURL.path + "/", with: "")
                    return try sourceFileURLs(at: rootURL.appendingPathComponent(nestedPath))
                }
                return url.pathExtension == "swift" ? [url] : []
            }
            .sorted { $0.path < $1.path }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    private func sourceFileURLs(at rootURL: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        guard let enumerator else { return [] }

        return try enumerator.compactMap { element in
            guard let url = element as? URL, url.pathExtension == "swift" else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            return values.isRegularFile == true ? url : nil
        }
    }
}
