#if os(macOS)
import AppKit
import Combine
import SwiftUI
import UserNotifications

private enum AppSceneIdentifier {
    static let mainWindow = "main-window"
}

enum AppLaunchPresentationPolicy {
    static func initialActivationPolicy() -> NSApplication.ActivationPolicy {
        // Keep the first interactive launch regular so SwiftUI can create the
        // initial WindowGroup even when the saved preference hides the Dock icon.
        .regular
    }

    static func configuredActivationPolicy(showsInDock: Bool) -> NSApplication.ActivationPolicy {
        showsInDock ? .regular : .accessory
    }
}

enum AppLaunchWindowPolicy {
    static let shouldCreateImmediateManualWindowOnLaunch = false
}

enum AppMainWindowTrackingPolicy {
    static func shouldDiscardPreviousTrackedWindow(
        hasPreviousTrackedWindow: Bool,
        isSameWindow: Bool,
        previousWindowIsVisible _: Bool
    ) -> Bool {
        // Scene attachment can observe a previous main window before AppKit has
        // ordered it visible. Any different tracked main window is a duplicate.
        hasPreviousTrackedWindow && !isSameWindow
    }
}

enum AppMainWindowRevealPolicy {
    /// Grace period after launch during which an early reveal request (login
    /// reopen, notification-tap launch) waits for the SwiftUI Window scene
    /// instead of creating a manual fallback window that would duplicate it.
    static let launchGraceSeconds: TimeInterval = 2.0

    static func shouldWaitForSceneWindow(hasSceneOpener: Bool, launchGraceElapsed: Bool) -> Bool {
        !hasSceneOpener && !launchGraceElapsed
    }
}

enum AppMainWindowDuplicatePolicy {
    /// Picks the window to keep when more than one main window exists. The
    /// SwiftUI scene window wins (it is the long-lived, reopen-capable window);
    /// otherwise the tracked window; otherwise the first candidate.
    static func windowToKeep(
        candidates: [NSWindow],
        trackedWindow: NSWindow?,
        isSceneWindow: (NSWindow) -> Bool
    ) -> NSWindow? {
        guard !candidates.isEmpty else { return nil }
        if candidates.count > 1, let sceneWindow = candidates.first(where: isSceneWindow) {
            return sceneWindow
        }
        if let trackedWindow, candidates.contains(trackedWindow) {
            return trackedWindow
        }
        return candidates.first
    }
}

