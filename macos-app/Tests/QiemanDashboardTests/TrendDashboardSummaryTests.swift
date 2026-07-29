import XCTest
@testable import QiemanDashboard

final class TrendDashboardSummaryTests: XCTestCase {
    func testUnconfiguredProviderShowsSettingsAction() {
        let summary = TrendDashboardSummary.make(
            report: nil,
            trendStatus: EnhancementTrendStatus(
                isProviderConfigured: false,
                generationState: .idle,
                lastGeneratedAt: nil,
                headline: "尚未配置趋势分析模型",
                externalSignalStatus: nil,
                isStale: false
            ),
            generationState: .idle,
            lastError: "",
            progressLogs: []
        )

        XCTAssertEqual(summary.status, .unconfigured)
        XCTAssertEqual(summary.headline, "尚未配置趋势分析模型")
        XCTAssertEqual(summary.primaryAction.kind, .configure)
        XCTAssertEqual(summary.primaryAction.title, "配置模型")
        XCTAssertTrue(summary.horizons.isEmpty)
        XCTAssertTrue(summary.sectors.isEmpty)
    }

    func testConfiguredProviderWithoutReportShowsGenerateAction() {
        let summary = TrendDashboardSummary.make(
            report: nil,
            trendStatus: EnhancementTrendStatus(
                isProviderConfigured: true,
                generationState: .idle,
                lastGeneratedAt: nil,
                headline: "等待生成趋势分析",
                externalSignalStatus: nil,
                isStale: false
            ),
            generationState: .idle,
            lastError: "",
            progressLogs: []
        )

        XCTAssertEqual(summary.status, .empty)
        XCTAssertEqual(summary.primaryAction.kind, .generate)
        XCTAssertEqual(summary.primaryAction.title, "立即分析")
        XCTAssertNil(summary.secondaryAction)
    }

    func testGeneratedReportExtractsHeadlineRiskHorizonsAndSectors() {
        let report = TrendAnalysisReport.fixture(
            generatedAt: "2026-06-25 09:30:00",
            externalSignalStatus: .available
        )
        let summary = TrendDashboardSummary.make(
            report: report,
            trendStatus: EnhancementTrendStatus(
                isProviderConfigured: true,
                generationState: .succeeded,
                lastGeneratedAt: report.generatedAt,
                headline: report.portfolio.headline,
                externalSignalStatus: report.externalSignalStatus,
                isStale: false
            ),
            generationState: .succeeded,
            lastError: "",
            progressLogs: []
        )

        XCTAssertEqual(summary.status, .ready)
        XCTAssertEqual(summary.headline, report.portfolio.headline)
        XCTAssertEqual(summary.riskText, report.portfolio.riskLevel.dashboardText)
        XCTAssertEqual(summary.primaryAction.kind, .openReport)
        XCTAssertEqual(summary.secondaryAction?.kind, .refresh)
        XCTAssertEqual(summary.horizons.map(\.title), ["短期", "中期", "长期"])
        XCTAssertEqual(summary.sectors.count, min(4, report.sectors.count))
        XCTAssertEqual(summary.dataAsOf, report.dataAsOf)
        XCTAssertEqual(summary.externalSignalText, "外部信号可用")
    }

    func testGeneratedReportKeepsPortfolioSummaryReadableForWideOverview() {
        let longDetail = "当前组合包含 26 只场外基金，总市值约 37.29 万元。组合在科技与海外资产上积累了丰厚的浮盈，消费与白酒板块短期承压但仍需结合计划节奏复核。"
        let report = TrendAnalysisReport.fixture(
            generatedAt: "2026-06-25 09:30:00",
            externalSignalStatus: .available
        )
        .replacingPortfolio(
            TrendPortfolioSummary(
                headline: "组合整体盈利稳固，结构上呈现科技/海外领涨",
                riskLevel: .medium,
                summary: longDetail
            )
        )

        let summary = TrendDashboardSummary.make(
            report: report,
            trendStatus: EnhancementTrendStatus(
                isProviderConfigured: true,
                generationState: .succeeded,
                lastGeneratedAt: report.generatedAt,
                headline: report.portfolio.headline,
                externalSignalStatus: report.externalSignalStatus,
                isStale: false
            ),
            generationState: .succeeded,
            lastError: "",
            progressLogs: []
        )

        XCTAssertEqual(summary.detail, longDetail)
    }

