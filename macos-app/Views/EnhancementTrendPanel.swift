import SwiftUI

// MARK: - Workbench Segments

extension EnhancementCenterView {
    // ② 趋势报告：组合头 + 周期/板块/重点标的/行动候选/证据/边界（AI观察移至独立分段）
    var reportSegment: some View {
        SectionCard(title: "趋势报告", subtitle: trendPanelSubtitle, icon: "sparkles") {
            VStack(alignment: .leading, spacing: AppPalette.spaceM) {
                if let report = model.trendReport {
                    trendReportView(report)
                } else if model.trendSettings.provider.isConfigured {
                    trendEmptyState("等待生成", detail: "趋势分析会结合本地持仓、平台动态和模型可用的外部信号，输出条件式判断和反证条件。")
                } else {
                    trendEmptyState("未配置模型", detail: "请先前往「设置 > AI 研判」填写模型地址、模型名称和 API Key。")
                }

                if !model.lastTrendError.isEmpty {
                    trendEmptyState("最近错误", detail: model.lastTrendError)
                }
            }
        }
    }

    // ③ AI 操作建议：基于趋势分析衍生的交易信号
    var signalsSegment: some View {
        SectionCard(title: "AI 操作建议", subtitle: model.tradeSignalSummary.headline, icon: "bell.badge") {
            tradeSignalDetailList(model.tradeSignalSummary)
        }
    }