@MainActor
final class QiemanApplicationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("QiemanDashboard.mainWindow")

    private enum MenuBarRenderState: Equatable {
        case fallback(title: String)
        case ticker(entries: [MenuBarTickerEntry], appearance: MenuBarTickerAppearance, page: Int, totalPages: Int, barHeight: CGFloat)
    }

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var model: AppModel?
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitor: Any?
    /// Local monitor for double-click events in the titlebar/toolbar area.
    private var titlebarDoubleClickMonitor: Any?
    private var didConfigure = false
    private var carouselPageIndex = 0
    private var carouselTimer: Timer?
    private var lastEntryIDs: [String] = []
    private var lastMenuBarRenderState: MenuBarRenderState?
    private var didFinishLaunching = false
    private var openMainWindowScene: (() -> Void)?
    /// Reveal requests that arrived before the SwiftUI Window scene attached;
    /// flushed once the scene opener registers or the scene window is tracked.
    private var pendingMainWindowReveal = false
    private var pendingRevealDeadlineScheduled = false
    /// Set when applicationDidFinishLaunching runs; gates the manual-window
    /// fallback so early reveal requests wait out the launch grace period.
    var finishLaunchingDate: Date?
    /// Retains a reference to the main window so it can be re-shown after closing.
    /// Set by both the SwiftUI WindowGroup (onAppear) and createMainWindow().
    fileprivate(set) var mainWindow: NSWindow?
    private var mainWindowRestoreFrames: [ObjectIdentifier: NSRect] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let telemetryStart = PerformanceTelemetry.start()
        defer {
            PerformanceTelemetry.record(
                "app.delegate.finishLaunching",
                startedAt: telemetryStart
            )
        }

        UNUserNotificationCenter.current().delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.image = nil
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 392, height: 720)
        popover.behavior = .transient

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, self.popover.isShown {
                if event.window != self.popover.contentViewController?.view.window {
                    self.popover.performClose(nil)
                }
            }
        }

        NSApplication.shared.setActivationPolicy(
            AppLaunchPresentationPolicy.initialActivationPolicy()
        )

        // Install local monitor to handle double-click in the titlebar/toolbar area.
        // SwiftUI's .onTapGesture cannot reach the native macOS titlebar region when
        // using hiddenTitleBar + titlebarAppearsTransparent, so we intercept at AppKit level.
        titlebarDoubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleTitlebarDoubleClick(event) ?? event
        }

        didFinishLaunching = true
        finishLaunchingDate = Date()
        configure(model: QiemanAppModelHolder.shared)
        if AppLaunchWindowPolicy.shouldCreateImmediateManualWindowOnLaunch {
            showMainWindow()
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func configure(model: AppModel) {
        self.model = model
        guard didFinishLaunching else { return }
        guard !didConfigure else { return }
        didConfigure = true
        let telemetryStart = PerformanceTelemetry.start()
        defer {
            PerformanceTelemetry.record(
                "app.delegate.configure",
                startedAt: telemetryStart
            )
        }
        Task { @MainActor in
            model.appDelegate = self
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            NSApplication.shared.setActivationPolicy(
                AppLaunchPresentationPolicy.configuredActivationPolicy(showsInDock: model.showsInDock)
            )
            let view = MenuBarPortfolioView()
                .environmentObject(model)
            self.popover.contentViewController = NSHostingController(rootView: view)
            self.updateTitle()

            model.objectWillChange
                .receive(on: RunLoop.main)
                .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.updateTitle()
                    }
                }
                .store(in: &self.cancellables)

            // Keep the window appearance as the single source of truth for both
            // SwiftUI's colorScheme environment and AppPalette's dynamic NSColor values.
            NotificationCenter.default.publisher(for: .qiemanAppearanceDidChange)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.syncWindowAppearances()
                    }
                }
                .store(in: &self.cancellables)
        }

    }

    /// Apply the current appearance setting at each window boundary.
    /// Descendant views must inherit from their window; retaining explicit
    /// NSAppearance overrides there leaves stale dark colors after switching
    /// back to the light system appearance.
    @MainActor func syncWindowAppearances(in windows: [NSWindow]? = nil) {
        guard let model else { return }
        let target = model.appearance.nsAppearance
        for window in windows ?? NSApplication.shared.windows {
            window.appearance = target
            clearExplicitAppearancesRecursively(in: window.contentView)
        }

        // The popover can be closed and therefore absent from NSApplication.windows.
        // Its root hosting view acts as the appearance boundary until it is shown.
        if windows == nil, let popoverVC = popover?.contentViewController {
            clearExplicitAppearancesRecursively(in: popoverVC.view)
            popoverVC.view.appearance = target
        }
    }

    /// Remove stale per-view overrides so the complete hierarchy follows its window.
    @MainActor private func clearExplicitAppearancesRecursively(in view: NSView?) {
        guard let view else { return }
        view.appearance = nil
        for subview in view.subviews {
            clearExplicitAppearancesRecursively(in: subview)
        }
    }

    @MainActor private func updateTitle() {
        guard let model, let button = statusItem.button else { return }
        let telemetryStart = PerformanceTelemetry.start()
        var renderedEntryCount = 0
        defer {
            PerformanceTelemetry.record(
                "menuBar.title.render",
                startedAt: telemetryStart,
                metadata: [
                    "entryCount": "\(renderedEntryCount)",
                    "enabled": "\(model.menuBarTickerSettings.isEnabled)"
                ]
            )
        }
        let allEntries = model.menuBarTickerAllCandidates
        let settings = model.menuBarTickerSettings.normalized()
        let appearance = settings.appearance.normalized()
        let pageSize = settings.maxVisibleItems

        // Reset page if entries changed
        let currentIDs = allEntries.map(\.id)
        if currentIDs != lastEntryIDs {
            lastEntryIDs = currentIDs
            carouselPageIndex = 0
            lastMenuBarRenderState = nil
        }

        let barHeight = NSStatusBar.system.thickness

        if allEntries.isEmpty {
            stopCarousel()
            let fallbackTitle = model.portfolioMenuBarFallbackTitle
            let state = MenuBarRenderState.fallback(title: fallbackTitle)
            guard state != lastMenuBarRenderState else { return }
            lastMenuBarRenderState = state

            let icon = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "QiemanDashboard") ?? NSImage()
            icon.isTemplate = true
            button.image = icon
            button.toolTip = fallbackTitle
            button.needsDisplay = true
            statusItem.length = NSStatusItem.squareLength
            return
        }

        // Paginate entries
        let totalPages = Int(ceil(Double(allEntries.count) / Double(pageSize)))
        if totalPages <= 1 {
            stopCarousel()
            carouselPageIndex = 0
        }
        let safePage = min(carouselPageIndex, max(0, totalPages - 1))
        let start = safePage * pageSize
        let end = min(start + pageSize, allEntries.count)
        let displayEntries = Array(allEntries[start..<end])
        renderedEntryCount = displayEntries.count

        // Start or update the carousel timer before the render guard so interval-only
        // settings changes still take effect without forcing a redraw.
        if totalPages > 1 {
            startCarousel(interval: settings.carouselIntervalSeconds)
        }

        let state = MenuBarRenderState.ticker(
            entries: displayEntries,
            appearance: appearance,
            page: safePage,
            totalPages: totalPages,
            barHeight: barHeight
        )
        guard state != lastMenuBarRenderState else { return }
        lastMenuBarRenderState = state

        let lines = displayEntries.map { $0.compactText }
        let image = renderTickerImage(entries: displayEntries, appearance: appearance, barHeight: barHeight)
        button.image = image
        let pageIndicator = totalPages > 1 ? " [\((safePage + 1))/\(totalPages)]" : ""
        button.toolTip = lines.joined(separator: "  ") + pageIndicator
        button.needsDisplay = true
        statusItem.length = image.size.width
    }

    private func startCarousel(interval: Double) {
        let clamped = max(MenuBarTickerSettings.minCarouselInterval, min(interval, MenuBarTickerSettings.maxCarouselInterval))
        if let existing = carouselTimer {
            if abs(existing.timeInterval - clamped) < 0.01 {
                return
            }
            existing.invalidate()
            carouselTimer = nil
        }
        carouselTimer = Timer.scheduledTimer(withTimeInterval: clamped, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.advanceCarousel()
            }
        }
    }

    private func stopCarousel() {
        carouselTimer?.invalidate()
        carouselTimer = nil
    }

    @MainActor private func advanceCarousel() {
        guard let model else { return }
        let allEntries = model.menuBarTickerAllCandidates
        let pageSize = model.menuBarTickerSettings.maxVisibleItems
        let totalPages = Int(ceil(Double(allEntries.count) / Double(pageSize)))
        guard totalPages > 1 else {
            stopCarousel()
            return
        }
        carouselPageIndex = (carouselPageIndex + 1) % totalPages
        updateTitle()
    }

    private func renderTickerImage(entries: [MenuBarTickerEntry], appearance: MenuBarTickerAppearance, barHeight: CGFloat) -> NSImage {
        if appearance.layoutMode == .vertical {
            return renderTickerImageVertical(entries: entries, appearance: appearance, barHeight: barHeight)
        }
        return renderTickerImageHorizontal(entries: entries, appearance: appearance, barHeight: barHeight)
    }

    private func renderTickerImageHorizontal(entries: [MenuBarTickerEntry], appearance: MenuBarTickerAppearance, barHeight: CGFloat) -> NSImage {
        let font = NSFont.monospacedSystemFont(ofSize: CGFloat(appearance.fontSize), weight: appearance.fontWeight)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let texts = entries.map(\.compactText)
        let measurements = texts.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }
        let itemSpacing = appearance.spacingMode == .manual
            ? CGFloat(appearance.manualSpacing)
            : MenuBarTickerLayoutMetrics.automaticStatusSpacing(for: appearance)
        let horizontalPadding = MenuBarTickerLayoutMetrics.statusHorizontalPadding(for: appearance)
        let width = MenuBarTickerLayoutMetrics.statusImageWidth(
            measurements: measurements,
            appearance: appearance
        )

        let image = NSImage(size: NSSize(width: width, height: barHeight))
        image.lockFocusFlipped(true)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: appearance.nsColor ?? NSColor.black,
            .paragraphStyle: paragraph
        ]
        let top = max(0, floor((barHeight - lineHeight) / 2))
        var x = horizontalPadding
        for (index, text) in texts.enumerated() {
            let remainingWidth = width - x - horizontalPadding
            guard remainingWidth > 4 else { break }
            let drawWidth = min(measurements[index], remainingWidth)
            let rect = NSRect(x: x, y: top, width: drawWidth, height: lineHeight)
            NSAttributedString(string: text, attributes: attrs)
                .draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            x += drawWidth + itemSpacing
        }

        image.unlockFocus()
        image.isTemplate = appearance.nsColor == nil
        return image
    }

    private func renderTickerImageVertical(entries: [MenuBarTickerEntry], appearance: MenuBarTickerAppearance, barHeight: CGFloat) -> NSImage {
        let font = NSFont.monospacedSystemFont(ofSize: CGFloat(appearance.fontSize), weight: appearance.fontWeight)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let texts = entries.map(\.compactText)
        let measurements = texts.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }
        let horizontalPadding = MenuBarTickerLayoutMetrics.statusHorizontalPadding(for: appearance)
        let width = MenuBarTickerLayoutMetrics.statusImageWidth(
            measurements: measurements,
            appearance: appearance
        )
        let lineSpacing = appearance.spacingMode == .manual ? CGFloat(appearance.manualSpacing) : 0

        let image = NSImage(size: NSSize(width: width, height: barHeight))
        image.lockFocusFlipped(true)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: appearance.nsColor ?? NSColor.black,
            .paragraphStyle: paragraph
        ]
        let totalHeight = CGFloat(texts.count) * lineHeight + CGFloat(max(0, texts.count - 1)) * lineSpacing
        let top = max(0, floor((barHeight - totalHeight) / 2))
        let textWidth = width - horizontalPadding * 2
        for (i, text) in texts.enumerated() {
            let rect = NSRect(
                x: horizontalPadding,
                y: top + CGFloat(i) * (lineHeight + lineSpacing),
                width: textWidth,
                height: lineHeight
            )
            NSAttributedString(string: text, attributes: attrs)
                .draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }

        image.unlockFocus()
        image.isTemplate = appearance.nsColor == nil
        return image
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            guard let button = statusItem.button else { return }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // 每次打开触发一次刷新（5 秒节流防抖），不再依赖 SwiftUI .task 在常驻 view 上重跑。
            model?.onMenuBarPopoverPresented()
        }
    }

    func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    /// Tracks the SwiftUI scene window as the main window. Returns false when
    /// the window is not (yet) reusable, e.g. while SwiftUI is still
    /// materializing it; callers may retry shortly instead of losing it.
    @discardableResult
    @MainActor func trackSwiftUISceneMainWindow(_ window: NSWindow) -> Bool {
        guard isReusableMainWindow(window) else { return false }
        configureMainWindowIdentity(window)

        if let previous = mainWindow,
           previous !== window,
           AppMainWindowTrackingPolicy.shouldDiscardPreviousTrackedWindow(
                hasPreviousTrackedWindow: true,
                isSameWindow: false,
                previousWindowIsVisible: previous.isVisible
           ) {
            discardDuplicateMainWindow(previous)
        }

        mainWindow = window
        reconcileDuplicateMainWindows(keeping: window)
        flushPendingMainWindowReveal()
        return true
    }

    @MainActor func registerMainWindowSceneOpener(_ action: @escaping () -> Void) {
        openMainWindowScene = action
        flushPendingMainWindowReveal()
    }

    @MainActor func createMainWindow() {
        guard let model else { return }
        let contentView = ContentView()
            .environmentObject(model)
            .tint(AppPalette.brand)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.center()
        configureMainWindowIdentity(window)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.setFrameAutosaveName("QiemanDashboardMainWindow")

        // Transparent toolbar for proper content-under-titlebar layout
        // without occluding content behind the system title bar area.
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.appearance = model.appearance.nsAppearance
        let hostingView = NSHostingView(rootView: contentView)
        window.contentView = hostingView
        window.delegate = self
        mainWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let refreshItem = menu.addItem(withTitle: "刷新数据", action: #selector(dockRefresh), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(.separator())
        for section in AppSection.allCases {
            let item = menu.addItem(withTitle: section.rawValue, action: #selector(dockNavigate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = section.rawValue
        }
        return menu
    }

    @objc private func dockRefresh() {
        Task { @MainActor in
            guard let model else { return }
            try? await model.refreshLatest()
        }
    }

    @objc private func dockNavigate(_ sender: NSMenuItem) {
        guard let model,
              let raw = sender.representedObject as? String,
              let section = AppSection(rawValue: raw) else { return }
        model.selectedSection = section
        showMainWindow()
    }

    /// Intercepts the window close action: hides the window instead of destroying it
    /// so the app stays alive (accessible via menu bar). The user can reopen the
    /// window from the status bar icon or the "打开主窗口" menu command.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    @MainActor func showMainWindow() {
        // 0. Collapse duplicate main windows first (e.g., a manual fallback
        //    window left over from an early-launch race next to the scene
        //    window), so the reveal targets the single surviving window.
        reconcileDuplicateMainWindows()

        // 1. Re-show the tracked main window if it still exists.
        if let window = mainWindow {
            if NSApplication.shared.windows.contains(where: { $0 === window }) {
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                return
            }
            mainWindow = nil
        }
        // 2. Search for an existing SwiftUI WindowGroup window (may have been hidden
        //    by windowShouldClose but never tracked in mainWindow).
        if let existing = findReusableMainWindow() {
            configureMainWindowIdentity(existing)
            mainWindow = existing
            existing.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        // 3. Reopen the single SwiftUI Window scene. Keeping this as the primary
        //    creation path prevents a manual AppKit window and a delayed SwiftUI
        //    window from appearing together at different sizes.
        if let openMainWindowScene {
            openMainWindowScene()
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        // 4. The SwiftUI scene has not attached yet. Early-launch reveal requests
        //    (login-item reopen, notification-tap launch) land here before the
        //    scene window exists; creating a manual window at this point used to
        //    duplicate the main window once the scene appeared. Queue the reveal
        //    until the scene attaches, with a deadline fallback for states where
        //    the scene never comes up.
        let launchGraceElapsed = finishLaunchingDate.map {
            Date().timeIntervalSince($0) >= AppMainWindowRevealPolicy.launchGraceSeconds
        } ?? false
        if AppMainWindowRevealPolicy.shouldWaitForSceneWindow(
            hasSceneOpener: false,
            launchGraceElapsed: launchGraceElapsed
        ) {
            queuePendingMainWindowReveal()
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        createMainWindow()
    }

    /// Remembers a reveal request that could not be served yet and schedules a
    /// deadline pass so the app never becomes unreachable if the scene opener
    /// never registers.
    @MainActor private func queuePendingMainWindowReveal() {
        pendingMainWindowReveal = true
        guard !pendingRevealDeadlineScheduled else { return }
        pendingRevealDeadlineScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(AppMainWindowRevealPolicy.launchGraceSeconds + 0.5))
            guard let self else { return }
            self.pendingRevealDeadlineScheduled = false
            if self.pendingMainWindowReveal, self.mainWindow == nil, self.openMainWindowScene == nil {
                self.pendingMainWindowReveal = false
                self.createMainWindow()
            }
        }
    }

    /// Serves a queued reveal request once the SwiftUI scene has attached.
    @MainActor private func flushPendingMainWindowReveal() {
        guard pendingMainWindowReveal else { return }
        pendingMainWindowReveal = false
        if let window = mainWindow, NSApplication.shared.windows.contains(where: { $0 === window }) {
            window.makeKeyAndOrderFront(nil)
        } else if let openMainWindowScene {
            openMainWindowScene()
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Collapses stray duplicate main windows down to a single window. Runs on
    /// every reveal and after scene tracking; normally a no-op.
    @MainActor private func reconcileDuplicateMainWindows(keeping preferred: NSWindow? = nil) {
        let candidates = NSApplication.shared.windows.filter { isMainWindowCandidate($0) }
        guard candidates.count > 1 else { return }

        let keep: NSWindow?
        if let preferred, candidates.contains(preferred) {
            keep = preferred
        } else {
            keep = AppMainWindowDuplicatePolicy.windowToKeep(
                candidates: candidates,
                trackedWindow: mainWindow,
                isSceneWindow: { NSStringFromClass(type(of: $0)).hasPrefix("SwiftUI.") }
            )
        }
        guard let keep else { return }

        configureMainWindowIdentity(keep)
        for candidate in candidates where candidate !== keep {
            discardDuplicateMainWindow(candidate)
        }
        mainWindow = keep
    }

    /// Distinguishes main windows from the Settings scene window or foreign
    /// windows: by identity, by main-window identifier, by the raw SwiftUI
    /// scene identifier, or by the main window title.
    @MainActor private func isMainWindowCandidate(_ window: NSWindow) -> Bool {
        guard isReusableMainWindow(window) else { return false }
        if window === mainWindow { return true }
        return window.identifier == Self.mainWindowIdentifier
            || window.identifier == NSUserInterfaceItemIdentifier(AppSceneIdentifier.mainWindow)
            || window.title == "且慢主理人"
    }

    /// Exposes the stored main window reference for zoom toggling.
    /// Returns `nil` if the window has been destroyed or is a panel/sheet.
    @MainActor var mainWindowForZoom: NSWindow? {
        guard let win = mainWindow, win.isVisible, win.canBecomeMain else { return nil }
        return win
    }

    /// Toggles a workspace-filling window frame without reserving the Dock area.
    /// Native `performZoom` uses `visibleFrame`, which can leave a large empty
    /// strip at the bottom even when the Dock is hidden.
    @MainActor func toggleMainWindowZoom(_ window: NSWindow? = nil) {
        guard let window = window ?? mainWindowForZoom,
              let screen = window.screen ?? NSScreen.main
        else { return }

        let windowID = ObjectIdentifier(window)
        let maximizedFrame = MainWindowZoomPolicy.maximizedFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
        let shouldAnimate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if MainWindowZoomPolicy.framesMatch(window.frame, maximizedFrame) {
            if let restoreFrame = mainWindowRestoreFrames.removeValue(forKey: windowID) {
                window.setFrame(restoreFrame, display: true, animate: shouldAnimate)
            } else {
                window.performZoom(nil)
            }
            return
        }

        // A window already zoomed by AppKit should keep its native restore
        // behavior on the first toggle after upgrading to this policy.
        if window.isZoomed {
            mainWindowRestoreFrames.removeValue(forKey: windowID)
            window.performZoom(nil)
            return
        }

        mainWindowRestoreFrames[windowID] = window.frame
        window.setFrame(maximizedFrame, display: true, animate: shouldAnimate)
    }

    // MARK: - Titlebar Double-Click Zoom

    /// Intercepts double-clicks in the native titlebar / unified toolbar region and
    /// forwards them as zoom toggles.  This is needed because the window uses
    /// `.hiddenTitleBar` + `titlebarAppearsTransparent = true`, which means SwiftUI
    /// tap gestures cannot reach the macOS-owned titlebar area above the content view.
    private func handleTitlebarDoubleClick(_ event: NSEvent) -> NSEvent {
        // Only care about double-clicks
        guard event.clickCount == 2 else { return event }

        let window = event.window

        // Only target our main window — skip panels, popovers, sheets
        guard let win = window,
              win == mainWindow,
              !(win is NSPanel),
              !win.isSheet,
              win.styleMask.contains(.resizable)
        else { return event }

        // Convert the click location to window coordinates
        let clickPoint = event.locationInWindow

        // Determine the titlebar height:
        // For a window with a toolbar (unified style), the titlebar region is the area
        // above the content view's frame. With fullSizeContentView, the content view
        // spans the full window, but the "titlebar" region is still the top portion
        // defined by the window's frameRect(forContentRect:) difference.
        let contentFrame = win.contentView?.frame ?? .zero
        let contentRectForContentRect = win.contentRect(forFrameRect: win.frame)
        let titlebarHeight = win.frame.height - contentRectForContentRect.height

        if MainWindowZoomPolicy.isInDoubleClickZoomBand(
            clickY: clickPoint.y,
            contentHeight: contentFrame.height,
            nativeTitlebarHeight: titlebarHeight
        ) {
            toggleMainWindowZoom(win)
            // Swallow the event so it doesn't propagate further
            return NSEvent()  // dummy event — effectively swallowed
        }

        return event
    }

    @MainActor private func configureMainWindowIdentity(_ window: NSWindow) {
        window.identifier = Self.mainWindowIdentifier
        window.title = "且慢主理人"
        if let model {
            window.appearance = model.appearance.nsAppearance
        }
    }

    @MainActor private func findReusableMainWindow() -> NSWindow? {
        NSApplication.shared.windows.first { window in
            window.identifier == Self.mainWindowIdentifier && isReusableMainWindow(window)
        } ?? NSApplication.shared.windows.first { window in
            window.title == "且慢主理人" && isReusableMainWindow(window)
        } ?? NSApplication.shared.windows.first { window in
            window.isVisible && isReusableMainWindow(window)
        }
    }

    @MainActor private func isReusableMainWindow(_ window: NSWindow) -> Bool {
        window.canBecomeMain && !(window is NSPanel) && !window.isSheet
    }

    @MainActor private func discardDuplicateMainWindow(_ window: NSWindow) {
        mainWindowRestoreFrames.removeValue(forKey: ObjectIdentifier(window))
        window.orderOut(nil)
        if window.delegate === self {
            window.delegate = nil
        }
        window.close()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        guard let deepLink = NotificationDeepLinkPayload(userInfo: userInfo) else { return }
        NotificationCenter.default.post(name: .qiemanNotificationDeepLink, object: deepLink)
    }

    deinit {
        carouselTimer?.invalidate()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        if let titlebarDoubleClickMonitor {
            NSEvent.removeMonitor(titlebarDoubleClickMonitor)
        }
    }
}

// MARK: - NSWindowDelegate

extension QiemanApplicationDelegate: NSWindowDelegate {
    /// When the user clicks the red close button, hide the window instead of
    /// destroying it. This prevents the app from "exiting" — the user can
    /// reopen it via the menu bar icon or by clicking the Dock icon.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

@MainActor
private final class MainWindowTrackingNSView: NSView {
    private static let maxTrackingAttempts = 4
    private static let retryInterval: Duration = .milliseconds(300)

    weak var appDelegate: QiemanApplicationDelegate?
    private var trackingAttempts = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        attemptTracking(window)
    }

    /// SwiftUI scene windows can transiently fail the reusability guard while
    /// being materialized. Losing the tracking call would leave the scene
    /// window untracked forever (never deduplicated against a stray manual
    /// window), so retry shortly instead of giving up on the first refusal.
    private func attemptTracking(_ window: NSWindow) {
        if appDelegate?.trackSwiftUISceneMainWindow(window) == true { return }
        guard trackingAttempts < Self.maxTrackingAttempts else { return }
        trackingAttempts += 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.retryInterval)
            guard let self, let window = self.window else { return }
            self.attemptTracking(window)
        }
    }
}

private struct MainWindowSceneTracker: NSViewRepresentable {
    let appDelegate: QiemanApplicationDelegate

    @MainActor func makeNSView(context: Context) -> MainWindowTrackingNSView {
        let view = MainWindowTrackingNSView(frame: .zero)
        view.appDelegate = appDelegate
        return view
    }

    @MainActor func updateNSView(_ view: MainWindowTrackingNSView, context: Context) {
        view.appDelegate = appDelegate
        if let window = view.window {
            appDelegate.trackSwiftUISceneMainWindow(window)
        }
    }
}

private struct MainWindowSceneOpener: View {
    @Environment(\.openWindow) private var openWindow

    let appDelegate: QiemanApplicationDelegate

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                appDelegate.registerMainWindowSceneOpener {
                    openWindow(id: AppSceneIdentifier.mainWindow)
                }
            }
    }
}