    func testGeneratedReportKeepsHorizonAndSectorRationalesComplete() {
        let horizonRationale = "短期判断需要完整保留模型返回的依据，包括成交量、估值、行业轮动、资金流向和组合暴露，不能因为总览卡片使用紧凑布局就提前截断正文。"
        let sectorRationale = "板块判断需要完整呈现模型给出的证据链，包括当前持仓、阶段涨跌、政策催化、盈利预期和潜在反向信号，避免省略号掩盖关键条件。"
        let report = TrendAnalysisReport.fixture(
            generatedAt: "2026-06-25 09:30:00",
            externalSignalStatus: .available
        )
        .replacingAnalysis(
            horizons: [
                TrendHorizonView(
                    horizon: .short,
                    direction: .neutral,
                    confidence: TrendConfidence(score: 62, label: "中"),
                    rationale: horizonRationale,
                    counterSignals: []
                )
            ],
            sectors: [
                TrendSectorView(
                    id: "technology",
                    name: "半导体与科技制造",
                    exposureText: "组合穿透后制造业暴露 57.5%",
                    direction: .neutral,
                    confidence: TrendConfidence(score: 48, label: "低"),
                    rationale: sectorRationale,
                    evidenceIDs: [],
                    counterSignals: []
                )
            ]
        )

        let summary = TrendDashboardSummary.make(
            report: report,
            trendStatus: EnhancementTrendStatus(
                isProviderConfigured: true,
                generationState: .succeeded,
                lastGeneratedAt: report.generatedAt,
                headline: report.portfolio.headline,
                externalSignalStatus: report.externalSignalStatus,
                isStale: false
            ),
            generationState: .succeeded,
            lastError: "",
            progressLogs: []
        )

        XCTAssertEqual(summary.horizons.first?.rationale, horizonRationale)
        XCTAssertEqual(summary.sectors.first?.rationale, sectorRationale)
    }

    func testStaleReportMarksRefreshAsPrimaryAction() {
        let report = TrendAnalysisReport.fixture(
            generatedAt: "2026-06-24 09:30:00",
            externalSignalStatus: .partial
        )
        let summary = TrendDashboardSummary.make(
            report: report,
            trendStatus: EnhancementTrendStatus(
                isProviderConfigured: true,
                generationState: .succeeded,
                lastGeneratedAt: report.generatedAt,
                headline: report.portfolio.headline,
                externalSignalStatus: report.externalSignalStatus,
                isStale: true
            ),
            generationState: .succeeded,
            lastError: "",
            progressLogs: []
        )

        XCTAssertEqual(summary.status, .stale)
        XCTAssertEqual(summary.stateText, "待更新")
        XCTAssertEqual(summary.primaryAction.kind, .refresh)
        XCTAssertEqual(summary.secondaryAction?.kind, .openReport)
    }

    func testFailedGenerationKeepsRecoveryActionAndShortError() {
        let summary = TrendDashboardSummary.make(
            report: nil,
            trendStatus: EnhancementTrendStatus(
                isProviderConfigured: true,
                generationState: .failed,
                lastGeneratedAt: nil,
                headline: "模型请求失败",
                externalSignalStatus: nil,
                isStale: false
            ),
            generationState: .failed,
            lastError: "趋势分析模型请求失败：HTTP 429。服务商提示余额不足或无可用资源包。",
            progressLogs: []
        )

        XCTAssertEqual(summary.status, .failed)
        XCTAssertEqual(summary.primaryAction.kind, .refresh)
        XCTAssertTrue(summary.detail.contains("HTTP 429"))
        XCTAssertLessThanOrEqual(summary.detail.count, 48)
    }

