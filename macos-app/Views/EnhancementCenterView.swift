import SwiftUI

struct EnhancementCenterView: View {
    @EnvironmentObject var model: AppModel
    @State var trendAutoAnalysisTimesDraft = ""
    @State var isTrendConfigurationExpanded = false
    @State var selectedTrendEvidenceCardID: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: AppPalette.spaceL) {
                workbenchSegmentBar
                if model.trendReport != nil {
                    HStack(spacing: 8) {
                        ShareLink(item: shareReportText()) {
                            Label("分享报告", systemImage: "square.and.arrow.up")
                                .font(AppPalette.appFont(.subheadline, weight: .semibold))
                        }
                        .buttonStyle(.appSecondary)
                        .controlSize(.small)
                    }
                }
                TrendLiveLogPanel()
                workbenchSegmentContent
            }
            .padding(18)
        }
        .onAppear {
            normalizeSelectedTab()
            normalizeDefaultSegment()
        }
    }

    private func shareReportText() -> String {
        guard let report = model.trendReport else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    // MARK: - Workbench Segments

    @ViewBuilder
    private var workbenchSegmentContent: some View {
        switch model.selectedWorkbenchSegment {
        case .today:
            todayContent
        case .tracking:
            trackingContent
        }
    }

    private var workbenchSegmentBar: some View {
        HStack(spacing: AppPalette.spaceS) {
            ForEach(WorkbenchSegment.allCases) { segment in
                workbenchSegmentButton(segment)
            }
            Spacer(minLength: AppPalette.spaceS)
            Button {
                model.startTrendAnalysis(userInitiated: true)
            } label: {
                Label(model.trendGenerationState == .generating ? "生成中…" : "立即分析", systemImage: "wand.and.stars")
                    .font(AppPalette.appFont(.body, weight: .semibold))
            }
            .buttonStyle(.appPrimary)
            .tint(AppPalette.brand)
            .disabled(!model.trendSettings.provider.isConfigured || model.trendGenerationState == .generating || model.trendProviderCapabilities?.supportsToolCalls == false)
            .help(model.trendSettings.provider.isConfigured ? "生成 AI 趋势分析" : "先在「设置」里配置模型")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func workbenchSegmentButton(_ segment: WorkbenchSegment) -> some View {
        let isSelected = model.selectedWorkbenchSegment == segment
        return Button {
            withAnimation(AppPalette.motionSpring) {
                model.selectedWorkbenchSegment = segment
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: segment.systemImage)
                    .font(AppPalette.appFont(.title3, weight: .semibold))
                Text(segment.rawValue)
                    .font(AppPalette.appFont(.headline, weight: .semibold))
            }
            .foregroundStyle(isSelected ? AppPalette.onBrand : AppPalette.ink)
            .padding(.horizontal, AppPalette.spaceL)
            .padding(.vertical, 10)
            .interactiveSurface(
                isSelected: isSelected,
                tint: AppPalette.brand,
                radius: AppPalette.controlRadius,
                fill: AppPalette.controlFill,
                hoverFill: AppPalette.cardHover,
                selectedFill: AppPalette.brand,
                strokeOpacity: AppPalette.strokeSubtle,
                activeStrokeOpacity: AppPalette.selectionStrokeOpacity,
                lift: 0.5
            )
        }
        .buttonStyle(PressResponsiveButtonStyle())
        .contentShape(RoundedRectangle(cornerRadius: AppPalette.controlRadius))
    }

    private func normalizeDefaultSegment() {
        if model.trendReport == nil, model.selectedWorkbenchSegment == .tracking {
            model.selectedWorkbenchSegment = .today
        }
    }

    private func normalizeSelectedTab() {
        if !model.selectedEnhancementTab.isVisibleInWorkbench {
            model.selectedEnhancementTab = .trend
        }
    }
}
