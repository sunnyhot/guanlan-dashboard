#if os(iOS)
import SwiftUI

// MARK: - iOS AI 研判页
//
// 三段切换：研判 / 跟踪 / 证据。
// 复用 trendDashboardSummary、model.trendTrackingItems、model.trendReport?.evidence。
// 跟踪清单、证据列表分别见 IOSTrendTrackingListView / IOSTrendEvidenceListView。

struct EnhancementSectionView: View {
    @EnvironmentObject private var model: AppModel
    @State private var segment: ResearchSegment = .report

    private enum ResearchSegment: String, CaseIterable, Identifiable {
        case report = "研判"
        case tracking = "跟踪"
        case evidence = "证据"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("", selection: $segment) {
                    ForEach(ResearchSegment.allCases) { seg in
                        Text(seg.rawValue).tag(seg)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 2)

                switch segment {
                case .report:  reportContent
                case .tracking: trackingContent
                case .evidence: evidenceContent
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            try? await model.refreshLatest(updateNotice: false)
        }
    }

    // MARK: 研判

    @ViewBuilder
    private var reportContent: some View {
        let summary = model.trendDashboardSummary
        statusCard(summary)
        // 投资智能(Slice 1):集中度决策事项。gate 在 InvestmentIntelligence.enabled。
        if InvestmentIntelligence.enabled {
            IOSInvestmentIntelligencePanel()
        }
        if !summary.horizons.isEmpty {
            horizonsCard(summary)
        }
        if !summary.sectors.isEmpty {
            sectorsCard(summary)
        }
    }

    // MARK: 跟踪

    @ViewBuilder
    private var trackingContent: some View {
        IOSTrendTrackingListView()
    }

    // MARK: 证据

    @ViewBuilder
    private var evidenceContent: some View {
        IOSTrendEvidenceListView(evidence: model.trendReport?.evidence ?? [])
    }

    // MARK: 研判卡片

    private func statusCard(_ summary: TrendDashboardSummary) -> some View {
        IOSSectionCard(title: "AI 趋势研判", subtitle: summary.dataAsOf ?? "尚未生成", icon: "sparkles") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    IOSTintedBadge(text: summary.stateText, tone: .neutral)
                    if summary.riskLevel != nil, !summary.riskText.isEmpty {
                        IOSTintedBadge(text: summary.riskText, tone: trendToneToStat(summary.riskTone))
                    }
                    Spacer()
                }
                Text(summary.headline)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !summary.detail.isEmpty {
                    Text(summary.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let generated = summary.generatedAt {
                    Text("生成于 \(generated)")
                        .font(.system(size: 11))
                        .foregroundStyle(AppPalette.muted)
                }
                actionButtons(summary)
            }
        }
    }

    private func actionButtons(_ summary: TrendDashboardSummary) -> some View {
        VStack(spacing: 8) {
            Button {
                handleTrendAction(summary.primaryAction)
            } label: {
                Label(summary.primaryAction.title, systemImage: summary.primaryAction.systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(trendToneColor(summary.primaryAction.tone))
            .disabled(summary.primaryAction.isDisabled)

            if let secondary = summary.secondaryAction {
                Button {
                    handleTrendAction(secondary)
                } label: {
                    Label(secondary.title, systemImage: secondary.systemImage)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(trendToneColor(secondary.tone))
                .disabled(secondary.isDisabled)
            }
        }
    }

    private func horizonsCard(_ summary: TrendDashboardSummary) -> some View {
        IOSSectionCard(title: "周期研判", icon: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(summary.horizons) { horizon in
                    trendRow(
                        title: horizon.title,
                        direction: horizon.directionText,
                        rationale: horizon.rationale,
                        confidence: horizon.confidence,
                        exposureText: nil,
                        tone: horizon.tone
                    )
                }
            }
        }
    }

    private func sectorsCard(_ summary: TrendDashboardSummary) -> some View {
        IOSSectionCard(title: "板块研判", icon: "chart.pie.fill") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(summary.sectors) { sector in
                    trendRow(
                        title: sector.name,
                        direction: sector.directionText,
                        rationale: sector.rationale,
                        confidence: sector.confidence,
                        exposureText: sector.exposureText,
                        tone: sector.tone
                    )
                }
            }
        }
    }

    /// 周期/板块研判行：色条 + 标题 + 方向 + 暴露占比 + 置信度 + 理由。
    private func trendRow(
        title: String,
        direction: String,
        rationale: String,
        confidence: TrendConfidence,
        exposureText: String?,
        tone: TrendDashboardTone
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(trendToneColor(tone))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppPalette.ink)
                    if let exposureText, !exposureText.isEmpty {
                        Text(exposureText)
                            .font(IOSDesign.monoNumber(10, weight: .regular))
                            .foregroundStyle(AppPalette.muted)
                    }
                    Spacer()
                    Text(direction)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(trendToneColor(tone))
                }
                confidenceMeter(confidence)
                if !rationale.isEmpty {
                    Text(rationale)
                        .font(.system(size: 12))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// 置信度细条：左标题右分数 + 进度胶囊。
    private func confidenceMeter(_ confidence: TrendConfidence) -> some View {
        HStack(spacing: IOSDesign.spaceS) {
            Text("置信度 \(confidence.label)")
                .font(IOSDesign.sansBody(10))
                .foregroundStyle(AppPalette.muted)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(IOSDesign.ink.opacity(0.08))
                    Capsule()
                        .fill(trendToneColor(.info))
                        .frame(width: geo.size.width * CGFloat(max(0, min(confidence.score, 100))) / 100)
                }
            }
            .frame(height: 3)
            Text("\(confidence.score)")
                .font(IOSDesign.monoNumber(10, weight: .medium))
                .foregroundStyle(AppPalette.muted)
        }
    }

    private func handleTrendAction(_ action: TrendDashboardAction) {
        guard !action.isDisabled else { return }
        switch action.kind {
        case .configure:
            model.selectedSection = .settings
        case .generate, .refresh:
            Task { await model.startTrendAnalysis(userInitiated: true) }
        case .openReport, .wait:
            break
        }
    }
}

// MARK: - TrendDashboardTone → 颜色(iOS 版)

func trendToneColor(_ tone: TrendDashboardTone) -> Color {
    switch tone {
    case .brand: return AppPalette.brand
    case .positive: return AppPalette.marketGain
    case .info: return AppPalette.info
    case .warning: return AppPalette.warning
    case .danger: return AppPalette.marketLoss
    case .muted: return AppPalette.muted
    }
}

func trendToneToStat(_ tone: TrendDashboardTone) -> IOSStatTile.StatTone {
    switch tone {
    case .positive: return .positive
    case .danger: return .negative
    default: return .neutral
    }
}
#endif