    var trendStatusStrip: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: AppPalette.spaceS)], spacing: AppPalette.spaceS) {
            trendFact(
                "模型",
                value: model.trendSettings.provider.isConfigured ? model.trendSettings.provider.model : "未配置",
                tint: model.trendSettings.provider.isConfigured ? AppPalette.positive : AppPalette.warning
            )
            trendFact("隐私模式", value: model.trendPrivacyMode.rawValue, tint: AppPalette.info)
            trendFact("最近生成", value: model.lastTrendGeneratedAt ?? "暂无", tint: model.trendReport == nil ? AppPalette.muted : AppPalette.brand)
            trendFact("状态", value: trendStateText, tint: trendStateTint)
        }
    }

    var trendActionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppPalette.spaceS) {
                trendActionButtons
            }

            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                trendActionButtons
            }
        }
    }

    var trendActionButtons: some View {
        Group {
            Picker("隐私模式", selection: trendPrivacyModeBinding) {
                ForEach(TrendPrivacyMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)

            Button {
                model.startTrendAnalysis(userInitiated: true)
            } label: {
                Label(model.trendGenerationState == .generating ? "生成中…" : "立即分析", systemImage: "wand.and.stars")
            }
            .buttonStyle(.appPrimary)
            .tint(AppPalette.brand)
            .disabled(!model.trendSettings.provider.isConfigured || model.trendGenerationState == .generating || model.trendProviderCapabilities?.supportsToolCalls == false)

            if model.trendGenerationState == .generating {
                Button {
                    model.cancelTrendAnalysis()
                } label: {
                    Label("取消", systemImage: "xmark.circle")
                }
                .buttonStyle(.appSecondary)
            }

            Button {
                Task {
                    await model.checkTrendAIConnection()
                }
            } label: {
                Label("检测模型", systemImage: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(.appSecondary)
            .disabled(!model.trendSettings.provider.isConfigured || model.trendConnectionState == .checking)
        }
    }

    func trendReportView(_ report: TrendAnalysisReport) -> some View {
        trendReportBalancedLayout(report)
    }

    func trendReportBalancedLayout(_ report: TrendAnalysisReport) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            trendPortfolioHeader(report)
            trendReportSectionGrid(report)
        }
    }

    func trendReportSectionGrid(_ report: TrendAnalysisReport) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            marketSection(report)
            actionSection(report)
            verificationSection(report)
        }
    }

    var trendReportWideColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 340), spacing: AppPalette.spaceM, alignment: .top)]
    }

    // MARK: - Report Sections

    // ① 市场视图：周期判断 + 板块
    private func trendEqualHeightGrid<Item: Identifiable, Card: View>(
        _ items: [Item],
        columnsCount: Int = 3,
        @ViewBuilder card: @escaping (Item) -> Card
    ) -> some View {
        EqualHeightGrid(items: items, columnsCount: columnsCount, horizontalSpacing: AppPalette.spaceS, verticalSpacing: AppPalette.spaceS, card: card)
    }

    @ViewBuilder
    private func trendMarketSubsection<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            Text(title)
                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                .foregroundStyle(AppPalette.muted)
            content()
        }
    }

    func marketSection(_ report: TrendAnalysisReport) -> some View {
        let columns = marketCardColumns
        return VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            trendReportSectionTitle("市场视图", icon: "chart.line.uptrend.xyaxis")
            if !report.marketOutlook.isEmpty {
                trendMarketSubsection("大盘与大类资产") {
                    trendMarketOutlookGrid(report.marketOutlook, columns: columns)
                }
            }
            if !report.sectors.isEmpty {
                trendMarketSubsection("板块") {
                    trendSectorGrid(report.sectors, columns: columns)
                }
            }
            if report.marketOutlook.isEmpty && report.sectors.isEmpty {
                trendEmptyState(
                    "本次报告未生成市场判断",
                    detail: "这是一份不完整的旧报告。请重新运行「立即分析」；新报告会在保存前拦截空的市场视图。"
                )
            }
        }
    }

    func trendMarketOutlookGrid(_ outlooks: [TrendMarketOutlook], columns: [GridItem]) -> some View {
        trendEqualHeightGrid(outlooks, columnsCount: max(1, columns.count)) { trendMarketOutlookCard($0) }
    }

    func trendMarketOutlookCard(_ outlook: TrendMarketOutlook) -> some View {
        let cardID = "market:\(outlook.id)"
        let evidenceDetail = trendEvidenceDetail(
            claimEvidence: outlook.claimEvidence,
            referencedEvidenceIDs: outlook.evidenceIDs
        )
        return Button {
            selectedTrendEvidenceCardID = cardID
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    trendDirectionDot(outlook.direction)
                    Text(outlook.name)
                        .font(AppPalette.appFont(.body, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                    trendDirectionBadge(outlook.direction)
                    Spacer(minLength: 4)
                    trendConfidenceMeter(outlook.confidence)
                    Text(outlook.categoryDisplayName)
                        .font(AppPalette.appFont(.caption, weight: .semibold))
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(1)
                }
                Text(outlook.rationale)
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                trendEvidenceDisclosureFooter(count: evidenceDetail.items.count)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: AppPalette.cardRadius))
            .staticSurface(
                tint: outlook.direction.tint,
                fill: AppPalette.cardStrong,
                strokeOpacity: 0.18,
                activeStrokeOpacity: 0.40
            )
        }
        .buttonStyle(PressResponsiveButtonStyle())
        .popover(
            isPresented: trendEvidencePopoverBinding(for: cardID),
            arrowEdge: .bottom
        ) {
            TrendEvidenceDetailPopover(
                subjectTitle: outlook.name,
                rationale: outlook.rationale,
                dataAsOf: model.trendReport?.dataAsOf ?? "",
                detail: evidenceDetail
            )
        }
        .contextMenu {
            Button("查看 Agent 判断依据") {
                selectedTrendEvidenceCardID = cardID
            }
        }
        .help("查看 \(outlook.name) 的 Agent 判断依据")
        .accessibilityLabel("\(outlook.name)，查看 Agent 判断依据")
        .accessibilityHint("打开该市场判断引用的行情、披露和联网研究数据")
    }

    /// 市场视图共用三列定义：周期判断与板块判断沿同一列线对齐，
    /// 宽屏时三列共同分配空间，消除 adaptive 在周期区右侧产生的空列。
    var marketCardColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: AppPalette.spaceS), count: 3)
    }

    // ② 重点标的：对组合趋势判断有实质影响的标的（行动候选已移至「AI 操作建议」分段）
    func actionSection(_ report: TrendAnalysisReport) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            trendReportSectionTitle("重点标的", icon: "star")
            trendAssetList(report.keyAssets)
        }
    }

    // ③ 核验：证据来源 + 边界与提示
    func verificationSection(_ report: TrendAnalysisReport) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceM) {
            trendReportSectionTitle("核验", icon: "shield.checkered")
            trendSourceStatusList(report.sourceStatuses)
            trendEvidenceList(report.evidence)
            trendWarnings(report)
        }
    }

    func trendReportSectionTitle(_ title: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(AppPalette.brand)
                Text(title)
                    .font(AppPalette.appFont(.headline, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
            }
            Rectangle()
                .fill(AppPalette.hairline.opacity(AppPalette.borderSubtle))
                .frame(height: 1)
        }
        .padding(.top, 2)
    }

    func trendPortfolioHeader(_ report: TrendAnalysisReport) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: AppPalette.spaceS) {
                    trendPortfolioHeadline(report)
                    Spacer(minLength: AppPalette.spaceS)
                    trendRiskBadge(report.portfolio.riskLevel)
                }

                VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                    trendPortfolioHeadline(report)
                    trendRiskBadge(report.portfolio.riskLevel)
                }
            }

            Text(report.portfolio.summary)
                .font(AppPalette.appFont(.body))
                .foregroundStyle(AppPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)

            HStack(spacing: AppPalette.spaceS) {
                trendMetaTag("数据时点", report.dataAsOf, tint: AppPalette.info)
                trendMetaTag("外部信号", report.externalSignalStatus.displayText, tint: report.externalSignalStatus.tint)
                trendMetaTag(
                    "处置",
                    trendDispositionText(report.disposition),
                    tint: trendDispositionTint(report.disposition)
                )
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                .stroke(AppPalette.hairline.opacity(0.38), lineWidth: 1)
        )
    }

    func trendMetaTag(_ title: String, _ value: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(AppPalette.appFont(.footnote, weight: .medium))
                .foregroundStyle(AppPalette.muted)
            Text(value)
                .font(AppPalette.appFont(.footnote, weight: .semibold))
                .foregroundStyle(tint)
        }
        .lineLimit(1)
    }

    @ViewBuilder
    func trendSourceStatusList(_ statuses: [TrendSourceStatus]) -> some View {
        if !statuses.isEmpty {
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                Text("数据来源状态")
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.muted)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 210), spacing: AppPalette.spaceS)],
                    spacing: AppPalette.spaceS
                ) {
                    ForEach(statuses) { status in
                        HStack(spacing: 7) {
                            Circle()
                                .fill(trendSourceStatusTint(status.status))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(trendSourceName(status.source))
                                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                                    .foregroundStyle(AppPalette.ink)
                                Text(status.asOf.map { "\(trendSourceStateText(status.status)) · \($0)" }
                                    ?? trendSourceStateText(status.status))
                                    .font(AppPalette.appFont(.caption))
                                    .foregroundStyle(AppPalette.muted)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            trendSourceStatusTint(status.status).opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                }
            }
        }
    }

    func trendDispositionText(_ disposition: TrendReportDisposition) -> String {
        switch disposition {
        case .actionable:
            return "具备行动条件"
        case .analysisOnly:
            return "仅供研究"
        case .insufficientEvidence:
            return "证据不足"
        }
    }

    func trendDispositionTint(_ disposition: TrendReportDisposition) -> Color {
        switch disposition {
        case .actionable:
            return AppPalette.positive
        case .analysisOnly:
            return AppPalette.info
        case .insufficientEvidence:
            return AppPalette.warning
        }
    }

    func trendSourceName(_ source: TrendDataSource) -> String {
        switch source {
        case .marketIndex: return "市场指数"
        case .portfolioQuote: return "持仓报价"
        case .fundNAV: return "基金净值/估值"
        case .fundDisclosure: return "基金披露"
        case .qiemanAdjustment: return "且慢调仓"
        case .alfaAdjustment: return "Alfa 调仓"
        case .managerWatch: return "主理人巡检"
        case .officialSource: return "官方数据"
        case .alphaVantage: return "Alpha Vantage"
        case .webSearch: return "联网搜索"
        }
    }

    func trendSourceStateText(_ state: TrendDataSourceState) -> String {
        switch state {
        case .notIntegrated: return "未接入"
        case .notConfigured: return "未配置"
        case .notRequested: return "未请求"
        case .fetching: return "获取中"
        case .successEmpty: return "成功，无数据"
        case .success: return "成功"
        case .failed: return "失败"
        }
    }

    func trendSourceStatusTint(_ state: TrendDataSourceState) -> Color {
        switch state {
        case .success:
            return AppPalette.positive
        case .successEmpty:
            return AppPalette.info
        case .fetching:
            return AppPalette.brand
        case .notIntegrated, .notConfigured, .notRequested:
            return AppPalette.muted
        case .failed:
            return AppPalette.danger
        }
    }

    func trendPortfolioHeadline(_ report: TrendAnalysisReport) -> some View {
        Text(report.portfolio.headline)
            .font(AppPalette.appFont(.title2, weight: .bold))
            .foregroundStyle(AppPalette.ink)
            .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }

    func trendRiskBadge(_ riskLevel: TrendRiskLevel) -> some View {
        Text(riskLevel.displayText)
            .font(AppPalette.appFont(.subheadline, weight: .bold, design: .rounded))
            .foregroundStyle(riskLevel.tint)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(riskLevel.tint.opacity(AppPalette.accentOnFill), in: Capsule())
    }

    func trendHorizonGrid(_ horizons: [TrendHorizonView]) -> some View {
        // 用 HStack 让短/中/长期卡片同行等高（LazyVGrid 同行 cell 高度独立，rationale 长短不一会高低不齐）
        HStack(alignment: .top, spacing: AppPalette.spaceS) {
            ForEach(horizons, id: \.horizon) { horizon in
                trendHorizonCard(horizon)
            }
        }
    }

    func trendHorizonCard(_ horizon: TrendHorizonView) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                trendDirectionDot(horizon.direction)
                Text(horizon.horizon.displayText)
                    .font(AppPalette.appFont(.body, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                trendDirectionBadge(horizon.direction)
                Spacer(minLength: 4)
                trendConfidenceMeter(horizon.confidence)
            }
            Text(horizon.rationale)
                .font(AppPalette.appFont(.subheadline))
                .foregroundStyle(AppPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            if !horizon.counterSignals.isEmpty {
                trendCounterSignalsRow(horizon.counterSignals)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .staticSurface(
            tint: horizon.direction.tint,
            fill: AppPalette.cardStrong,
            strokeOpacity: 0.18,
            activeStrokeOpacity: 0.40
        )
    }

    func trendSectorGrid(_ sectors: [TrendSectorView], columns: [GridItem]) -> some View {
        trendEqualHeightGrid(sectors, columnsCount: max(1, columns.count)) { trendSectorCard($0) }
    }

    func trendSectorCard(_ sector: TrendSectorView) -> some View {
        let cardID = "sector:\(sector.id)"
        let evidenceDetail = trendEvidenceDetail(
            claimEvidence: sector.claimEvidence,
            referencedEvidenceIDs: sector.evidenceIDs
        )
        return Button {
            selectedTrendEvidenceCardID = cardID
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    trendDirectionDot(sector.direction)
                    Text(sector.name)
                        .font(AppPalette.appFont(.body, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                    trendDirectionBadge(sector.direction)
                    Spacer(minLength: 4)
                    trendConfidenceMeter(sector.confidence)
                }
                trendSectorExposure(sector.exposureText)
                Text(sector.rationale)
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                if !sector.counterSignals.isEmpty {
                    trendCounterSignalsRow(sector.counterSignals)
                }
                trendEvidenceDisclosureFooter(count: evidenceDetail.items.count)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: AppPalette.cardRadius))
            .staticSurface(
                tint: sector.direction.tint,
                fill: AppPalette.cardStrong,
                strokeOpacity: 0.18,
                activeStrokeOpacity: 0.40
            )
        }
        .buttonStyle(PressResponsiveButtonStyle())
        .popover(
            isPresented: trendEvidencePopoverBinding(for: cardID),
            arrowEdge: .bottom
        ) {
            TrendEvidenceDetailPopover(
                subjectTitle: sector.name,
                rationale: sector.rationale,
                dataAsOf: model.trendReport?.dataAsOf ?? "",
                detail: evidenceDetail
            )
        }
        .contextMenu {
            Button("查看 Agent 判断依据") {
                selectedTrendEvidenceCardID = cardID
            }
        }
        .help("查看 \(sector.name) 的 Agent 判断依据")
        .accessibilityLabel("\(sector.name)，查看 Agent 判断依据")
        .accessibilityHint("打开该板块判断引用的行情、披露和联网研究数据")
    }

    private func trendEvidenceDetail(
        claimEvidence: TrendClaimEvidence,
        referencedEvidenceIDs: [String]
    ) -> TrendEvidenceDetailModel {
        TrendEvidenceDetailModel(
            claimEvidence: claimEvidence,
            referencedEvidenceIDs: referencedEvidenceIDs,
            evidenceLedger: model.trendReport?.evidence ?? []
        )
    }

    private func trendEvidenceDisclosureFooter(count: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(AppPalette.appFont(.caption, weight: .semibold))
            Text("查看 Agent 判断依据")
                .font(AppPalette.appFont(.caption, weight: .semibold))
            Spacer(minLength: 4)
            Text(count > 0 ? "\(count) 条" : "暂无直接证据")
                .font(AppPalette.appFont(.caption2))
            Image(systemName: "chevron.right")
                .font(AppPalette.appFont(.caption2, weight: .bold))
        }
        .foregroundStyle(AppPalette.info)
        .padding(.top, 2)
    }

    private func trendEvidencePopoverBinding(for cardID: String) -> Binding<Bool> {
        Binding(
            get: { selectedTrendEvidenceCardID == cardID },
            set: { isPresented in
                if isPresented {
                    selectedTrendEvidenceCardID = cardID
                } else if selectedTrendEvidenceCardID == cardID {
                    selectedTrendEvidenceCardID = nil
                }
            }
        )
    }

    func trendSectorExposure(_ exposureText: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "scope")
                .font(AppPalette.appFont(.caption, weight: .semibold))
                .foregroundStyle(AppPalette.info)
                .padding(.top, 2)
            Text(exposureText)
                .font(AppPalette.appFont(.footnote, weight: .semibold))
                .foregroundStyle(AppPalette.info)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            AppPalette.info.opacity(AppPalette.accentSubtle),
            in: RoundedRectangle(cornerRadius: AppPalette.controlRadius)
        )
    }

    // MARK: - Report helpers

    func trendDirectionDot(_ direction: TrendDirection) -> some View {
        Circle()
            .fill(direction.tint)
            .frame(width: 7, height: 7)
    }

    func trendDirectionBadge(_ direction: TrendDirection) -> some View {
        Text(direction.displayText)
            .font(AppPalette.appFont(.footnote, weight: .bold))
            .foregroundStyle(direction.tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(direction.tint.opacity(AppPalette.accentFill), in: Capsule())
            .overlay(Capsule().stroke(direction.tint.opacity(AppPalette.accentBorder), lineWidth: 1))
    }

    func trendConfidencePill(_ confidence: TrendConfidence) -> some View {
        HStack(spacing: 3) {
            Text("置信")
                .font(AppPalette.appFont(.footnote, weight: .medium))
                .foregroundStyle(AppPalette.muted)
            Text(confidence.label)
                .font(AppPalette.appFont(.footnote, weight: .bold))
                .foregroundStyle(AppPalette.info)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(AppPalette.info.opacity(AppPalette.accentSubtle), in: Capsule())
    }

    func trendConfidenceMeter(_ confidence: TrendConfidence) -> some View {
        TrendConfidenceMeter(confidence: confidence)
    }

    func trendCounterSignalsRow(_ signals: [String]) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(AppPalette.appFont(.caption2))
                .foregroundStyle(AppPalette.warning)
                .padding(.top, 1)
            Text("反证：\(signals.prefix(2).joined(separator: "；"))")
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.warning)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    func trendAssetList(_ assets: [TrendAssetView]) -> some View {
        if assets.isEmpty {
            trendEmptyState("暂无重点标的", detail: "模型没有给出需要单独关注的基金或股票。")
        } else {
            VStack(spacing: AppPalette.spaceS) {
                ForEach(assets.prefix(8)) { asset in
                    trendAssetCard(asset)
                }
            }
        }
    }

    func trendAssetCard(_ asset: TrendAssetView) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(asset.name)
                    .font(AppPalette.appFont(.body, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                if let code = asset.code, !code.isEmpty {
                    Text(code)
                        .font(AppPalette.appFont(.footnote, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer(minLength: 4)
                Text(asset.sector)
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(AppPalette.info)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(AppPalette.info.opacity(AppPalette.accentSubtle), in: Capsule())
            }
            Text(asset.impactText)
                .font(AppPalette.appFont(.subheadline, weight: .medium))
                .foregroundStyle(AppPalette.ink)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            Text(asset.rationale)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
            if !asset.counterSignals.isEmpty {
                trendCounterSignalsRow(asset.counterSignals)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .staticSurface(
            tint: AppPalette.info,
            fill: AppPalette.cardStrong,
            strokeOpacity: 0.18,
            activeStrokeOpacity: 0.40
        )
    }

    @ViewBuilder
    func tradeSignalDetailList(_ summary: TradeSignalSummary) -> some View {
        if summary.items.isEmpty {
            trendEmptyState("暂无观察", detail: summary.headline)
        } else {
            VStack(spacing: AppPalette.spaceM) {
                ForEach(summary.items.prefix(8)) { item in
                    tradeSignalDetailRow(item)
                }
            }
        }
    }

    func tradeSignalDetailRow(_ item: TradeSignalItem) -> some View {
        let tint = trendSignalTint(for: item)
        return HStack(alignment: .top, spacing: 0) {
            // 左侧状态色条
            RoundedRectangle(cornerRadius: AppPalette.selectionRailWidth / 2)
                .fill(AppPalette.accentGlow(tint))
                .frame(width: AppPalette.selectionRailWidth)
                .padding(.vertical, 6)

            VStack(alignment: .leading, spacing: AppPalette.spaceM - 2) {
                // 头部：图标盒 + 资产名/副标题 + 状态徽章
                HStack(alignment: .top, spacing: AppPalette.spaceS) {
                    Image(systemName: tradeSignalActionIcon(item.action))
                        .font(AppPalette.appFont(.headline, weight: .semibold))
                        .foregroundStyle(tint)
                        .accentIconStyle(tint: tint, size: 30)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.assetName)
                            .font(AppPalette.appFont(.title3, weight: .bold))
                            .foregroundStyle(AppPalette.ink)
                            .lineLimit(1)
                        tradeSignalAssetSubtitle(item)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    tradeSignalStatusBadge(item)
                }

                // 操作区：操作胶囊 + 旧分析标记
                HStack(spacing: AppPalette.spaceS) {
                    Text(item.action.displayText)
                        .font(AppPalette.appFont(.subheadline, weight: .bold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(tint.opacity(AppPalette.accentFill), in: Capsule())
                        .overlay(Capsule().stroke(tint.opacity(AppPalette.accentBorder), lineWidth: 1))

                    if item.isBasedOnStaleAnalysis {
                        Text("基于上次分析")
                            .font(AppPalette.appFont(.footnote, weight: .semibold))
                            .foregroundStyle(AppPalette.muted)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(AppPalette.muted.opacity(AppPalette.accentSubtle), in: Capsule())
                    }

                    Spacer(minLength: AppPalette.spaceS)
                    Text("置信度")
                        .font(AppPalette.appFont(.footnote, weight: .medium))
                        .foregroundStyle(AppPalette.muted)
                    Text("\(item.confidence.normalizedScore)")
                        .font(AppPalette.appFont(.subheadline, weight: .bold, design: .rounded))
                        .foregroundStyle(AppPalette.info)
                }

                // 置信度进度条
                trendConfidenceBar(item.confidence)

                // 原因说明
                Text(item.reason)
                    .font(AppPalette.appFont(.subheadline))
                    .foregroundStyle(AppPalette.muted)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)

                // 触发 / 反证条件
                VStack(alignment: .leading, spacing: 5) {
                    tradeSignalConditionLine(title: "触发", text: item.triggerSummary, tint: AppPalette.info, glyph: .filled)
                    tradeSignalConditionLine(title: "反证", text: item.invalidatingSummary, tint: AppPalette.warning, glyph: .half)
                }
            }
            .padding(.leading, AppPalette.spaceS)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .staticSurface(
                tint: tint,
                fill: AppPalette.cardStrong,
                strokeOpacity: 0.26,
                activeStrokeOpacity: 0.40
            )
        }
    }

    func tradeSignalAssetSubtitle(_ item: TradeSignalItem) -> some View {
        let parts: [String] = [item.assetCode, item.title].compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }
        if parts.isEmpty { return AnyView(EmptyView()) }
        return AnyView(
            Text(parts.joined(separator: " · "))
                .font(AppPalette.appFont(.footnote, weight: .medium))
                .foregroundStyle(AppPalette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        )
    }

    func tradeSignalStatusBadge(_ item: TradeSignalItem) -> some View {
        let tint = trendSignalTint(for: item)
        return Text(item.status.displayText)
            .font(AppPalette.appFont(.footnote, weight: .bold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(AppPalette.accentFill), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(AppPalette.accentBorder), lineWidth: 1))
    }

    func tradeSignalActionIcon(_ action: TradeSignalAction) -> String {
        switch action {
        case .watchBuy:
            return "arrow.up.circle"
        case .watchSell:
            return "arrow.down.circle"
        case .holdObserve:
            return "eye"
        case .waitForConfirmation:
            return "clock"
        case .rebalanceReview:
            return "arrow.2.squarepath"
        }
    }

    private func tradeSignalConditionLine(title: String, text: String, tint: Color, glyph: TradeSignalConditionGlyph) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                switch glyph {
                case .filled:
                    Circle().fill(tint)
                case .half:
                    Circle().fill(tint.opacity(0.5))
                        .overlay(Circle().stroke(tint, lineWidth: 1))
                }
            }
            .frame(width: 6, height: 6)
            Text(title)
                .font(AppPalette.appFont(.footnote, weight: .bold))
                .foregroundStyle(tint)
            Text(text)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private enum TradeSignalConditionGlyph { case filled, half }

    @ViewBuilder
    func trendEvidenceList(_ evidence: [TrendEvidence]) -> some View {
        if evidence.isEmpty {
            trendEmptyState("暂无外部证据", detail: "模型没有返回可核验来源，按本地上下文结果理解。")
        } else {
            VStack(spacing: AppPalette.spaceS) {
                ForEach(evidence.prefix(6)) { item in
                    trendEvidenceCard(item)
                }
            }
        }
    }

    func trendEvidenceCard(_ item: TrendEvidence) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "link")
                    .font(AppPalette.appFont(.caption, weight: .semibold))
                    .foregroundStyle(AppPalette.info)
                Text(item.sourceName)
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(AppPalette.info)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(item.publishedAt ?? item.retrievedAt)
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
            }
            if let urlText = item.url, let url = URL(string: urlText) {
                Link(item.title, destination: url)
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(item.title)
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            Text(item.summary)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .staticSurface(
            tint: AppPalette.info,
            fill: AppPalette.cardStrong,
            strokeOpacity: 0.18,
            activeStrokeOpacity: 0.38
        )
    }

    func trendWarnings(_ report: TrendAnalysisReport) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                ForEach(report.warnings) { warning in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(AppPalette.appFont(.caption))
                            .foregroundStyle(AppPalette.warning)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(warning.title)
                                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                                .foregroundStyle(AppPalette.ink)
                            Text(warning.detail)
                                .font(AppPalette.appFont(.footnote))
                                .foregroundStyle(AppPalette.muted)
                                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Text(report.disclaimer)
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    func trendBlock<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.brand)
                Text(title)
                    .font(AppPalette.appFont(.headline, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    func trendFact(_ title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(AppPalette.appFont(.footnote, weight: .medium))
                .foregroundStyle(AppPalette.muted)
            Text(value)
                .font(AppPalette.appFont(.headline, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(11)
        .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
    }

    func trendConfidenceBar(_ confidence: TrendConfidence) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(confidence.label)
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(AppPalette.muted)
                Spacer()
                Text("\(confidence.normalizedScore)")
                    .font(AppPalette.appFont(.footnote, weight: .bold, design: .rounded))
                    .foregroundStyle(AppPalette.info)
            }
            ProgressView(value: Double(confidence.normalizedScore), total: 100)
                .progressViewStyle(.linear)
                .tint(AppPalette.info)
        }
    }

    func trendSignalTint(for item: TradeSignalItem) -> Color {
        switch item.status {
        case .triggered, .upgraded:
            return AppPalette.warning
        case .approaching, .new:
            return AppPalette.info
        case .invalidated:
            return AppPalette.danger
        case .staleAnalysis:
            return AppPalette.muted
        }
    }

    func trendEmptyState(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(AppPalette.appFont(.body, weight: .bold))
                .foregroundStyle(AppPalette.ink)
            Text(detail)
                .font(AppPalette.appFont(.subheadline))
                .foregroundStyle(AppPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
    }

    var trendPanelSubtitle: String {
        if let report = model.trendReport {
            return "\(report.dataAsOf) · \(report.externalSignalStatus.displayText)"
        }
        return model.trendSettings.provider.isConfigured ? "已配置模型，等待生成" : "需要配置趋势分析模型"
    }

    var trendStateText: String {
        switch model.trendGenerationState {
        case .idle:
            return "空闲"
        case .generating:
            return "生成中"
        case .succeeded:
            return "已完成"
        case .failed:
            return "失败"
        case .rejected:
            return "已拦截"
        }
    }

    var trendStateTint: Color {
        switch model.trendGenerationState {
        case .idle:
            return AppPalette.muted
        case .generating:
            return AppPalette.info
        case .succeeded:
            return AppPalette.positive
        case .failed:
            return AppPalette.danger
        case .rejected:
            return AppPalette.warning
        }
    }

    private var trendPrivacyModeBinding: Binding<TrendPrivacyMode> {
        Binding(
            get: { model.trendPrivacyMode },
            set: { mode in
                model.trendPrivacyMode = mode
                model.trendSettings.defaultPrivacyMode = mode
                model.saveTrendAnalysisSettings()
            }
        )
    }
}

private extension TrendRiskLevel {
    var displayText: String {
        switch self {
        case .low:
            return "低风险"
        case .medium:
            return "中风险"
        case .high:
            return "高风险"
        case .unknown:
            return "风险未知"
        }
    }

    var tint: Color {
        switch self {
        case .low:
            return AppPalette.positive
        case .medium:
            return AppPalette.warning
        case .high:
            return AppPalette.danger
        case .unknown:
            return AppPalette.muted
        }
    }
}

private extension TrendExternalSignalStatus {
    var displayText: String {
        switch self {
        case .available:
            return "可用"
        case .unavailable:
            return "不可用"
        case .partial:
            return "部分可用"
        case .stale:
            return "可能过期"
        }
    }

    var tint: Color {
        switch self {
        case .available:
            return AppPalette.positive
        case .unavailable:
            return AppPalette.warning
        case .partial:
            return AppPalette.info
        case .stale:
            return AppPalette.warning
        }
    }
}

private extension TrendHorizon {
    var displayText: String {
        switch self {
        case .short:
            return "短期"
        case .medium:
            return "中期"
        case .long:
            return "长期"
        }
    }
}

private extension TrendDirection {
    var displayText: String {
        switch self {
        case .bullish:
            return "偏强"
        case .neutralPositive:
            return "中性偏强"
        case .neutral:
            return "中性"
        case .neutralNegative:
            return "中性偏弱"
        case .bearish:
            return "偏弱"
        case .uncertain:
            return "不确定"
        }
    }

    var tint: Color {
        switch self {
        case .bullish, .neutralPositive:
            return AppPalette.positive
        case .neutral:
            return AppPalette.info
        case .neutralNegative, .bearish:
            return AppPalette.warning
        case .uncertain:
            return AppPalette.muted
        }
    }
}

extension TrendActionKind {
    var displayText: String {
        switch self {
        case .watch:
            return "观察"
        case .waitForConfirmation:
            return "等待确认"
        case .observeInBatches:
            return "分批观察"
        case .pausePlan:
            return "暂停计划"
        case .considerIncrease:
            return "考虑增加"
        case .considerReduce:
            return "考虑降低"
        case .rebalanceReview:
            return "调仓复核"
        }
    }
}
