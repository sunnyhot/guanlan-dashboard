import SwiftUI

struct EnhancementCenterView: View {
    @EnvironmentObject var model: AppModel
    @State var trendAutoAnalysisTimesDraft = ""
    @State var isTrendConfigurationExpanded = false
    @State var selectedTrendEvidenceDetail: TrendEvidenceDetailSelection?
    @State private var orderedTabs: [WorkbenchSegment] = WorkbenchSegment.allCases
    private let tabOrderStore = TabOrderStore(namespace: "workbench")

    var body: some View {
        VStack(spacing: 0) {
            workbenchSegmentBar

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: AppPalette.spaceL) {
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
            .scrollIndicators(.hidden)
        }
        .onAppear {
            orderedTabs = tabOrderStore.ordered(WorkbenchSegment.self, id: { $0.rawValue })
            normalizeDefaultSegment()
        }
        .sheet(item: $selectedTrendEvidenceDetail) { selection in
            TrendEvidenceDetailSheet(selection: selection)
        }
    }

    private var trendAnalysisButton: some View {
        Button {
            model.startTrendAnalysis(userInitiated: true)
        } label: {
            Label(model.trendGenerationState == .generating ? "生成中…" : "立即分析", systemImage: "wand.and.stars")
                .font(AppPalette.appFont(.body, weight: .semibold))
        }
        .buttonStyle(.appPrimary)
        .tint(AppPalette.brand)
        .disabled(
            !model.trendSettings.provider.isConfigured
                || model.trendGenerationState == .generating
                || model.trendProviderCapabilities?.supportsToolCalls == false
        )
        .help(model.trendSettings.provider.isConfigured ? "生成 AI 趋势分析" : "先在「设置」里配置模型")
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
        ModuleTabBar(
            items: orderedTabs,
            selection: $model.selectedWorkbenchSegment,
            onReorder: { from, to in
                var arranged = orderedTabs
                arranged.move(fromOffsets: from, toOffset: to)
                tabOrderStore.save(arranged.map { $0.rawValue })
                orderedTabs = arranged
            },
            title: { $0.rawValue },
            systemImage: { $0.systemImage },
            trailingContent: {
                trendAnalysisButton
            }
        )
    }

    private func normalizeDefaultSegment() {
        if model.trendReport == nil, model.selectedWorkbenchSegment == .tracking {
            model.selectedWorkbenchSegment = .today
        }
    }

}