    func testGeneratingStateUsesLatestProgressLogAndDisablesPrimaryAction() {
        let summary = TrendDashboardSummary.make(
            report: nil,
            trendStatus: EnhancementTrendStatus(
                isProviderConfigured: true,
                generationState: .generating,
                lastGeneratedAt: nil,
                headline: "等待模型返回",
                externalSignalStatus: nil,
                isStale: false
            ),
            generationState: .generating,
            lastError: "",
            progressLogs: [
                TrendProgressLog(timestamp: "2026-06-25 09:30:00", message: "启动趋势模型"),
                TrendProgressLog(timestamp: "2026-06-25 09:31:00", message: "等待模型返回：模型分析 已等待 1m")
            ]
        )

        XCTAssertEqual(summary.status, .generating)
        XCTAssertEqual(summary.primaryAction.kind, .wait)
        XCTAssertTrue(summary.primaryAction.isDisabled)
        XCTAssertEqual(summary.detail, "等待模型返回：模型分析 已等待 1m")
    }

    /// Overview 板块源码已按子视图拆到 Views/Overview/ 目录，断言汇总该目录下所有 .swift 文件。
    private func overviewSectionSources() throws -> String {
        let overviewDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Views/Overview")
        let urls = try FileManager.default
            .contentsOfDirectory(at: overviewDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        return try urls
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    func testOverviewSourceRendersAITrendSummaryPanel() throws {
        let source = try overviewSectionSources()

        XCTAssertTrue(source.contains("AITrendSummaryPanel("))
        XCTAssertTrue(source.contains("summary: model.trendDashboardSummary"))
        XCTAssertTrue(source.contains("model.selectedEnhancementTab = .trend"))
        XCTAssertTrue(source.contains("model.startTrendAnalysis(userInitiated: true)"))
    }

    func testOverviewSourceMergesSummaryIntoTodayBrief() throws {
        let source = try overviewSectionSources()

        XCTAssertTrue(source.contains("summaryItems: overviewBriefSummaryItems"))
        XCTAssertTrue(source.contains("TodayBriefSummaryCard("))
        XCTAssertFalse(source.contains("OverviewHeroCard()"))
        XCTAssertFalse(source.contains("struct OverviewHeroCard"))
        XCTAssertFalse(source.contains("今日看板"))
        XCTAssertFalse(source.contains("总览摘要"))
    }

    func testOverviewSourceUsesFullWidthGridsAndDropsAssetOverview() throws {
        let source = try overviewSectionSources()

        XCTAssertFalse(source.contains("SectionCard(title: \"资产总览\""))
        XCTAssertFalse(source.contains("OverviewAssetTypeSummary"))
        XCTAssertFalse(source.contains("assetTypeSummary"))
        XCTAssertTrue(source.contains("todayBriefWideColumns"))
        XCTAssertTrue(source.contains("trendHorizonWideColumns"))
        XCTAssertTrue(source.contains("trendSectorWideColumns"))
        XCTAssertTrue(source.contains(".lineLimit(4)"))
        XCTAssertTrue(source.contains(".lineLimit(3)"))
    }

    func testOverviewSourceDropsManagerActivityAndFreshnessPanels() throws {
        let source = try overviewSectionSources()

        XCTAssertFalse(source.contains("DashboardInsightPanel("))
        XCTAssertFalse(source.contains("struct DashboardInsightPanel"))
        XCTAssertFalse(source.contains("ManagerActivityPanel"))
        XCTAssertFalse(source.contains("FreshnessStatusPanel"))
        XCTAssertFalse(source.contains("openManagerActivity"))
        XCTAssertFalse(source.contains("openFreshness"))
        XCTAssertTrue(source.contains("title: \"主理人动态\""))
        XCTAssertFalse(source.contains("数据状态"))
    }

    func testTrendPanelUsesPageScopedAutoScrollingRealtimeLog() throws {
        let viewsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Views", isDirectory: true)
        let trendSource = try String(
            contentsOf: viewsURL.appendingPathComponent("EnhancementTrendPanel.swift"),
            encoding: .utf8
        )
        let liveLogSource = try String(
            contentsOf: viewsURL.appendingPathComponent("TrendLiveLogPanel.swift"),
            encoding: .utf8
        )
        let contentSource = try String(
            contentsOf: viewsURL.appendingPathComponent("ContentView.swift"),
            encoding: .utf8
        )
        let centerSource = try String(
            contentsOf: viewsURL.appendingPathComponent("EnhancementCenterView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(trendSource.contains("trendReportBalancedLayout"))
        XCTAssertTrue(trendSource.contains("trendReportSectionGrid"))
        XCTAssertTrue(trendSource.contains("trendReportWideColumns"))
        XCTAssertFalse(trendSource.contains("trendProgressSummaryCard"))
        XCTAssertFalse(contentSource.contains("TrendLiveLogPanel()"))
        XCTAssertTrue(centerSource.contains("TrendLiveLogPanel()"))
        XCTAssertTrue(liveLogSource.contains("AI 分析实时日志"))
        XCTAssertTrue(liveLogSource.contains("ScrollViewReader"))
        XCTAssertTrue(liveLogSource.contains("scrollToBottom"))
        XCTAssertTrue(liveLogSource.contains(".onChange(of: latestLog?.id)"))
        XCTAssertTrue(liveLogSource.contains("model.trendProgressLogs"))
        XCTAssertFalse(liveLogSource.contains(".suffix(6)"))
    }

    func testWorkbenchUsesSegmentedConfigReportSignalsLayout() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let centerSource = try String(
            contentsOf: rootURL.appendingPathComponent("Views/EnhancementCenterView.swift"),
            encoding: .utf8
        )
        let trendSource = try String(
            contentsOf: rootURL.appendingPathComponent("Views/EnhancementTrendPanel.swift"),
            encoding: .utf8
        )
        let evidencePopoverSource = try String(
            contentsOf: rootURL.appendingPathComponent("Views/TrendEvidenceDetailPopover.swift"),
            encoding: .utf8
        )

        // 分段状态由 AppModel 持有（selectedWorkbenchSegment 迁至 EnhancementState，支持通知深链直达）
        XCTAssertTrue(centerSource.contains("model.selectedWorkbenchSegment"))
        XCTAssertTrue(centerSource.contains("workbenchSegmentBar"))
        XCTAssertTrue(centerSource.contains("workbenchSegmentContent"))
        XCTAssertTrue(centerSource.contains("case .today"))
        XCTAssertTrue(centerSource.contains("case .tracking"))
        // 巨型 trendPanel 已拆分为三个独立分段
        XCTAssertFalse(centerSource.contains("trendPanel"))
        // 顶部「理财工作台」标题卡与运行时 chips 已删除，分段栏直接作为工作台入口
        XCTAssertFalse(centerSource.contains("理财工作台"))
        XCTAssertFalse(centerSource.contains("dashboardHeader"))
        XCTAssertFalse(centerSource.contains("runtimeChip"))
        XCTAssertFalse(centerSource.contains("headerTitleBlock"))
        // 分段按钮使用大号交互样式，不再是原生窄条 segmented Picker
        XCTAssertFalse(centerSource.contains(".pickerStyle(.segmented)"))
        XCTAssertTrue(centerSource.contains("workbenchSegmentButton"))
        XCTAssertTrue(centerSource.contains("interactiveSurface"))

        // 分析设置已迁至设置页；趋势面板只保留报告与信号内容
        XCTAssertFalse(trendSource.contains("var configSegment"))
        XCTAssertTrue(trendSource.contains("var reportSegment"))
        XCTAssertTrue(trendSource.contains("var signalsSegment"))
        // AI 操作建议从报告网格移出，独立成段
        XCTAssertFalse(trendSource.contains("SectionCard(title: \"趋势\""))
        // 信号卡片重做：左侧状态色条 + 图标盒 + 状态徽章 + 置信度进度条 + 圆点条件
        XCTAssertTrue(trendSource.contains("tradeSignalStatusBadge"))
        XCTAssertTrue(trendSource.contains("tradeSignalActionIcon"))
        XCTAssertTrue(trendSource.contains("tradeSignalConditionLine"))
        XCTAssertTrue(trendSource.contains("tradeSignalAssetSubtitle"))
        XCTAssertTrue(trendSource.contains("AppPalette.accentGlow(tint)"))
        XCTAssertTrue(trendSource.contains("trendConfidenceBar(item.confidence)"))
        // 旧版平铺胶囊（裸文字置信度）已替换为带框徽章 + 进度条
        XCTAssertFalse(trendSource.contains("置信度 \\(item.confidence.normalizedScore)"))
        // 趋势报告：整页重构为三分区聚拢骨架（市场视图/重点标的/核验）
        XCTAssertTrue(trendSource.contains("marketSection"))
        XCTAssertTrue(trendSource.contains("actionSection"))
        XCTAssertTrue(trendSource.contains("verificationSection"))
        XCTAssertTrue(trendSource.contains("trendReportSectionTitle"))
        XCTAssertTrue(trendSource.contains("trendDirectionDot"))
        XCTAssertTrue(trendSource.contains("trendDirectionBadge"))
        XCTAssertTrue(trendSource.contains("trendAssetCard"))
        XCTAssertTrue(trendSource.contains("trendEvidenceCard"))
        // 子模块标题已上移到分区级，不再各自带 subHeader
        XCTAssertFalse(trendSource.contains("trendReportSubHeader"))
        // 头部声明 pill 已移除（disclaimer 移至核验区底部）
        XCTAssertFalse(trendSource.contains("trendMiniPill(\"声明\""))
        // 6 个子模块不再用 trendBlock 图标标题块包裹
        XCTAssertFalse(trendSource.contains("trendBlock(\"周期判断\""))
        XCTAssertFalse(trendSource.contains("trendBlock(\"板块\""))
        XCTAssertFalse(trendSource.contains("trendBlock(\"重点标的\""))
        XCTAssertFalse(trendSource.contains("trendBlock(\"行动候选\""))
        XCTAssertFalse(trendSource.contains("trendBlock(\"证据来源\""))
        XCTAssertFalse(trendSource.contains("trendBlock(\"边界与提示\""))
        // 普通报告卡片仍复用静态表面；市场/板块卡片通过原生 Button + popover
        // 明确提供 Agent 判断依据，并保留键盘、VoiceOver 与 Esc 关闭能力。
        XCTAssertTrue(trendSource.contains(".staticSurface("))
        XCTAssertTrue(trendSource.contains("activeStrokeOpacity"))
        XCTAssertFalse(trendSource.contains("hoverFill: AppPalette.cardHover"))
        XCTAssertFalse(trendSource.contains("lift:"))
        XCTAssertTrue(trendSource.contains("trendEvidenceDisclosureFooter"))
        XCTAssertTrue(trendSource.contains("trendEvidencePopoverBinding"))
        XCTAssertTrue(trendSource.contains("TrendEvidenceDetailPopover("))
        XCTAssertTrue(trendSource.contains(".buttonStyle(PressResponsiveButtonStyle())"))
        XCTAssertTrue(trendSource.contains(".accessibilityHint("))
        XCTAssertTrue(evidencePopoverSource.contains("Agent 判断依据"))
        XCTAssertTrue(evidencePopoverSource.contains("支持证据"))
        XCTAssertTrue(evidencePopoverSource.contains("反向证据"))
        XCTAssertTrue(evidencePopoverSource.contains("背景数据"))
        XCTAssertTrue(evidencePopoverSource.contains("item.summary"))
        // 市场视图：周期与板块共用统一三列定义，消除宽屏空列与高矮不齐
        XCTAssertTrue(trendSource.contains("marketCardColumns"))
        XCTAssertTrue(trendSource.contains("columns: columns"))
        XCTAssertFalse(trendSource.contains(".adaptive(minimum: 200)"))
        XCTAssertTrue(trendSource.contains("本次报告未生成市场判断"))
        XCTAssertTrue(trendSource.contains("Text(outlook.categoryDisplayName)"))
        XCTAssertFalse(trendSource.contains("Text(outlook.category)"))
        // 组合暴露从拥挤的标题行移到独立信息区，允许多行完整展示。
        XCTAssertTrue(trendSource.contains("trendSectorExposure(sector.exposureText)"))
        XCTAssertTrue(trendSource.contains("func trendSectorExposure(_ exposureText: String)"))
        // 板块卡说明不再截断（sector rationale 用 fixedSize 完整展示，无 lineLimit）
        XCTAssertTrue(trendSource.contains("Text(sector.rationale)"))
    }

    func testWorkbenchSourceDropsReviewAndTodoRail() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Views/EnhancementCenterView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("statusCardGrid(summary)"))
        XCTAssertFalse(source.contains("actionQueueRail"))
        XCTAssertFalse(source.contains("SectionCard(title: \"下一步\""))
        XCTAssertFalse(source.contains("private var reviewPanel"))
        XCTAssertFalse(source.contains("monthlyReportPreview"))
        XCTAssertFalse(source.contains("本月复盘"))
        XCTAssertFalse(source.contains("待办"))
    }

    func testTrendPreferencesLiveInSettingsCenterInsteadOfTheWorkbench() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: rootURL.appendingPathComponent("Views/SettingsSectionView.swift"),
            encoding: .utf8
        )
        let trendSettingsSource = try String(
            contentsOf: rootURL.appendingPathComponent("Views/SettingsTrendPanel.swift"),
            encoding: .utf8
        )
        let trendPanelSource = try String(
            contentsOf: rootURL.appendingPathComponent("Views/EnhancementTrendPanel.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(settingsSource.contains("case trend"))
        XCTAssertTrue(settingsSource.contains("TrendSettingsPanel()"))
        XCTAssertTrue(trendSettingsSource.contains("struct TrendSettingsPanel: View"))
        XCTAssertTrue(trendSettingsSource.contains("model.checkTrendAIConnection()"))
        XCTAssertFalse(trendSettingsSource.contains("DisclosureGroup(isExpanded: $isTrendConfigurationExpanded)"))
        XCTAssertFalse(trendPanelSource.contains("trendConfigurationPanel"))
        XCTAssertTrue(trendPanelSource.contains("设置 > AI 研判"))
    }
}

private extension TrendAnalysisReport {
    func replacingPortfolio(_ portfolio: TrendPortfolioSummary) -> TrendAnalysisReport {
        TrendAnalysisReport(
            id: id,
            generatedAt: generatedAt,
            dataAsOf: dataAsOf,
            privacyMode: privacyMode,
            externalSignalStatus: externalSignalStatus,
            portfolio: portfolio,
            horizons: horizons,
            sectors: sectors,
            keyAssets: keyAssets,
            actions: actions,
            evidence: evidence,
            warnings: warnings,
            disclaimer: disclaimer
        )
    }

    func replacingAnalysis(
        horizons: [TrendHorizonView],
        sectors: [TrendSectorView]
    ) -> TrendAnalysisReport {
        TrendAnalysisReport(
            id: id,
            generatedAt: generatedAt,
            dataAsOf: dataAsOf,
            privacyMode: privacyMode,
            externalSignalStatus: externalSignalStatus,
            portfolio: portfolio,
            horizons: horizons,
            sectors: sectors,
            keyAssets: keyAssets,
            actions: actions,
            evidence: evidence,
            warnings: warnings,
            disclaimer: disclaimer
        )
    }
}
