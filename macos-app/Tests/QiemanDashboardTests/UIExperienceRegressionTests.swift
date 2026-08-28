import XCTest
@testable import QiemanDashboard

final class UIExperienceRegressionTests: XCTestCase {
    func testPresentedAssetSheetDisablesBackgroundInteractionAndHover() throws {
        let browser = try source(at: "Views_macOS/PersonalAssetBrowser.swift")
        let row = try source(at: "Views_macOS/PersonalAsset/PersonalAssetTableRow.swift")
        let components = try source(at: "Views_macOS/SharedComponents.swift")

        XCTAssertTrue(browser.contains("let allowsInteraction = selectedDetailRow == nil"))
        XCTAssertTrue(browser.contains(".allowsHitTesting(allowsInteraction)"))
        XCTAssertTrue(browser.contains("allowsHoverFeedback: allowsInteraction"))
        XCTAssertTrue(row.contains("allowsHoverFeedback: allowsHoverFeedback"))
        XCTAssertTrue(components.contains(".onChange(of: allowsHoverFeedback)"))
        XCTAssertTrue(components.contains("isHovering = false"))
    }

    func testSharedInteractionPrimitivesSupportStaticSurfacesDismissibleToastsAndReducedMotion() throws {
        let source = try source(at: "Views_macOS/SharedComponents.swift")

        XCTAssertTrue(source.contains("func staticSurface("))
        XCTAssertTrue(source.contains("accessibilityReduceMotion"))
        XCTAssertTrue(source.contains("let onDismiss: (() -> Void)?"))
    }

    func testResponsiveCardHoverDoesNotExpandPastScrollBounds() throws {
        let source = try source(at: "Views_macOS/SharedComponents.swift")

        XCTAssertTrue(source.contains("configuration.isPressed ? 0.965 : 1"))
        XCTAssertTrue(source.contains(".brightness(isHovering ? 0.025 : 0)"))
        XCTAssertFalse(source.contains("isHovering ? 1.018"))
    }

    func testVisibleActionsUseTheUnifiedAppButtonSystem() throws {
        let components = try source(at: "Views_macOS/SharedComponents.swift")
        let views = try sourceTree(at: "Views_macOS")

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
        let components = try source(at: "Views_macOS/SharedComponents.swift")
        let portfolio = try source(at: "Views_macOS/PortfolioSectionView.swift")
        let platform = try source(at: "Views_macOS/PlatformSectionView.swift")
        let enhancement = try source(at: "Views_macOS/EnhancementCenterView.swift")

        XCTAssertTrue(components.contains("struct ModuleTabBar<"))
        XCTAssertTrue(components.contains("private func tabLabel"))
        XCTAssertTrue(components.contains("private func tabCell"))
        XCTAssertTrue(components.contains("selectedFill: AppPalette.brand"))
        XCTAssertTrue(components.contains("fill: AppPalette.cardStrong"))
        XCTAssertTrue(components.contains("hoverFill: AppPalette.cardHover"))

        XCTAssertTrue(portfolio.contains("ModuleTabBar("))
        XCTAssertTrue(platform.contains("ModuleTabBar("))
        // AI 研判页已合并为单页通览，不再使用 ModuleTabBar
        XCTAssertFalse(enhancement.contains("ModuleTabBar("))

        XCTAssertFalse(portfolio.contains(".pickerStyle(.segmented)"))
        XCTAssertFalse(platform.contains("isSelected ? AppPalette.brand : AppPalette.cardStrong"))
        XCTAssertFalse(enhancement.contains("workbenchSegmentButton"))
    }