@MainActor
private enum QiemanAppModelHolder {
    static let shared = AppModel()
}

@main
struct QiemanDashboardApp: App {
    @NSApplicationDelegateAdaptor(QiemanApplicationDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        let sharedModel = QiemanAppModelHolder.shared
        _model = StateObject(wrappedValue: sharedModel)
    }

    var body: some Scene {
        Window("且慢主理人", id: AppSceneIdentifier.mainWindow) {
            ContentView()
                .environmentObject(model)
                .tint(AppPalette.brand)
                .onAppear {
                    appDelegate.configure(model: model)
                    appDelegate.syncWindowAppearances()
                }
                .background(MainWindowSceneTracker(appDelegate: appDelegate))
                .background(MainWindowSceneOpener(appDelegate: appDelegate))
        }
        .defaultSize(width: 1200, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("打开主窗口") {
                    Task { @MainActor in
                        appDelegate.showMainWindow()
                    }
                }
                .keyboardShortcut("0")
                Button("打开数据目录") {
                    model.openDataDirectory()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button(model.isCheckingForUpdates ? "检查更新中…" : "检查更新…") {
                    Task { await model.checkForUpdates(userInitiated: true) }
                }
                .disabled(model.isCheckingForUpdates)
                .keyboardShortcut("u", modifiers: .command)
                Divider()
                Button("快捷操作") {
                    model.isPresentingCommandPalette = true
                    appDelegate.showMainWindow()
                }
                .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("立即刷新") {
                    Task { try? await model.refreshLatest() }
                }
                .keyboardShortcut("r")
            }

            CommandGroup(after: .toolbar) {
                Button("切换侧边栏") {
                    NotificationCenter.default.post(name: .qiemanToggleSidebar, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }

            CommandMenu("导航") {
                Button("总览") {
                    model.selectedSection = .overview
                    appDelegate.showMainWindow()
                }
                .keyboardShortcut("1")

                Button("我的持仓") {
                    model.selectedSection = .portfolio
                    appDelegate.showMainWindow()
                }
                .keyboardShortcut("2")

                Button("调仓动态") {
                    model.selectedPlatformActivityTab = .adjustments
                    model.selectedSection = .platform
                    appDelegate.showMainWindow()
                }
                .keyboardShortcut("3")

                Button("论坛发言") {
                    model.selectedPlatformActivityTab = .forum
                    model.selectedSection = .platform
                    appDelegate.showMainWindow()
                }
                .keyboardShortcut("4")

                Button("投资智能") {
                    model.selectedSection = .intelligence
                    appDelegate.showMainWindow()
                }
                .keyboardShortcut("5")

                Button("设置") {
                    model.selectedSection = .settings
                    appDelegate.showMainWindow()
                }
                .keyboardShortcut("6")
            }

            CommandGroup(after: .textEditing) {
                Button("搜索当前页面") {
                    appDelegate.showMainWindow()
                    NotificationCenter.default.post(name: .qiemanFocusSearch, object: nil)
                }
                .keyboardShortcut("f")
                .disabled(![AppSection.portfolio, .platform].contains(model.selectedSection))
            }
        }

        // 原生 Settings 场景，支持标准 ⌘, 打开偏好设置窗口
        Settings {
            SettingsSectionView()
                .environmentObject(model)
        }
    }
}
#endif
