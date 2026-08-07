import SwiftUI

extension EnhancementCenterView {
    /// AI 投资指引单页：围绕用户决策链路按紧迫度排列。
    /// 盘中实时 → 投资方向 → 需要关注的风险 → 长期趋势 → 判断与复盘。
    var investmentDashboardContent: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            InvestmentIntelligenceDashboardView {
                intradaySection
                investmentDirectionSection
            } trendContent: {
                trendSection
            }
            legacyTrackingDisclosure
        }
    }

    // MARK: - ① 盘中实时指引

    var intradaySection: some View {
        SectionCard(
            title: "盘中实时指引",
            subtitle: model.nextHourGuidanceScheduleText,
            icon: "clock.arrow.circlepath",
            trailing: {
                Spacer()
                Button {
                    model.startNextHourGuidance()
                } label: {
                    Label(
                        model.nextHourGuidanceGenerationState == .generating ? "生成中…" : "手动生成",
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
                .disabled(
                    !model.trendSettings.provider.isConfigured
                        || model.nextHourGuidanceGenerationState == .generating
                        || model.trendGenerationState == .generating
                )
            }
        ) {
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                if model.trendSettings.provider.isConfigured,
                   !model.trendSettings.webSearch.isConfigured {
                    Label(
                        "未配置联网搜索：风控规则只允许输出持有建议",
                        systemImage: "lock.trianglebadge.exclamationmark"
                    )
                    .font(AppPalette.appFont(.caption, weight: .medium))
                    .foregroundStyle(AppPalette.warning)
                }

                if model.nextHourGuidanceGenerationState == .generating {
                    HStack(spacing: AppPalette.spaceS) {
                        ProgressView().controlSize(.small)
                        Text("正在刷新行情并搜索最新消息…")
                            .font(AppPalette.appFont(.subheadline, weight: .medium))
                            .foregroundStyle(AppPalette.muted)
                    }
                    .padding(.vertical, AppPalette.spaceS)
                }

                if let report = model.nextHourGuidanceReport {
                    nextHourGuidanceReportView(report)
                } else if model.nextHourGuidanceGenerationState != .generating {
                    Text(model.trendSettings.provider.isConfigured
                         ? "将在下一个交易时段自动生成，也可以手动触发。"
                         : "配置 AI 模型后自动启用。")
                        .font(AppPalette.appFont(.subheadline))
                        .foregroundStyle(AppPalette.muted)
                        .padding(.vertical, AppPalette.spaceS)
                }

                if !model.nextHourGuidanceError.isEmpty {
                    Label(model.nextHourGuidanceError, systemImage: "exclamationmark.triangle.fill")
                        .font(AppPalette.appFont(.footnote, weight: .medium))
                        .foregroundStyle(AppPalette.warning)
                }
            }
        }
    }

    // MARK: - ② 值得关注的投资方向

    var investmentDirectionSection: some View {
        let opportunities = MarketOpportunityEngine.analyze(report: model.trendReport)

        return SectionCard(
            title: "值得关注的投资方向",
            subtitle: "已持有板块动作 + 全市场板块机会 + 大盘与资产风向",
            icon: "lightbulb",
            trailing: {
                Spacer()
                Button {
                    model.startTrendAnalysis(userInitiated: true)
                } label: {
                    Label(
                        model.trendGenerationState == .generating ? "扫描中…" : "扫描市场",
                        systemImage: "globe.asia.australia"
                    )
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
                .disabled(
                    !model.trendSettings.provider.isConfigured
                        || !model.trendSettings.webSearch.isConfigured
                        || model.trendGenerationState == .generating
                )
            }
        ) {
            VStack(alignment: .leading, spacing: AppPalette.spaceL) {
                // 全市场扫描会经历行情刷新、基金穿透、分组检索、模型判断和报告校验。
                // 直接展示 Agent 已有的阶段日志，避免旧报告仍在时页面只剩“扫描中…”按钮。
                TrendLiveLogPanel()

                InvestmentDirectionView(
                    analysis: opportunities,
                    hasTrendReport: model.trendReport != nil,
                    isProviderConfigured: model.trendSettings.provider.isConfigured,
                    isWebSearchConfigured: model.trendSettings.webSearch.isConfigured
                )
            }
        }
    }

    // MARK: - ④ 长期趋势研判

    var trendSection: some View {
        SectionCard(
            title: "长期趋势研判",
            subtitle: trendSectionSubtitle,
            icon: "chart.line.uptrend.xyaxis",
            trailing: {
                Spacer()
                Button {
                    model.startTrendAnalysis(userInitiated: true)
                } label: {
                    Label(model.trendGenerationState == .generating ? "生成中…" : "立即分析", systemImage: "wand.and.stars")
                }
                .buttonStyle(.appSecondary)
                .controlSize(.small)
                .disabled(
                    !model.trendSettings.provider.isConfigured
                        || model.trendGenerationState == .generating
                )
            }
        ) {
            if let report = model.trendReport {
                todayReportView(report)
            } else if model.trendGenerationState == .generating {
                HStack(spacing: AppPalette.spaceS) {
                    ProgressView().controlSize(.small)
                    Text("正在分析…")
                        .font(AppPalette.appFont(.subheadline, weight: .medium))
                        .foregroundStyle(AppPalette.muted)
                }
                .padding(.vertical, AppPalette.spaceS)
            } else if model.trendSettings.provider.isConfigured {
                trendEmptyState("等待生成", detail: "趋势分析会结合持仓、平台动态和外部信号，输出周期判断和行动候选。")
            } else {
                trendEmptyState("未配置模型", detail: "在「设置」里配置 AI 模型后即可生成趋势研判。")
            }
        }
    }

    private var trendSectionSubtitle: String {
        if let generated = model.trendReport?.generatedAt {
            return "生成于 \(String(generated.prefix(16)))"
        }
        return "周期方向、板块观点、行动候选"
    }

    private var legacyTrackingDisclosure: some View {
        DisclosureGroup(isExpanded: $isLegacyTrackingExpanded) {
            trackingContent
                .padding(.top, AppPalette.spaceM)
        } label: {
            Label("旧趋势跟踪清单", systemImage: "archivebox")
                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                .foregroundStyle(AppPalette.muted)
        }
        .tint(AppPalette.muted)
    }

    private var researchEvidenceDisclosure: some View {
        DisclosureGroup(isExpanded: $isResearchEvidenceExpanded) {
            VStack(alignment: .leading, spacing: AppPalette.spaceL) {
                TrendLiveLogPanel()
                if model.trendReport != nil {
                    ShareLink(item: shareReportText()) {
                        Label("分享完整研究报告", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.appSecondary)
                    .controlSize(.small)
                }
                researchEvidenceSection
            }
            .padding(.top, AppPalette.spaceM)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Label("研究依据", systemImage: "doc.text.magnifyingglass")
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Text("展开查看盘中研判、趋势报告、证据与数据边界")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
            }
        }
        .tint(AppPalette.brand)
        .padding(.horizontal, AppPalette.spaceM)
        .padding(.vertical, AppPalette.spaceS)
    }

    /// 研究依据区(旧功能降级):下一小时(盘中短周期)+ 趋势研报(中长期)。
    private var researchEvidenceSection: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            nextHourGuidanceModule
            Group {
                if let report = model.trendReport {
                    todayReportView(report)
                } else if model.trendSettings.provider.isConfigured {
                    trendEmptyState("等待生成", detail: "趋势分析会结合本地持仓、平台动态和模型可用的外部信号，输出条件式判断和反证条件。")
                } else {
                    trendEmptyState("未配置模型", detail: "点右上角「设置」填写模型地址、模型名称和 API Key 后即可生成。")
                }
            }
        }
    }

    private var nextHourGuidanceModule: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            HStack(spacing: AppPalette.spaceS) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(AppPalette.appFont(.title3, weight: .bold))
                    .foregroundStyle(AppPalette.onBrand)
                    .frame(width: 30, height: 30)
                    .background(AppPalette.brand, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                VStack(alignment: .leading, spacing: 2) {
                    Text("下一小时买卖建议")
                        .font(AppPalette.appFont(.title3, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text(model.nextHourGuidanceScheduleText)
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer(minLength: AppPalette.spaceS)
                nextHourGuidanceStatus
                Button {
                    model.startNextHourGuidance()
                } label: {
                    Label(
                        model.nextHourGuidanceGenerationState == .generating ? "生成中…" : "手动生成",
                        systemImage: "arrow.clockwise"
                    )
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                }
                .buttonStyle(.appSecondary)
                .disabled(
                    !model.trendSettings.provider.isConfigured
                        || model.nextHourGuidanceGenerationState == .generating
                        || model.trendGenerationState == .generating
                )
            }

            if model.trendSettings.provider.isConfigured,
               !model.trendSettings.webSearch.isConfigured {
                Label(
                    "未配置 Tavily 联网搜索：Agent 仍会读取行情和基金穿透，但风控规则只允许输出持有。",
                    systemImage: "lock.trianglebadge.exclamationmark"
                )
                .font(AppPalette.appFont(.caption, weight: .medium))
                .foregroundStyle(AppPalette.warning)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            }

            if model.nextHourGuidanceGenerationState == .generating {
                HStack(spacing: AppPalette.spaceS) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在刷新行情、穿透基金底层资产并搜索最新消息，再生成买入 / 卖出 / 持有建议…")
                        .font(AppPalette.appFont(.subheadline, weight: .medium))
                        .foregroundStyle(AppPalette.muted)
                }
                .padding(.vertical, AppPalette.spaceS)
            }

            if let report = model.nextHourGuidanceReport {
                nextHourGuidanceReportView(report)
            } else {
                Text(model.trendSettings.provider.isConfigured
                     ? "将在下一个交易时段槽位自动生成；也可以随时手动触发。场外基金不会参与盘中逐小时研判，只在 14:50 或手动研判时纳入。"
                     : "配置 AI 模型后自动启用。生成成功会发送系统提醒，点击提醒可回到 AI 研判。")
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, AppPalette.spaceS)
            }

            if !model.nextHourGuidanceError.isEmpty {
                Label(model.nextHourGuidanceError, systemImage: "exclamationmark.triangle.fill")
                    .font(AppPalette.appFont(.footnote, weight: .medium))
                    .foregroundStyle(AppPalette.warning)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppPalette.spaceL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .staticSurface(
            tint: AppPalette.brand,
            fill: AppPalette.cardStrong,
            strokeOpacity: 0.20,
            activeStrokeOpacity: 0.42
        )
    }

    @ViewBuilder
    var nextHourGuidanceStatus: some View {
        switch model.nextHourGuidanceGenerationState {
        case .generating:
            trendMetaTag("状态", "生成中", tint: AppPalette.info)
        case .succeeded:
            trendMetaTag("状态", "已更新", tint: AppPalette.positive)
        case .failed, .rejected:
            trendMetaTag("状态", "上次失败", tint: AppPalette.warning)
        case .idle:
            trendMetaTag("状态", "等待时段", tint: AppPalette.muted)
        }
    }

    func nextHourGuidanceReportView(
        _ report: NextHourGuidanceReport
    ) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            HStack(alignment: .firstTextBaseline, spacing: AppPalette.spaceS) {
                Text(report.headline)
                    .font(AppPalette.appFont(.title3, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: AppPalette.spaceS)
                TintedCapsuleBadge(
                    text: report.posture.displayName,
                    tint: nextHourPostureTint(report.posture),
                    font: AppPalette.appFont(.footnote, weight: .bold),
                    horizontalPadding: 8,
                    verticalPadding: 3,
                    softStrokeOpacity: nil
                )
            }

            HStack(spacing: 6) {
                trendMetaTag("生成", String(report.generatedAt.suffix(8)), tint: AppPalette.info)
                trendMetaTag("有效至", String(report.validUntil.suffix(5)), tint: AppPalette.brand)
                trendMetaTag("范围", report.scope.displayName, tint: AppPalette.warning)
                trendMetaTag(
                    "处置",
                    trendDispositionText(report.disposition),
                    tint: trendDispositionTint(report.disposition)
                )
                trendMetaTag("标的", "\(report.assetCount)", tint: AppPalette.muted)
            }

            // 当处置为 analysisOnly（风控只允许持有）时，明确说明为什么全是持有
            if report.disposition == .analysisOnly {
                Label(
                    "当前数据条件下风控规则只允许输出持有建议。配置联网搜索后，AI 可获取更多实时信号，输出更精细的买卖建议。",
                    systemImage: "info.circle"
                )
                .font(AppPalette.appFont(.caption, weight: .medium))
                .foregroundStyle(AppPalette.info)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text(report.summary)
                .font(AppPalette.appFont(.subheadline))
                .foregroundStyle(AppPalette.muted)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            // 只显示最有把握的 3 个标的（按置信度降序）
            let topActions = report.actions.sorted { $0.confidence > $1.confidence }.prefix(3)
            let hiddenCount = max(0, report.actions.count - 3)
            VStack(spacing: AppPalette.spaceS) {
                ForEach(Array(topActions)) { action in
                    nextHourGuidanceActionRow(action, allEvidence: report.evidence)
                }
            }
            if hiddenCount > 0 {
                Text("还有 \(hiddenCount) 个标的建议持有，置信度较低未展开")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .padding(.top, 2)
            }

            if !report.riskChecks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("执行前复核")
                        .font(AppPalette.appFont(.footnote, weight: .bold))
                        .foregroundStyle(AppPalette.warning)
                    ForEach(report.riskChecks, id: \.self) { item in
                        Label(item, systemImage: "checkmark.shield")
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.muted)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(AppPalette.spaceS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    AppPalette.warning.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                )
            }

            if !report.evidence.isEmpty || !report.warnings.isEmpty {
                DisclosureGroup("判断依据与数据边界") {
                    VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                        trendSourceStatusList(report.sourceStatuses)
                        ForEach(report.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(AppPalette.appFont(.caption))
                                .foregroundStyle(AppPalette.warning)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        trendEvidenceList(report.evidence)
                    }
                    .padding(.top, AppPalette.spaceS)
                }
                .font(AppPalette.appFont(.footnote, weight: .semibold))
                .tint(AppPalette.info)
            }

            Text(report.disclaimer)
                .font(AppPalette.appFont(.caption2))
                .foregroundStyle(AppPalette.muted.opacity(0.85))
        }
    }

    func nextHourGuidanceActionRow(
        _ action: NextHourGuidanceAction,
        allEvidence: [TrendEvidence] = []
    ) -> some View {
        let tint = nextHourActionTint(action.action)
        let confidenceLabel: String
        let confidenceColor: Color
        if action.confidence >= 85 {
            confidenceLabel = "很高"
            confidenceColor = AppPalette.positive
        } else if action.confidence >= 70 {
            confidenceLabel = "较高"
            confidenceColor = AppPalette.positive
        } else if action.confidence >= 55 {
            confidenceLabel = "中等"
            confidenceColor = AppPalette.info
        } else {
            confidenceLabel = "偏低"
            confidenceColor = AppPalette.warning
        }
        return NextHourGuidanceActionCard(
            action: action,
            allEvidence: allEvidence,
            tint: tint,
            confidenceLabel: confidenceLabel,
            confidenceColor: confidenceColor
        )
    }

    func nextHourCondition(_ title: String, _ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(title)
                .font(AppPalette.appFont(.caption, weight: .bold))
                .foregroundStyle(tint)
            Text(text)
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func nextHourPostureTint(_ posture: NextHourGuidancePosture) -> Color {
        switch posture {
        case .defensive:
            return AppPalette.warning
        case .balanced:
            return AppPalette.info
        case .selective:
            return AppPalette.brand
        case .opportunistic:
            return AppPalette.positive
        }
    }

    func nextHourActionTint(_ action: NextHourGuidanceActionKind) -> Color {
        switch action {
        case .buy, .buySmall:
            return AppPalette.marketGain
        case .sell, .reduceSmall:
            return AppPalette.marketLoss
        case .hold, .watch, .wait:
            return AppPalette.info
        case .avoidChasing:
            return AppPalette.info
        }
    }

    func todayReportView(_ report: TrendAnalysisReport) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            trendPortfolioHeader(report)
            VStack(alignment: .leading, spacing: AppPalette.spaceM) {
                trendReportSectionTitle("组合方向", icon: "clock")
                trendHorizonGrid(report.horizons)
            }
            marketSection(report)
            actionSection(report)
            todayActionCandidates(report)
            todayVerificationSection(report)
        }
    }

    // 行动候选（最多 3 条）：原因/触发/失效/置信度 + 加入跟踪
    func todayActionCandidates(_ report: TrendAnalysisReport) -> some View {
        let actions = Array(report.actions.prefix(3))
        return VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            trendReportSectionTitle("行动候选", icon: "checklist")
            if actions.isEmpty {
                trendEmptyState("暂无行动候选", detail: "当前报告没有建议新增观察、调仓复核或计划调整动作。")
            } else {
                VStack(spacing: AppPalette.spaceS) {
                    ForEach(actions) { action in
                        todayActionCard(action, report: report)
                    }
                }
            }
        }
    }

    func todayActionCard(_ action: TrendActionCandidate, report: TrendAnalysisReport) -> some View {
        let tracked = model.hasActiveTrackingItem(for: action)
        let tint = todayActionTint(action.kind)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(action.title)
                    .font(AppPalette.appFont(.body, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                TintedCapsuleBadge(
                    text: action.kind.displayText,
                    tint: tint,
                    font: AppPalette.appFont(.caption, weight: .bold),
                    horizontalPadding: 6,
                    verticalPadding: 2
                )
                trendConfidenceMeter(action.confidence)
                Spacer(minLength: 6)
                Button {
                    model.addTrackingItem(from: action, report: report)
                } label: {
                    Label(tracked ? "已跟踪" : "加入跟踪", systemImage: tracked ? "checkmark.circle.fill" : "bell.badge")
                        .font(AppPalette.appFont(.footnote, weight: .semibold))
                }
                .buttonStyle(.appSecondary)
                .tint(tint)
                .disabled(tracked)
            }

            Text(action.detail)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppPalette.spaceS) {
                    todayConditionLine("触发", action.triggerConditions, tint: AppPalette.info)
                    todayConditionLine("失效", action.invalidatingConditions, tint: AppPalette.warning)
                }
                VStack(alignment: .leading, spacing: 4) {
                    todayConditionLine("触发", action.triggerConditions, tint: AppPalette.info)
                    todayConditionLine("失效", action.invalidatingConditions, tint: AppPalette.warning)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .staticSurface(
            tint: tint,
            fill: AppPalette.cardStrong,
            strokeOpacity: 0.18,
            activeStrokeOpacity: 0.40
        )
    }

    @ViewBuilder
    func todayConditionLine(_ title: String, _ items: [String], tint: Color) -> some View {
        let trimmed = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !trimmed.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(AppPalette.appFont(.caption, weight: .semibold))
                    .foregroundStyle(tint)
                Text(trimmed.joined(separator: "；"))
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: AppPalette.badgeRadius))
            .overlay(RoundedRectangle(cornerRadius: AppPalette.badgeRadius).stroke(tint.opacity(0.35), lineWidth: 1))
        }
    }

    @ViewBuilder
    private func todayVerificationSection(_ report: TrendAnalysisReport) -> some View {
        if !report.evidence.isEmpty || !report.warnings.isEmpty {
            DisclosureGroup("证据与风险边界") {
                VStack(alignment: .leading, spacing: AppPalette.spaceM) {
                    trendEvidenceList(report.evidence)
                    trendWarnings(report)
                }
                .padding(.top, 6)
            }
            .font(AppPalette.appFont(.body, weight: .semibold))
            .tint(AppPalette.info)
        }
    }

    func todayActionTint(_ kind: TrendActionKind) -> Color {
        switch kind {
        case .watch, .waitForConfirmation:
            return AppPalette.info
        case .observeInBatches, .rebalanceReview:
            return AppPalette.brand
        case .pausePlan, .considerReduce:
            return AppPalette.warning
        case .considerIncrease:
            return AppPalette.positive
        }
    }
}