    func testAssetAddControlUsesACustomPopoverInsteadOfTheSystemMenu() throws {
        let source = try source(at: "Views_macOS/PersonalAssetCards.swift")
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
        let source = try source(at: "Views_macOS/PersonalAsset/PersonalAssetTableRow.swift")

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
        let components = try source(at: "Views_macOS/SettingsComponents.swift")
        let menuBar = try source(at: "Views_macOS/SettingsMenuBarPanel.swift")
        let watch = try source(at: "Views_macOS/SettingsWatchPanel.swift")

        XCTAssertTrue(components.contains("Toggle(title, isOn: isOn)"))
        XCTAssertTrue(menuBar.contains("isConfirmingMenuBarReset"))
        XCTAssertTrue(menuBar.contains("向前移动"))
        XCTAssertTrue(menuBar.contains("向后移动"))
        XCTAssertFalse(menuBar.contains(".frame(width: 18, height: 18)"))
        XCTAssertTrue(watch.contains("title: \"平台动态来源\""))
        XCTAssertTrue(watch.contains("调仓动态 · 可多选"))
        XCTAssertTrue(watch.contains("model.managerWatchAvailableAdjustmentSources"))
        XCTAssertTrue(watch.contains("model.updateManagerWatchAdjustmentSource"))
        XCTAssertTrue(watch.contains("title: \"系统通知\""))
        XCTAssertTrue(watch.contains("model.isManagerWatchPolling"))
        XCTAssertTrue(watch.contains("model.managerWatchNextCheckText"))
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

        let settings = try source(at: "Views_macOS/SettingsSectionView.swift")
        let appSettings = try source(at: "Views_macOS/SettingsAppPanel.swift")
        let content = try source(at: "Views_macOS/ContentView.swift")
        let menuBar = try source(at: "Views_macOS/MenuBarPortfolioView.swift")
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
        XCTAssertTrue(appSettings.contains("spacing: AppPalette.spaceXL"))
        XCTAssertTrue(content.contains(".preferredColorScheme(model.appearance.colorScheme)"))
        XCTAssertTrue(menuBar.contains(".preferredColorScheme(model.appearance.colorScheme)"))
        XCTAssertTrue(appModel.contains("appDelegate?.syncWindowAppearances()"))
    }

    func testSettingsHierarchyUsesDistinctPanelHeaderGroupHeaderAndContentSurfaces() throws {
        let components = try source(at: "Views_macOS/SettingsComponents.swift")

        XCTAssertTrue(components.contains(".font(AppPalette.appFont(.largeTitle, weight: .bold))"))
        XCTAssertTrue(components.contains(".background(AppPalette.surfaceVariant.opacity(0.28))"))
        XCTAssertTrue(components.contains(".background(tint.opacity(0.075))"))
        XCTAssertTrue(components.contains("Capsule()"))
        XCTAssertTrue(components.contains(".background(AppPalette.card)"))
        XCTAssertTrue(components.contains("colorSchemeContrast == .increased"))
    }

    func testEditorsKeepValidationFeedbackInsideThePresentedSheet() throws {
        let sources = try [
            source(at: "Views_macOS/PersonalAsset/PersonalPendingTradeEditSheet.swift"),
            source(at: "Views_macOS/PersonalAsset/PersonalInvestmentPlanEditor.swift"),
            source(at: "Views_macOS/PersonalAssetCards.swift"),
        ]

        for source in sources {
            XCTAssertTrue(source.contains("inlineErrorMessage"))
        }
    }

    func testHiddenHorizontalOverflowIsNotUsedForPrimaryInformation() throws {
        let content = try source(at: "Views_macOS/ContentView.swift")
        let forum = try source(at: "Views_macOS/ForumSectionView.swift")

        XCTAssertFalse(content.contains("ScrollView(.horizontal, showsIndicators: false)"))
        XCTAssertFalse(forum.contains("ScrollView(.horizontal, showsIndicators: false)"))
    }

