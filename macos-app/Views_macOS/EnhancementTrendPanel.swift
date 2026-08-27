import SwiftUI

// MARK: - Workbench Segments

extension EnhancementCenterView {

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
        let evidenceDetail = trendEvidenceDetail(
            claimEvidence: outlook.claimEvidence,
            referencedEvidenceIDs: outlook.evidenceIDs
        )
        let selection = TrendEvidenceDetailSelection(
            id: "market:\(outlook.id)",
            subjectTitle: outlook.name,
            rationale: outlook.rationale,
            dataAsOf: model.trendReport?.dataAsOf ?? "",
            detail: evidenceDetail
        )
        return Button {
            selectedTrendEvidenceDetail = selection
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    trendDirectionDot(outlook.direction)
                    Text(outlook.name)
                        .font(AppPalette.appFont(.body, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(outlook.categoryDisplayName)
                        .font(AppPalette.appFont(.caption, weight: .semibold))
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(1)
                }
                VerdictCard(
                    direction: outlook.direction,
                    confidence: outlook.confidence,
                    rationale: outlook.rationale,
                    counterSignals: outlook.counterSignals,
                    evidenceCount: evidenceDetail.items.count
                )
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
        .contextMenu {
            Button("查看 Agent 判断依据") {
                selectedTrendEvidenceDetail = selection
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
                            in: RoundedRectangle(cornerRadius: AppPalette.controlRadius)
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
        TintedCapsuleBadge(
            text: riskLevel.displayText,
            tint: riskLevel.tint,
            style: .soft,
            font: AppPalette.appFont(.subheadline, weight: .bold, design: .rounded),
            horizontalPadding: 8,
            verticalPadding: 4,
            softFillOpacity: AppPalette.accentOnFill,
            softStrokeOpacity: nil
        )
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
            }
            // W4.4:方向/把握/结论/理由/作废条件统一走结论卡组件。
            VerdictCard(
                direction: horizon.direction,
                confidence: horizon.confidence,
                rationale: horizon.rationale,
                counterSignals: horizon.counterSignals
            )
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
        let evidenceDetail = trendEvidenceDetail(
            claimEvidence: sector.claimEvidence,
            referencedEvidenceIDs: sector.evidenceIDs
        )
        let selection = TrendEvidenceDetailSelection(
            id: "sector:\(sector.id)",
            subjectTitle: sector.name,
            rationale: sector.rationale,
            dataAsOf: model.trendReport?.dataAsOf ?? "",
            detail: evidenceDetail
        )
        return Button {
            selectedTrendEvidenceDetail = selection
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    trendDirectionDot(sector.direction)
                    Text(sector.name)
                        .font(AppPalette.appFont(.body, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                }
                trendSectorExposure(sector.exposureText)
                VerdictCard(
                    direction: sector.direction,
                    confidence: sector.confidence,
                    rationale: sector.rationale,
                    counterSignals: sector.counterSignals,
                    evidenceCount: evidenceDetail.items.count
                )
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
        .contextMenu {
            Button("查看 Agent 判断依据") {
                selectedTrendEvidenceDetail = selection
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
        TintedCapsuleBadge(
            text: direction.displayText,
            tint: direction.tint,
            style: .soft,
            font: AppPalette.appFont(.footnote, weight: .bold),
            horizontalPadding: 7,
            verticalPadding: 3
        )
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

// TrendDirection / TrendHorizon 的展示映射已迁至 VerdictCard.swift 共用。