// MARK: - 盘中操作建议卡（独立 View，自带依据弹窗）

/// 单个标的的操作建议卡。点击「依据 N 条」弹出 Sheet 展示证据详情。
struct NextHourGuidanceActionCard: View {
    let action: NextHourGuidanceAction
    let allEvidence: [TrendEvidence]
    let tint: Color
    let confidenceLabel: String
    let confidenceColor: Color

    @State private var isShowingDetail = false

    /// 该标的引用的证据（从全局 evidence 按 evidenceID 过滤）。
    /// 如果 evidenceID 在 allEvidence 里匹配不到（如子 Agent 未注入 Ledger），
    /// 则展示全部 evidence 作为兜底，至少让用户能看到内容。
    private var referencedEvidence: [TrendEvidence] {
        let matched = allEvidence.filter { action.evidenceIDs.contains($0.id) }
        if !matched.isEmpty { return matched }
        // 兜底：如果按 ID 匹配不到，但有全局 evidence，展示全部（总比空白好）
        return allEvidence
    }

    var body: some View {
        Button {
            isShowingDetail = true
        } label: {
            HStack(alignment: .top, spacing: AppPalette.spaceS) {
                Rectangle()
                    .fill(tint)
                    .frame(width: 3)
                    .clipShape(Capsule())
                VStack(alignment: .leading, spacing: 4) {
                    // 第一行：标的名 + 操作 + 把握度
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(action.targetName)
                            .font(AppPalette.appFont(.body, weight: .bold))
                            .foregroundStyle(AppPalette.ink)
                            .lineLimit(1)
                        Text(action.action.displayName)
                            .font(AppPalette.appFont(.footnote, weight: .bold))
                            .foregroundStyle(tint)
                        Spacer(minLength: 4)
                        Text("把握 \(confidenceLabel) \(action.confidence)")
                            .font(AppPalette.appFont(.footnote, weight: .semibold))
                            .foregroundStyle(confidenceColor)
                    }
                    // 第二行：操作说明（instruction）截断显示
                    Text(action.instruction)
                        .font(AppPalette.appFont(.subheadline))
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(AppPalette.spaceM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.controlFill, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
            .contentShape(RoundedRectangle(cornerRadius: AppPalette.controlRadius))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isShowingDetail) {
            NextHourGuidanceActionDetailSheet(
                action: action,
                tint: tint,
                confidenceLabel: confidenceLabel,
                confidenceColor: confidenceColor,
                evidence: referencedEvidence
            )
        }
    }

    private func conditionView(_ title: String, _ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(title)
                .font(AppPalette.appFont(.caption, weight: .bold))
                .foregroundStyle(tint)
            Text(text)
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 盘中操作建议详情弹窗

/// 点击标的条目弹出的 Sheet，展示完整的理由、触发/失效条件、依据。
struct NextHourGuidanceActionDetailSheet: View {
    let action: NextHourGuidanceAction
    let tint: Color
    let confidenceLabel: String
    let confidenceColor: Color
    let evidence: [TrendEvidence]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // 固定标题栏
            headerBar

            Divider()

            // 可滚动内容
            ScrollView {
                VStack(alignment: .leading, spacing: AppPalette.spaceM) {
                    // 操作说明
                    detailSection("操作说明", icon: "arrow.right.circle") {
                        Text(action.instruction)
                            .font(AppPalette.appFont(.subheadline))
                            .foregroundStyle(AppPalette.ink)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // 理由
                    if !action.rationale.isEmpty {
                        detailSection("为什么", icon: "questionmark.bubble") {
                            Text(action.rationale)
                                .font(AppPalette.appFont(.subheadline))
                                .foregroundStyle(AppPalette.muted)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    // 触发/失效条件
                    if !action.trigger.isEmpty || !action.invalidation.isEmpty {
                        detailSection("条件", icon: "scope") {
                            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                                conditionRow("触发", action.trigger, tint: AppPalette.info)
                                conditionRow("失效", action.invalidation, tint: AppPalette.warning)
                            }
                        }
                    }

                    // 判断依据
                    if !evidence.isEmpty {
                        detailSection("判断依据（\(evidence.count) 条）", icon: "doc.text.magnifyingglass") {
                            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                                ForEach(evidence) { ev in
                                    evidenceRow(ev)
                                }
                            }
                        }
                    }
                }
                .padding(AppPalette.spaceL)
            }
        }
        .frame(width: 600, height: 640)
    }

    // MARK: - 固定标题栏

    private var headerBar: some View {
        HStack(spacing: AppPalette.spaceS) {
            Rectangle().fill(tint).frame(width: 3, height: 36).clipShape(Capsule())
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(action.targetName)
                        .font(AppPalette.appFont(.headline, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                    Text(action.action.displayName)
                        .font(AppPalette.appFont(.body, weight: .bold))
                        .foregroundStyle(tint)
                }
                HStack(spacing: AppPalette.spaceS) {
                    TintedCapsuleBadge(
                        text: "把握 \(confidenceLabel) \(action.confidence)",
                        tint: confidenceColor,
                        font: AppPalette.appFont(.footnote, weight: .bold),
                        horizontalPadding: 8, verticalPadding: 3
                    )
                    if !action.evidenceIDs.isEmpty {
                        TintedCapsuleBadge(
                            text: "依据 \(action.evidenceIDs.count) 条",
                            tint: AppPalette.info,
                            font: AppPalette.appFont(.footnote, weight: .bold),
                            horizontalPadding: 8, verticalPadding: 3
                        )
                    }
                }
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(AppPalette.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AppPalette.spaceM)
        .padding(.vertical, AppPalette.spaceS)
    }

    // MARK: - 辅助

    private func detailSection<C: View>(_ title: String, icon: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            Label(title, systemImage: icon)
                .font(AppPalette.appFont(.headline, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
            content()
        }
        .padding(AppPalette.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(AppPalette.appFont(.subheadline, weight: .semibold))
            .foregroundStyle(AppPalette.muted)
            .padding(.top, AppPalette.spaceS)
    }

    private func conditionRow(_ title: String, _ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: AppPalette.spaceS) {
            Text(title)
                .font(AppPalette.appFont(.subheadline, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 36, alignment: .leading)
            Text(text)
                .font(AppPalette.appFont(.subheadline))
                .foregroundStyle(AppPalette.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 证据行：根据来源类型用不同图标和颜色，不套额外卡片层。
    private func evidenceRow(_ item: TrendEvidence) -> some View {
        let (icon, iconColor) = evidenceIcon(for: item)
        return HStack(alignment: .top, spacing: AppPalette.spaceS) {
            Image(systemName: icon)
                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.summary)
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppPalette.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.controlFill.opacity(0.5), in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
    }

    /// 根据证据来源类型返回图标和颜色。
    private func evidenceIcon(for item: TrendEvidence) -> (String, Color) {
        let source = item.sourceName
        if source.contains("行情") {
            return ("chart.line.uptrend.xyaxis", AppPalette.brand)
        } else if source.contains("新闻") {
            return ("newspaper", AppPalette.info)
        } else if source.contains("持仓") {
            return ("chart.pie.fill", AppPalette.positive)
        } else if source.contains("官方") || source.contains("SEC") {
            return ("doc.text.fill", AppPalette.warning)
        } else {
            return ("link", AppPalette.muted)
        }
    }
}