    func testWorkspaceListsUseBoundedScrollViewportsWithoutDrawingPastTheirCards() throws {
        let fixedViewportSources = try [
            source(at: "Views_macOS/PlatformSectionView.swift"),
            source(at: "Views_macOS/Platform/AlfaPlatformPanel.swift"),
        ]

        for source in fixedViewportSources {
            XCTAssertFalse(source.contains(".fixedSize(horizontal: false, vertical: true)"))
            XCTAssertTrue(source.contains(".frame(height: PlatformWorkspaceLayout.actionListHeight)"))
            XCTAssertTrue(source.contains(".clipped()"))
        }

        let forum = try source(at: "Views_macOS/ForumSectionView.swift")
        XCTAssertFalse(forum.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertTrue(forum.contains("availableHeight: proxy.size.height"))
        XCTAssertTrue(forum.contains(".frame(height: PlatformWorkspaceLayout.forumListHeight(for: availableHeight))"))
        XCTAssertTrue(forum.contains(".clipped()"))
    }

    func testAdjustmentWorkspaceKeepsColumnsAlignedAndDetailConcise() throws {
        let platform = try source(at: "Views_macOS/PlatformSectionView.swift")
        let detail = try source(at: "Views_macOS/Platform/PlatformActionDetailCard.swift")

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
        let platform = try source(at: "Views_macOS/PlatformSectionView.swift")
        let actionRow = try source(at: "Views_macOS/Platform/PlatformActionRow.swift")

        XCTAssertTrue(platform.contains("availableWidth * 0.36"))
        XCTAssertTrue(platform.contains("showsFourColumnMetrics: !isCompact"))
        XCTAssertTrue(actionRow.contains("showsFourColumnMetrics"))
        XCTAssertTrue(actionRow.contains("compactFourColumnLayout"))
        XCTAssertTrue(actionRow.contains("count: 4"))
    }

    func testPlatformHoldingsShowsAssetClassAndAssetTypeAllocationByUnits() throws {
        let platform = try source(at: "Views_macOS/PlatformSectionView.swift")
        let chart = try source(at: "Views_macOS/Platform/PlatformHoldingsPieChart.swift")
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
        let platform = try source(at: "Views_macOS/PlatformSectionView.swift")
        let alfa = try source(at: "Views_macOS/Platform/AlfaPlatformPanel.swift")

        XCTAssertTrue(platform.contains("AlfaPlatformPanel("))
        XCTAssertTrue(platform.contains("isCompact: isCompact"))
        XCTAssertTrue(platform.contains("availableWidth: proxy.size.width"))
        XCTAssertTrue(platform.contains("scrollProxy: scrollProxy"))
        XCTAssertFalse(alfa.contains("GeometryReader { proxy in"))
        XCTAssertFalse(alfa.contains("ScrollViewReader { scrollProxy in"))
        XCTAssertFalse(alfa.contains("ScrollView(showsIndicators: false)"))
    }

    func testAlfaPanelUsesSinglePortfolioDataAndAdaptiveHoldingCards() throws {
        let panel = try source(at: "Views_macOS/Platform/AlfaPlatformPanel.swift")
        let holding = try source(at: "Views_macOS/Platform/AlfaHoldingCard.swift")
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
        let content = try source(at: "Views_macOS/ContentView.swift")
        let activity = try source(at: "Views_macOS/PlatformSectionView.swift")
        let overview = try source(at: "Views_macOS/Overview/OverviewSectionView.swift")
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
        let overview = try source(at: "Views_macOS/Overview/OverviewSectionView.swift")
        let actionRow = try source(at: "Views_macOS/Platform/PlatformActionRow.swift")

        XCTAssertTrue(overview.contains("isCompact: true"))
        XCTAssertTrue(overview.contains("showsCompactArticleLink: true"))
        XCTAssertTrue(actionRow.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(actionRow.contains("compactWideLayout"))
        XCTAssertTrue(actionRow.contains("compactStackedLayout"))
        XCTAssertTrue(actionRow.contains("Label(\"平台原文\", systemImage: \"arrow.up.right\")"))
        XCTAssertFalse(actionRow.contains("compactMetricPill"))
    }

    func testOverviewGroupsManagerActivityIntoOneSection() throws {
        let overview = try source(at: "Views_macOS/Overview/OverviewSectionView.swift")

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
        let menuBar = try source(at: "Views_macOS/MenuBarPortfolioView.swift")
        let settings = try source(at: "Views_macOS/SettingsAppPanel.swift")

        XCTAssertTrue(appModel.contains("func quitApplication()"))
        XCTAssertTrue(appModel.contains("NSApplication.shared.terminate(nil)"))

        XCTAssertTrue(menuBar.contains("Button(\"退出应用\")"))
        XCTAssertTrue(menuBar.contains("model.quitApplication()"))

        XCTAssertTrue(settings.contains("title: \"退出且慢主理人\""))
        XCTAssertTrue(settings.contains("Button(\"退出应用\")"))
        XCTAssertTrue(settings.contains("model.quitApplication()"))
    }

    func testMenuBarPopoverShowsAndRefreshesPersonalWatchlist() throws {
        let menuBar = try source(at: "Views_macOS/MenuBarPortfolioView.swift")

        XCTAssertTrue(menuBar.contains("Text(\"我的关注\")"))
        XCTAssertTrue(menuBar.contains("MenuBarWatchlistRow(row: row)"))
        XCTAssertTrue(menuBar.contains("percentOptional(row.changeSinceFollowPct)"))
        // 关注刷新已迁移到 AppModel.onMenuBarPopoverPresented()，view 不再持有 .task 刷新逻辑。
        XCTAssertFalse(menuBar.contains("try? await model.refreshPersonalWatchlist(updateNotice: false)"))
        XCTAssertTrue(menuBar.contains("@AppStorage(\"menu.bar.popover.top-section\")"))
        XCTAssertTrue(menuBar.contains("Text(\"\\(section.title)在上\")"))
        XCTAssertTrue(menuBar.contains("ForEach(orderedSections)"))

        // 关注行支持右键取消关注（复用 removePersonalWatchlistItem，带确认弹窗）
        XCTAssertTrue(menuBar.contains("let onDelete: () -> Void"))
        XCTAssertTrue(menuBar.contains(".contextMenu"))
        XCTAssertTrue(menuBar.contains("Button(role: .destructive, action: onDelete)"))
        XCTAssertTrue(menuBar.contains("pendingWatchlistDeletion"))
        XCTAssertTrue(menuBar.contains("model.removePersonalWatchlistItem(pendingWatchlistDeletion.record.id)"))
    }

    func testMenuBarPopoverChecksForUpdatesInsteadOfOpeningTheDataDirectory() throws {
        let menuBar = try source(at: "Views_macOS/MenuBarPortfolioView.swift")
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

    func testMenuBarPopoverRefreshIsDrivenByAppDelegateEventNotByTaskModifier() throws {
        // popover 的 hosting controller 只创建一次，SwiftUI .task 不会每次开都重跑；
        // 刷新改由 AppDelegate.togglePopover → model.onMenuBarPopoverPresented() 触发。
        let menuBar = try source(at: "Views_macOS/MenuBarPortfolioView.swift")
        XCTAssertFalse(menuBar.contains("MenuBarPortfolioRefreshDecision"))
        XCTAssertFalse(menuBar.contains(".task {"))

        let appDelegate = try source(at: "QiemanDashboardApp.swift")
        XCTAssertTrue(appDelegate.contains("model?.onMenuBarPopoverPresented()"))

        let refresh = try source(at: "Core/AppModel/PortfolioRefresh.swift")
        XCTAssertTrue(refresh.contains("func onMenuBarPopoverPresented()"))
        XCTAssertTrue(refresh.contains("throttle(key: \"menuBarPopover\""))
    }

    func testNoHardcodedCornerRadiusInMacOSViews() throws {
        // 所有视图圆角必须走 AppPalette token；
        // PlatformHoldingsPieChart 的 cornerRadius: 0 是饼图 slice 几何参数，不是 UI 圆角，允许。
        let tree = try sourceTree(at: "Views_macOS")
        // 精确匹配 `cornerRadius: N)`，避免误伤 12 / 10 等。
        let forbidden = ["1", "1.5", "2", "6", "8"]
        for value in forbidden {
            let needle = "cornerRadius: \(value))"
            XCTAssertFalse(
                tree.contains(needle),
                "Views_macOS/ 下出现硬编码 \(needle)，请改用 AppPalette.swatchRadius / badgeRadius / controlRadius"
            )
        }
        XCTAssertTrue(tree.contains("AppPalette.swatchRadius"), "swatchRadius token 应被使用")
    }

    func testWatchlistLookupKeepsLocalResolutionWhileRefreshingTheName() throws {
        let watchlist = try source(at: "Views_macOS/PersonalWatchlist/PersonalWatchlistAddSheet.swift")

        XCTAssertTrue(watchlist.contains("model.preparePersonalWatchlistCode("))
        XCTAssertTrue(watchlist.contains(".onChange(of: lookupKey, initial: true)"))
        XCTAssertTrue(watchlist.contains("requestID == lookupRequestID"))
        XCTAssertTrue(watchlist.contains("resolution = resolved ?? prepared"))
        XCTAssertTrue(watchlist.contains(".disabled(resolution == nil || isSaving)"))
        XCTAssertFalse(watchlist.contains(".disabled(resolution == nil || isResolving || isSaving)"))
    }

    func testPortfolioAllocationPanelUsesReadableRankedBreakdown() throws {
        let panel = try source(at: "Views_macOS/PortfolioAllocationPanel.swift")

        // 主视图先交代数据口径，再直接展示直接 + 间接证券暴露和基金披露行业
        XCTAssertTrue(panel.contains("PortfolioLookThroughMetricStrip"))
        XCTAssertTrue(panel.contains("PortfolioUnderlyingPositionList"))
        XCTAssertTrue(panel.contains("PortfolioIndustryExposureList"))
        XCTAssertTrue(panel.contains("基金仓位未披露到证券"))
        XCTAssertTrue(panel.contains("穿透后证券暴露"))
        XCTAssertTrue(panel.contains("基金披露行业"))
        XCTAssertTrue(panel.contains("真实 0–100% 刻度"))

        // 基金到证券的换算降级为可展开对账表，不再用交叉流带占据主视野
        XCTAssertTrue(panel.contains("PortfolioFundDisclosureTable"))
        XCTAssertTrue(panel.contains("showsFundDisclosure.toggle()"))
        XCTAssertTrue(panel.contains("if showsFundDisclosure"))
        XCTAssertTrue(panel.contains("chevron.down"))
        XCTAssertTrue(panel.contains("rotationEffect"))
        XCTAssertTrue(panel.contains("transition(.opacity)"))
        XCTAssertTrue(panel.contains("披露重仓占基金"))
        XCTAssertTrue(panel.contains("折算占组合"))
        XCTAssertFalse(panel.contains("DisclosureGroup"))
        XCTAssertFalse(panel.contains("struct SankeyDiagram"))
        XCTAssertFalse(panel.contains("Canvas { context, size in"))
        XCTAssertFalse(panel.contains("bandPath"))

        // 明细留在当前阅读上下文内，不使用 popover 隐藏
        XCTAssertFalse(panel.contains(".popover(isPresented:"))
        XCTAssertFalse(panel.contains("查看明细…"))
        XCTAssertFalse(panel.contains("PortfolioAllocationDetailPopover"))

        // 行业饼图用 Charts 框架；证券暴露改用块状图（Treemap）
        XCTAssertTrue(panel.contains("import Charts"))
        XCTAssertTrue(try source(at: "Views_macOS/DonutChart.swift").contains("SectorMark"))
        XCTAssertTrue(panel.contains("PortfolioTreemap"))

        // 旧的大环形图 / 相对最大项进度条 / StatChip 仍不存在
        XCTAssertFalse(panel.contains("PortfolioRankedExposurePanel"))
        XCTAssertFalse(panel.contains("total: maximumWeight"))
        XCTAssertFalse(panel.contains("StatChip("))
    }

    func testInvestmentDirectionUsesUniformSummaryCardsAndOneDetailSheet() throws {
        let view = try source(
            at: "Views_macOS/InvestmentIntelligence/InvestmentDirectionView.swift"
        )
        let card = try source(
            at: "Views_macOS/InvestmentIntelligence/InvestmentDirectionCard.swift"
        )
        let detail = try source(
            at: "Views_macOS/InvestmentIntelligence/InvestmentDirectionDetailSheet.swift"
        )
        let scanState = try source(
            at: "Views_macOS/InvestmentIntelligence/InvestmentDirectionMarketScanStateView.swift"
        )

        XCTAssertTrue(view.contains(".sheet(item: $selectedSignal)"))
        XCTAssertFalse(view.contains("全市场扫描 · 不读取个人持仓"))
        XCTAssertFalse(view.contains("共呈现"))
        XCTAssertFalse(view.contains("更新于"))
        XCTAssertTrue(view.contains("全市场板块机会"))
        XCTAssertFalse(view.contains("我已持有的板块"))
        XCTAssertFalse(view.contains("analysis?.heldSectors"))
        XCTAssertTrue(view.contains("analysis?.marketScanCompleted == true"))
        XCTAssertTrue(view.contains("已隐藏旧机会和空白占位"))
        XCTAssertFalse(card.contains("dynamicTypeSize"))
        XCTAssertFalse(card.contains("minHeight:"))
        XCTAssertFalse(card.contains("portfolioWeightPct"))
        XCTAssertTrue(card.contains(".lineLimit(2, reservesSpace: true)"))
        XCTAssertTrue(card.contains(".frame(maxWidth: .infinity, alignment: .topLeading)"))
        XCTAssertTrue(card.contains("查看详情"))
        XCTAssertTrue(detail.contains("ScrollView"))
        XCTAssertTrue(detail.contains("完整证据"))
        XCTAssertFalse(detail.contains("组合暴露依据"))
        XCTAssertTrue(detail.contains("触发条件"))
        XCTAssertTrue(detail.contains("失效与反向信号"))
        XCTAssertTrue(scanState.contains("arrow.clockwise.circle.fill"))
    }

    func testInvestmentIntelligenceSeparatesMarketPortfolioAndIntradayResponsibilities() throws {
        let today = try source(at: "Views_macOS/EnhancementTodayPanel.swift")
        let intraday = try source(
            at: "Views_macOS/InvestmentIntelligence/NextHourGuidanceDecisionConsole.swift"
        )
        let progress = try source(
            at: "Views_macOS/InvestmentIntelligence/NextHourGuidanceProgressView.swift"
        )
        let actionRow = try source(
            at: "Views_macOS/InvestmentIntelligence/NextHourGuidancePriorityActionRow.swift"
        )
        let priorityActions = try source(
            at: "Views_macOS/InvestmentIntelligence/NextHourGuidancePriorityActionsView.swift"
        )
        let teamInsights = try source(
            at: "Views_macOS/InvestmentIntelligence/NextHourGuidanceTeamInsightsView.swift"
        )
        let actionDetail = try source(
            at: "Views_macOS/InvestmentIntelligence/NextHourGuidanceActionDetailSheet.swift"
        )
        let marketEngine = try source(
            at: "Core/InvestmentIntelligence/MarketOpportunityEngine.swift"
        )

        XCTAssertTrue(today.contains("title: \"全市场机会雷达\""))
        XCTAssertTrue(today.contains("subtitle: \"市场强弱主线、触发条件与失效信号\""))
        XCTAssertTrue(today.contains("title: \"我的组合长期研判\""))
        XCTAssertTrue(today.contains("portfolioLongTermReportView(report)"))

        let portfolioStart = try XCTUnwrap(
            today.range(of: "func portfolioLongTermReportView")
        )
        let portfolioEnd = try XCTUnwrap(
            today.range(
                of: "// 行动候选",
                range: portfolioStart.upperBound..<today.endIndex
            )
        )
        let portfolioSource = today[portfolioStart.lowerBound..<portfolioEnd.lowerBound]
        XCTAssertTrue(portfolioSource.contains("portfolioAssetTrendSection(report)"))
        XCTAssertFalse(portfolioSource.contains("marketSection(report)"))
        XCTAssertFalse(portfolioSource.contains("report.marketOutlook"))
        XCTAssertFalse(portfolioSource.contains("report.opportunities"))

        XCTAssertTrue(intraday.contains("NextHourGuidancePriorityActionsView"))
        XCTAssertFalse(intraday.contains("NextHourGuidanceTeamInsightsView"))
        XCTAssertTrue(priorityActions.contains("下一小时优先动作"))
        XCTAssertTrue(actionDetail.contains("NextHourGuidanceTeamInsightsView"))
        XCTAssertTrue(teamInsights.contains("三方判断约束"))
        XCTAssertTrue(teamInsights.contains("行情信号分析"))
        XCTAssertTrue(teamInsights.contains("新闻事件分析"))
        XCTAssertTrue(teamInsights.contains("持仓结构分析"))
        XCTAssertTrue(actionRow.contains("action.trigger"))
        XCTAssertTrue(actionRow.contains("action.invalidation"))
        XCTAssertTrue(progress.contains("stage.completedStepCount"))
        XCTAssertTrue(progress.contains("三方分析"))
        XCTAssertTrue(progress.contains("汇总校验"))
        XCTAssertTrue(marketEngine.contains("$0.scope == .marketWide"))
        XCTAssertFalse(marketEngine.contains("report.sectors"))
        XCTAssertFalse(marketEngine.contains("portfolioExposureText"))
    }

    func testInvestmentDashboardAnchorScrollAndEmptyHintsRemain() throws {
        // 「今日研判」摘要卡（含怎么读指南入口）已按产品决定移除；
        // 锚点滚动与空态引流/memo 化仍在，这里守护不回归。
        let dashboard = try source(
            at: "Views_macOS/InvestmentIntelligence/InvestmentIntelligenceDashboardView.swift"
        )
        let center = try source(at: "Views_macOS/EnhancementCenterView.swift")
        let today = try source(at: "Views_macOS/EnhancementTodayPanel.swift")

        // 摘要卡确实不在了
        XCTAssertFalse(dashboard.contains("InvestmentTodaySummaryCard"))

        // 复盘区段锚点
        XCTAssertTrue(dashboard.contains("investmentSectionAnchor(.closeReview)"))

        // 锚点滚动贯通:协调器注入 + 三个区段锚点
        XCTAssertTrue(center.contains("ScrollViewReader"))
        XCTAssertTrue(center.contains("investmentSectionAnchors"))
        XCTAssertTrue(today.contains("investmentSectionAnchor(.intraday)"))
        XCTAssertTrue(today.contains("investmentSectionAnchor(.marketRadar)"))
        XCTAssertTrue(today.contains("investmentSectionAnchor(.longTerm)"))

        // 空态引流与 memo 化:面板不再直接调 analyze
        XCTAssertTrue(today.contains("IntradayEmptyHintView"))
        XCTAssertTrue(today.contains("model.marketOpportunities"))
        XCTAssertFalse(today.contains("MarketOpportunityEngine.analyze"))
    }

    func testTrendSettingsPanelGuidesConfigurationWithPresetsAndLayers() throws {
        let panel = try source(at: "Views_macOS/SettingsTrendPanel.swift")
        let iosPanel = try source(at: "Views_iOS/IOSTrendSettingsView.swift")

        // 预设 chips + 取 Key 引导(命中预设时可见)
        XCTAssertTrue(panel.contains("TrendProviderPreset.allPresets"))
        XCTAssertTrue(panel.contains("applyProviderPreset"))
        XCTAssertTrue(panel.contains("consoleURL"))

        // 隐私说明:按模式如实描述,脱敏必须点明「不发送任何金额」
        XCTAssertTrue(panel.contains("不发送任何金额"))
        XCTAssertTrue(panel.contains("隐私说明"))

        // 分层:超时与三个可选数据源收进 DisclosureGroup
        XCTAssertTrue(panel.contains("DisclosureGroup(\"高级:服务超时\")"))
        XCTAssertTrue(panel.contains("高级数据源"))
        XCTAssertTrue(panel.contains("trendWebSearchCard"))

        // iOS 同步:快速选择预设 + 取 Key 链接
        XCTAssertTrue(iosPanel.contains("TrendProviderPreset"))
        XCTAssertTrue(iosPanel.contains("providerPresetBinding"))
    }

    func testDecisionProfileEditorExistsOnMacOSAndTerminologyIsUnifiedOnIOS() throws {
        let dashboard = try source(
            at: "Views_macOS/InvestmentIntelligence/InvestmentIntelligenceDashboardView.swift"
        )
        let profilePanel = try source(
            at: "Views_macOS/InvestmentIntelligence/UserDecisionProfilePanel.swift"
        )
        let iosEnhancement = try source(at: "Views_iOS/EnhancementSectionView.swift")
        let iosTracking = try source(at: "Views_iOS/IOSTrendTrackingListView.swift")
        let iosGlossary = try source(at: "Views_iOS/IOSResearchTermGlossaryView.swift")

        // macOS 画像入口:研判基础卡按钮 + sheet + 与 iOS 一致的字段
        XCTAssertTrue(dashboard.contains("UserDecisionProfilePanel()"))
        XCTAssertTrue(dashboard.contains("isShowingProfile"))
        XCTAssertTrue(profilePanel.contains("model.updateUserDecisionProfile"))
        XCTAssertTrue(profilePanel.contains("InvestmentHorizon.allCases"))
        XCTAssertTrue(profilePanel.contains("RiskTolerance.allCases"))
        XCTAssertTrue(profilePanel.contains("allowsActiveRebalancing"))
        XCTAssertTrue(profilePanel.contains("恢复默认"))

        // iOS 术语统一:不再出现「置信度」,档位来自 ConfidenceGrade
        XCTAssertFalse(iosEnhancement.contains("置信度"))
        XCTAssertFalse(iosTracking.contains("置信度"))
        XCTAssertTrue(iosEnhancement.contains("ConfidenceGrade(score:"))
        XCTAssertTrue(iosTracking.contains("ConfidenceGrade(score:"))

        // iOS 词表:同源 ResearchTerm,带「怎么读」入口
        XCTAssertTrue(iosEnhancement.contains("IOSResearchTermGlossaryView"))
        XCTAssertTrue(iosGlossary.contains("ResearchTerm.allCases"))
        XCTAssertTrue(iosGlossary.contains("不替你做买卖决定"))
    }

    func testTrendErrorsAreTriagedAndLiveLogCollapsesWhenIdle() throws {
        let liveLog = try source(at: "Views_macOS/TrendLiveLogPanel.swift")
        let today = try source(at: "Views_macOS/EnhancementTodayPanel.swift")
        let settings = try source(at: "Views_macOS/SettingsTrendPanel.swift")

        // 失败态:日志面板头部显示分诊人话 + 建议动作 + 去设置按钮
        XCTAssertTrue(liveLog.contains("TrendErrorTriage.explain"))
        XCTAssertTrue(liveLog.contains("failureExplanation"))
        XCTAssertTrue(liveLog.contains("去设置"))

        // 盘中错误行走分诊;设置页 ToastBar 用分诊文案
        XCTAssertTrue(today.contains("TrendErrorTriage.explain"))
        XCTAssertTrue(settings.contains("TrendErrorTriage.explain"))

        // 空闲收纳:运行结束自动收起为单行状态条,空闲标题为「上次…运行」
        XCTAssertTrue(liveLog.contains("isExpanded = false"))
        XCTAssertTrue(liveLog.contains("上次"))
    }

    func testMenuBarOffersAIPostureKindInSettings() throws {
        let panel = try source(at: "Views_macOS/SettingsMenuBarPanel.swift")
        XCTAssertTrue(panel.contains("AI 研判姿态"))
        XCTAssertTrue(panel.contains(".aiPosture"))
    }

    func testNextHourFollowupReviewIsWiredThroughPipeline() throws {
        let core = try source(at: "Core/NextHourGuidance.swift")
        let controller = try source(at: "Core/AppModel/NextHourGuidanceController.swift")
        let console = try source(
            at: "Views_macOS/InvestmentIntelligence/NextHourGuidanceDecisionConsole.swift"
        )
        let subAgents = try source(at: "Core/NextHourGuidance/NextHourGuidanceSubAgents.swift")

        // V1 system prompt 与 V2 决策 user message 都带回指指令
        XCTAssertTrue(core.contains("followup_reviews 中逐条回指"))
        XCTAssertTrue(core.contains("逐条回指到 followup_reviews"))
        // 取证积极性:先查再答,不许不查就 inconclusive(2026-08-19 强化)
        XCTAssertTrue(core.contains("必须先取证再回答"))
        XCTAssertTrue(core.contains("针对该关注本身补一次检索"))
        // 净化 + 报告字段
        XCTAssertTrue(core.contains("sanitizeFollowupReviews"))
        XCTAssertTrue(core.contains("followupReviews: followup.reviews"))
        // 注入:context 组装调用 + 窗口规则
        XCTAssertTrue(controller.contains("makeLastCloseReviewContext(generatedAt: generatedAt)"))
        XCTAssertTrue(controller.contains("calendarDayDistance"))
        // V2 子 Agent 主动核对:行情看量能,新闻做针对性检索
        XCTAssertTrue(subAgents.contains("逐条核对其中与行情、量能、指数表现相关的事项"))
        XCTAssertTrue(subAgents.contains("至少为每条做一次针对性搜索"))
        // UI:决策台底部回顾块(评审定:靠下)
        XCTAssertTrue(console.contains("NextHourGuidanceFollowupReviewsView"))
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
