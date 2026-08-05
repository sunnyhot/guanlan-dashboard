import SwiftUI

extension EnhancementCenterView {
    /// 今日研判：组合结论 + 数据时间 + 周期/市场/板块/重点标的 + 行动候选(可加入跟踪) + 全部持仓研判 + 折叠证据边界
    var todayContent: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            nextHourGuidanceModule
            // 投资智能(Slice 1):集中度决策事项。gate 在 InvestmentIntelligence.enabled。
            if InvestmentIntelligence.enabled {
                InvestmentIntelligencePanel()
            }
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
    private var nextHourGuidanceStatus: some View {
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

    private func nextHourGuidanceReportView(
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

            Text(report.summary)
                .font(AppPalette.appFont(.subheadline))
                .foregroundStyle(AppPalette.muted)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: AppPalette.spaceS) {
                ForEach(report.actions) { action in
                    nextHourGuidanceActionRow(action)
                }
            }

            if !report.riskChecks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("执行前复核")
                        .font(AppPalette.appFont(.footnote, weight: .bold))
                        .foregroundStyle(AppPalette.warning)
                    ForEach(Array(report.riskChecks.enumerated()), id: \.offset) { _, item in
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
                        ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, warning in
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

    private func nextHourGuidanceActionRow(
        _ action: NextHourGuidanceAction
    ) -> some View {
        let tint = nextHourActionTint(action.action)
        return HStack(alignment: .top, spacing: AppPalette.spaceS) {
            Rectangle()
                .fill(tint)
                .frame(width: 3)
                .clipShape(Capsule())
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(action.targetName)
                        .font(AppPalette.appFont(.subheadline, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text(action.action.displayName)
                        .font(AppPalette.appFont(.caption, weight: .bold))
                        .foregroundStyle(tint)
                    Spacer(minLength: 4)
                    Text("置信度 \(action.confidence)")
                        .font(AppPalette.appFont(.caption2, weight: .semibold))
                        .foregroundStyle(AppPalette.muted)
                    Text("依据 \(action.evidenceIDs.count)")
                        .font(AppPalette.appFont(.caption2, weight: .semibold))
                        .foregroundStyle(AppPalette.info)
                }
                Text(action.instruction)
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(action.rationale)
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: AppPalette.spaceS) {
                        nextHourCondition("触发", action.trigger, tint: AppPalette.info)
                        nextHourCondition("失效", action.invalidation, tint: AppPalette.warning)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        nextHourCondition("触发", action.trigger, tint: AppPalette.info)
                        nextHourCondition("失效", action.invalidation, tint: AppPalette.warning)
                    }
                }
            }
        }
        .padding(AppPalette.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.controlFill, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
    }

    private func nextHourCondition(_ title: String, _ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(title)
                .font(AppPalette.appFont(.caption2, weight: .bold))
                .foregroundStyle(tint)
            Text(text)
                .font(AppPalette.appFont(.caption2))
                .foregroundStyle(AppPalette.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func nextHourPostureTint(_ posture: NextHourGuidancePosture) -> Color {
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

    private func nextHourActionTint(_ action: NextHourGuidanceActionKind) -> Color {
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

    private func todayReportView(_ report: TrendAnalysisReport) -> some View {
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
    private func todayActionCandidates(_ report: TrendAnalysisReport) -> some View {
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

    private func todayActionCard(_ action: TrendActionCandidate, report: TrendAnalysisReport) -> some View {
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
    private func todayConditionLine(_ title: String, _ items: [String], tint: Color) -> some View {
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
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint.opacity(0.35), lineWidth: 1))
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

    private func todayActionTint(_ kind: TrendActionKind) -> Color {
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
