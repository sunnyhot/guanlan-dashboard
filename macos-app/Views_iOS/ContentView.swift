#if os(iOS)
import SwiftUI

// MARK: - iOS ContentView (skeleton)
//
// Stage-1 skeleton: a TabView shell bound to the shared `AppSection` enum and
// `AppModel`. Each tab currently shows a placeholder; stage 2/3 will replace
// the placeholders with dedicated iOS section views (Overview / Portfolio /
// Platform / Enhancement / Settings) — written from scratch for iPhone layout,
// NOT copied from Views_macOS/.
//
// Key reuse vs macOS ContentView:
//   - `AppSection.allCases` (shared enum, Core/Models/AppEnums.swift)
//   - `AppModel` (shared state, via @EnvironmentObject)
//   - `model.selectedSection` drives TabView selection
//   - launch task mirrors macOS (.task { await model.start() })

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("qieman.dashboard.hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        TabView(selection: $model.selectedSection) {
            ForEach(AppSection.allCases) { section in
                NavigationStack {
                    sectionContent(for: section)
                        .navigationTitle(section.rawValue)
                        .navigationBarTitleDisplayMode(.large)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {
                                    Task { try? await model.refreshLatest(persist: false) }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                        }
                }
                .tabItem {
                    Label(section.rawValue, systemImage: section.systemImage)
                }
                .badge(badge(for: section))
                .tag(section)
            }
        }
        .tint(AppPalette.brand)
        .preferredColorScheme(model.appearance.colorScheme)
        // Onboarding + launch task mirror the macOS ContentView wiring so the
        // shared AppModel behaves identically on both platforms.
        .sheet(isPresented: Binding(
            get: { !hasCompletedOnboarding },
            set: { if !$0 { hasCompletedOnboarding = true } }
        )) {
            // TODO(stage-3): iOS-native onboarding. macOS onboarding lives in
            // Views_macOS/OnboardingView.swift and assumes a 420pt-wide sheet.
            OnboardingPlaceholder()
        }
        .task {
            await model.start()
            await model.runDailyTrendAnalysisIfNeeded()
            model.refreshDataForSectionIfNeeded(model.selectedSection)
        }
        .onChange(of: model.selectedSection) { _, section in
            model.refreshDataForSectionIfNeeded(section)
        }
    }

    // MARK: - Placeholders (replaced by real iOS section views in stage 2/3)

    @ViewBuilder
    private func sectionContent(for section: AppSection) -> some View {
        switch section {
        case .overview:
            OverviewSectionView()
        case .portfolio:
            PortfolioSectionView()
        case .platform:
            PlatformSectionView()
        case .enhancement:
            EnhancementSectionView()
        case .settings:
            SettingsSectionView()
        }
    }

    private func badge(for section: AppSection) -> Int {
        switch section {
        case .portfolio: return model.pendingTrades.count
        case .enhancement: return model.trendTrackingItems.count
        default: return 0
        }
    }
}

// MARK: - Onboarding Placeholder

private struct OnboardingPlaceholder: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: AppPalette.spaceL) {
                Spacer()
                Image(systemName: "rectangle.grid.2x2")
                    .font(.system(size: 60))
                    .foregroundStyle(AppPalette.brand)
                Text("且慢主理人")
                    .font(.largeTitle.bold())
                Text("iOS 版欢迎你。完整的引导流程将在后续阶段补全。")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AppPalette.muted)
                    .padding(.horizontal, 32)
                Spacer()
                Button("开始使用") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.bottom, 32)
            }
            .padding()
        }
    }
}
#endif
