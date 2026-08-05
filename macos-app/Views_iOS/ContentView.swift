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
                }
                .tabItem {
                    Label(section.rawValue, systemImage: section.systemImage)
                }
                .badge(badge(for: section))
                .tag(section)
            }
        }
        .tint(IOSDesign.accent)
        .preferredColorScheme(model.appearance.colorScheme)
        .overlay(alignment: .top) { toastOverlay }
        // Onboarding + launch task mirror the macOS ContentView wiring so the
        // shared AppModel behaves identically on both platforms.
        .sheet(isPresented: Binding(
            get: { !hasCompletedOnboarding },
            set: { if !$0 { hasCompletedOnboarding = true } }
        )) {
            IOSOnboardingView()
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

    // MARK: - Toast(通知/错误反馈)
    //
    // macOS 用自定义 toast 条;iOS 用顶部浮层卡片显示 notice/error,
    // 4 秒后自动清空。错误用红涨色(中国股市惯例:红=警示正向),通知用品牌色。

    @ViewBuilder
    private var toastOverlay: some View {
        let message = model.errorMessage.isEmpty ? model.noticeMessage : model.errorMessage
        let isError = !model.errorMessage.isEmpty
        if !message.isEmpty {
            VStack {
                Button {
                    if isError { model.errorMessage = "" } else { model.noticeMessage = "" }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        Text(message)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(2)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(
                        isError ? AppPalette.marketGain : IOSDesign.accent,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
            }
            .task {
                // 4 秒后自动清除
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if isError {
                    if model.errorMessage == message { model.errorMessage = "" }
                } else {
                    if model.noticeMessage == message { model.noticeMessage = "" }
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

#endif
