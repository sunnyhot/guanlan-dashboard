#if canImport(AppKit)
import AppKit
#endif
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @AppStorage("qieman.dashboard.hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarNavigation
                .navigationSplitViewColumnWidth(min: 200, ideal: 232)
                .modifier(SidebarFloatingCompatModifier())
        } detail: {
            mainContent
                .background(
                    ZStack {
                        AppPalette.canvasGradient
                        // Subtle material overlay for depth on macOS 14+
                        MaterialPanel(material: .underWindowBackground, blendingMode: .behindWindow)
                            .opacity(0.30)
                    }
                )
        }
        .frame(minWidth: 860, idealWidth: 1200, minHeight: 600)
        .buttonStyle(.appSecondary)
        .preferredColorScheme(model.appearance.colorScheme)
        .respectsReducedMotion()
        .onReceive(NotificationCenter.default.publisher(for: .qiemanToggleSidebar)) { _ in
            withAnimation(AppPalette.motionStandard) {
                switch columnVisibility {
                case .all: columnVisibility = .detailOnly
                default: columnVisibility = .all
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { !hasCompletedOnboarding },
            set: { if !$0 { hasCompletedOnboarding = true } }
        )) {
            OnboardingView()
        }
        .sheet(isPresented: $model.isPresentingCommandPalette) {
            CommandPaletteView()
                .environmentObject(model)
        }
        .task {
            await model.start()
            await model.runDailyTrendAnalysisIfNeeded()
            model.refreshDataForSectionIfNeeded(model.selectedSection)
        }
        .onChange(of: model.selectedSection) { _, section in
            model.refreshDataForSectionIfNeeded(section)
        }
        .sheet(isPresented: $model.isPresentingUpdateSheet) {
            if let update = model.availableUpdate {
                AppUpdateSheet(
                    release: update,
                    isInstalling: model.isInstallingUpdate,
                    installProgress: model.updateInstallProgress,
                    downloadFraction: model.updateDownloadFraction,
                    onInstall: {
                        Task { await model.downloadAndInstallAvailableUpdate() }
                    },
                    onReleasePage: {
                        model.openAvailableUpdateReleasePage()
                        model.dismissUpdateSheet()
                    },
                    onDismiss: {
                        model.dismissUpdateSheet()
                    }
                )
            }
        }
    }

    private var sidebarNavigation: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: AppPalette.spaceXS + 2) {
                ForEach(AppSection.allCases) { section in
                    SidebarSectionButton(
                        section: section,
                        isSelected: model.selectedSection == section,
                        badgeCount: sidebarBadge(for: section)
                    ) {
                        if model.selectedSection != section {
                            model.selectedSection = section
                        }
                    }
                }
            }
            .padding(.horizontal, AppPalette.spaceM)
            .padding(.top, 34)
            .padding(.bottom, AppPalette.spaceL)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(spacing: 0) {
            toolbar
            notifications
            detailPanel
        }
    }

    private var toolbar: some View {
        VStack(spacing: 0) {
            VStack(spacing: AppPalette.spaceM) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: AppPalette.spaceL) {
                        toolbarTitleBlock
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                toggleMainWindowZoom()
                            }
                        Spacer(minLength: AppPalette.spaceM)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                toggleMainWindowZoom()
                            }
                        toolbarActionRow
                    }

                    VStack(alignment: .leading, spacing: AppPalette.spaceM) {
                        toolbarTitleBlock
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                toggleMainWindowZoom()
                            }
                        toolbarActionRow
                    }
                }
            }
            .padding(.horizontal, AppPalette.toolbarPaddingH)
            .padding(.top, AppPalette.toolbarPaddingTop)
            .padding(.bottom, AppPalette.toolbarPaddingBottom)
            .background(
                Group {
                    if reduceTransparency {
                        AppPalette.surface
                    } else {
                        MaterialPanel(material: .windowBackground, blendingMode: .withinWindow)
                            .opacity(AppPalette.bgToolbar)
                    }
                }
            )

            Divider()
        }
    }


    private var toolbarTitleBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.selectedSection.rawValue)
                .font(AppPalette.appFont(.title2, weight: .bold))
                .foregroundStyle(colorSchemeContrast == .increased ? .primary : AppPalette.ink)
        }
    }

    private var toolbarActionRow: some View {
        HStack(spacing: 10) {
            Button {
                Task { try? await model.refreshLatest(persist: false) }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
                    .font(AppPalette.appFont(.headline, weight: .semibold))
            }
            .buttonStyle(.appPrimary)
            .controlSize(.regular)
            .disabled(model.isRefreshing || (!model.hasLiveService && !model.canRefreshWithoutLiveService))
        }
    }


    /// Double-click the toolbar title area to zoom (maximize/restore) the main window.
    /// Only targets the app's tracked main window — never a sheet, popover, or NSPanel.
    /// iOS has no window-zoom concept; this is a no-op there.
    private func toggleMainWindowZoom() {
        #if os(macOS)
        // Prefer the AppDelegate's tracked mainWindow reference.
        if let delegate = NSApplication.shared.delegate as? QiemanApplicationDelegate,
           let mainWin = delegate.mainWindowForZoom {
            delegate.toggleMainWindowZoom(mainWin)
            return
        }
        // Fallback: find the first suitable window, excluding panels/sheets.
        guard let targetWindow = NSApplication.shared.windows.first(where: { window in
            window.isVisible
                && window.canBecomeMain
                && !(window is NSPanel)
                && !window.isSheet
                && window.styleMask.contains(.resizable)
        }) else { return }
        targetWindow.performZoom(nil)
        #endif
    }

    @ViewBuilder
    private var notifications: some View {
        if !model.noticeMessage.isEmpty || !model.errorMessage.isEmpty {
            VStack(spacing: AppPalette.spaceXS) {
                if !model.noticeMessage.isEmpty {
                    ToastBar(
                        text: model.noticeMessage,
                        tint: AppPalette.positive,
                        onDismiss: { model.noticeMessage = "" }
                    )
                        .task(id: model.noticeMessage) {
                            await dismissNoticeToast(model.noticeMessage, after: 4.5)
                        }
                }
                if !model.errorMessage.isEmpty {
                    ToastBar(
                        text: model.errorMessage,
                        tint: AppPalette.danger,
                        actionTitle: "复制",
                        action: { copyErrorMessage() },
                        onDismiss: { model.errorMessage = "" }
                    )
                }
            }
            .padding(.horizontal, AppPalette.contentPadding)
            .padding(.top, AppPalette.spaceS)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func dismissNoticeToast(_ message: String, after seconds: Double) async {
        guard !message.isEmpty else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await MainActor.run {
            guard model.noticeMessage == message else { return }
            withAnimation(AppPalette.motionStandard) {
                model.noticeMessage = ""
            }
        }
    }

    private func copyErrorMessage() {
        PasteboardHelper.copy(model.errorMessage)
    }

    private func sidebarBadge(for section: AppSection) -> Int {
        switch section {
        case .portfolio: return model.pendingTrades.count
        case .enhancement: return model.trendTrackingItems.count
        default: return 0
        }
    }

    @ViewBuilder
    private var detailPanel: some View {
        switch model.selectedSection {
        case .overview:
            OverviewSectionView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .portfolio:
            PortfolioSectionView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .settings:
            SettingsSectionView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .platform:
            PlatformActivitySectionView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .enhancement:
            EnhancementCenterView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SidebarSectionButton: View {
    @EnvironmentObject private var model: AppModel
    let section: AppSection
    let isSelected: Bool
    var badgeCount: Int = 0
    let action: () -> Void

    @State private var isHovering = false

    private var activeTint: Color {
        isSelected ? AppPalette.brand : (isHovering ? AppPalette.ink : AppPalette.muted)
    }

    private var rowFill: Color {
        if isSelected {
            return AppPalette.selectionFill.opacity(0.78)
        }
        if isHovering {
            return AppPalette.cardHover.opacity(0.72)
        }
        return .clear
    }

    private var strokeColor: Color {
        isSelected
            ? AppPalette.selectionStroke.opacity(AppPalette.selectionStrokeOpacity)
            : AppPalette.line.opacity(isHovering ? AppPalette.borderMedium : 0)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppPalette.spaceS) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isSelected ? AppPalette.brand : .clear)
                    .frame(width: AppPalette.selectionRailWidth, height: 24)

                Image(systemName: section.systemImage)
                    .font(AppPalette.appFont(.headline, weight: .semibold))
                    .foregroundStyle(activeTint)
                    .frame(width: 26, height: 26)
                    .background(
                        (isSelected ? AppPalette.brand.opacity(0.13) : activeTint.opacity(isHovering ? 0.08 : 0.05)),
                        in: RoundedRectangle(cornerRadius: AppPalette.iconBoxRadius)
                    )

                Text(section.rawValue)
                    .font(AppPalette.appFont(.headline, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? AppPalette.ink : activeTint)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(AppPalette.appFont(.footnote, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(AppPalette.brand, in: Capsule())
                }
            }
            .padding(.horizontal, AppPalette.spaceS)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowFill, in: RoundedRectangle(cornerRadius: AppPalette.sidebarRowRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppPalette.sidebarRowRadius)
                    .stroke(strokeColor, lineWidth: 1)
            )
            .shadow(
                color: AppPalette.selectionGlow.opacity(isSelected ? AppPalette.selectionGlowOpacity : 0),
                radius: isSelected ? AppPalette.selectionGlowRadius : 0,
                x: 0,
                y: isSelected ? 4 : 0
            )
            .offset(y: isHovering && !isSelected ? -AppPalette.hoverLift : 0)
            .contentShape(RoundedRectangle(cornerRadius: AppPalette.sidebarRowRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            Button("前往「\(section.rawValue)」") {
                if model.selectedSection != section {
                    model.selectedSection = section
                }
            }
            Divider()
            Button("刷新数据") {
                Task { try? await model.refreshLatest(persist: false) }
            }
            .keyboardShortcut("r", modifiers: .command)
            if section == .enhancement {
                Divider()
                Button("生成趋势分析") {
                    model.startTrendAnalysis(userInitiated: true)
                }
                Button("快捷操作") {
                    model.isPresentingCommandPalette = true
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }
        .animation(AppPalette.motionStandard, value: isHovering)
        .animation(AppPalette.motionSpring, value: isSelected)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

private struct AppUpdateSheet: View {
    let release: AppUpdateRelease
    let isInstalling: Bool
    let installProgress: String
    let downloadFraction: Double
    let onInstall: () -> Void
    let onReleasePage: () -> Void
    let onDismiss: () -> Void

    private var releaseNoteItems: [String] {
        let items = AppUpdateReleaseNotesFormatter.items(from: release.notes)
        return items.isEmpty ? ["这个版本没有填写更新说明。"] : items
    }

    private var publishedText: String? {
        guard let publishedAt = release.publishedAt else { return nil }
        return Self.releaseDateFormatter.string(from: publishedAt)
    }

    private static let releaseDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(AppPalette.appFont(.largeTitle, weight: .semibold))
                    .foregroundStyle(AppPalette.brand)
                    .frame(width: 48, height: 48)
                    .background(AppPalette.brandSoft, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))

                VStack(alignment: .leading, spacing: AppPalette.spaceS - 2) {
                    Text("发现新版本")
                        .font(AppPalette.appFont(.headline, weight: .semibold))
                        .foregroundStyle(AppPalette.positive)
                    Text(release.displayTitle)
                        .font(AppPalette.appFont(.largeTitle, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text("当前 \(release.currentVersion) · 最新 \(release.version)")
                        .font(AppPalette.appFont(.body, weight: .medium))
                        .foregroundStyle(AppPalette.muted)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: AppPalette.spaceS) {
                    if let asset = release.asset {
                        ToolbarBadge(title: asset.name, tint: AppPalette.info)
                        ToolbarBadge(title: asset.sizeText, tint: AppPalette.muted)
                    } else {
                        ToolbarBadge(title: "未找到 zip 资产", tint: AppPalette.warning)
                    }

                    if let publishedText {
                        ToolbarBadge(title: publishedText, tint: AppPalette.muted)
                    }
                }

                VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                    Text("本次更新")
                        .font(AppPalette.appFont(.title3, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)

                    ScrollView {
                        VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                            ForEach(Array(releaseNoteItems.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .firstTextBaseline, spacing: AppPalette.spaceS) {
                                    Text("•")
                                        .font(AppPalette.appFont(.headline, weight: .semibold))
                                        .foregroundStyle(AppPalette.muted)
                                    Text(item)
                                        .font(AppPalette.appFont(.headline))
                                        .foregroundStyle(AppPalette.ink)
                                        .lineSpacing(AppPalette.spaceXS)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
                .padding(AppPalette.spaceM)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))

                if isInstalling {
                    VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                        if downloadFraction > 0 {
                            // Determinate progress bar during download
                            ProgressView(value: downloadFraction, total: 1.0)
                                .progressViewStyle(.linear)
                                .tint(AppPalette.brand)
                        } else {
                            // Indeterminate spinner for non-download phases (extract, verify, install)
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(installProgress.isEmpty ? "正在准备更新…" : installProgress)
                            .font(AppPalette.appFont(.body, weight: .medium))
                            .foregroundStyle(AppPalette.muted)
                    }
                    .padding(.horizontal, 2)
                }
            }

            HStack {
                Button("稍后") {
                    onDismiss()
                }
                .buttonStyle(.appText)
                .keyboardShortcut(.cancelAction)
                .disabled(isInstalling)

                Spacer()

                Button("查看发布页") {
                    onReleasePage()
                }
                .buttonStyle(.appSecondary)
                .disabled(isInstalling)

                Button {
                    onInstall()
                } label: {
                    Label(isInstalling ? "安装中…" : "下载并重启安装", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.appPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(isInstalling || release.asset == nil)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(AppPalette.paper)
    }
}

// MARK: - Sidebar Floating Compatibility Modifier

/// Applies a floating visual effect to the sidebar on all macOS versions.
/// Uses a translucent material background, rounded corners, padding, and
/// a subtle shadow to create the "hovering" look.
struct SidebarFloatingCompatModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .padding(.vertical, AppPalette.spaceS)
            .padding(.leading, AppPalette.spaceS)
            .padding(.trailing, AppPalette.spaceXS)
            .background(
                Group {
                    if reduceTransparency {
                        AppPalette.surface
                            .ignoresSafeArea()
                    } else {
                        MaterialPanel(material: .sidebar, blendingMode: .behindWindow)
                            .ignoresSafeArea()
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: AppPalette.cardRadius))
            .shadow(color: AppPalette.sidebarShadowColor, radius: AppPalette.sidebarShadowRadius, x: AppPalette.sidebarShadowX, y: 0)
    }
}

// MARK: - NSVisualEffectView Wrapper (Legacy Alias)

/// Wraps `NSVisualEffectView` to provide a blurred material backdrop.
/// Kept for backward compatibility; new code should use `MaterialPanel` instead.
#if canImport(AppKit)
struct VisualEffectBlurView: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}
#endif
