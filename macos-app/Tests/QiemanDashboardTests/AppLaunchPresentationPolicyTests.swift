import AppKit
import XCTest
@testable import QiemanDashboard

final class AppLaunchPresentationPolicyTests: XCTestCase {
    func testInitialLaunchStaysRegular() {
        XCTAssertEqual(
            AppLaunchPresentationPolicy.initialActivationPolicy(),
            .regular
        )
    }

    func testConfiguredPolicyUsesDockPreferenceAfterWindowExists() {
        XCTAssertEqual(AppLaunchPresentationPolicy.configuredActivationPolicy(showsInDock: true), .regular)
        XCTAssertEqual(AppLaunchPresentationPolicy.configuredActivationPolicy(showsInDock: false), .accessory)
    }

    func testNotificationDelegateIsInstalledAtLaunch() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: sourceRoot.appendingPathComponent("QiemanDashboardApp.swift"))

        XCTAssertTrue(source.contains("UNUserNotificationCenter.current().delegate = self"))
        XCTAssertFalse(source.contains("QIEMAN_INSTALL_NOTIFICATION_DELEGATE_AT_LAUNCH"))
    }

    func testSwiftUISceneWindowDeduplicatesDifferentTrackedWindowRegardlessOfVisibility() {
        XCTAssertTrue(AppMainWindowTrackingPolicy.shouldDiscardPreviousTrackedWindow(
            hasPreviousTrackedWindow: true,
            isSameWindow: false,
            previousWindowIsVisible: true
        ))
        XCTAssertTrue(AppMainWindowTrackingPolicy.shouldDiscardPreviousTrackedWindow(
            hasPreviousTrackedWindow: true,
            isSameWindow: false,
            previousWindowIsVisible: false
        ))
        XCTAssertFalse(AppMainWindowTrackingPolicy.shouldDiscardPreviousTrackedWindow(
            hasPreviousTrackedWindow: true,
            isSameWindow: true,
            previousWindowIsVisible: true
        ))
        XCTAssertFalse(AppMainWindowTrackingPolicy.shouldDiscardPreviousTrackedWindow(
            hasPreviousTrackedWindow: false,
            isSameWindow: false,
            previousWindowIsVisible: false
        ))
    }

    func testDiscardPolicyNeverClosesSwiftUIOwnedWindows() {
        XCTAssertFalse(AppMainWindowDiscardPolicy.shouldClose(windowClassName: "SwiftUI.Window"))
        XCTAssertTrue(AppMainWindowDiscardPolicy.shouldClose(windowClassName: "NSWindow"))
    }

    @MainActor
    func testTrackingNewSceneDiscardsPreviousTrackedWindowEvenIfPreviousIsNotYetVisible() {
        let delegate = QiemanApplicationDelegate()
        let firstWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let secondWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        firstWindow.isReleasedWhenClosed = false
        secondWindow.isReleasedWhenClosed = false
        defer {
            firstWindow.delegate = nil
            secondWindow.delegate = nil
            firstWindow.orderOut(nil)
            firstWindow.close()
            secondWindow.orderOut(nil)
            secondWindow.close()
        }

        firstWindow.orderFront(nil)
        delegate.trackSwiftUISceneMainWindow(firstWindow)
        firstWindow.delegate = delegate
        firstWindow.orderOut(nil)
        secondWindow.orderFront(nil)
        delegate.trackSwiftUISceneMainWindow(secondWindow)

        XCTAssertTrue(delegate.mainWindow === secondWindow)
        XCTAssertNil(firstWindow.delegate)
        XCTAssertFalse(firstWindow.isVisible)
    }

    @MainActor
    func testShowMainWindowReusesVisibleUntrackedSwiftUIWindowBeforeCreatingFallback() {
        let delegate = QiemanApplicationDelegate()
        let existingWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        existingWindow.isReleasedWhenClosed = false
        existingWindow.title = "QiemanDashboard"
        existingWindow.orderFront(nil)
        defer {
            existingWindow.orderOut(nil)
            existingWindow.close()
        }

        delegate.showMainWindow()

        XCTAssertTrue(delegate.mainWindow === existingWindow)
    }

    func testDidFinishLaunchingWaitsForSwiftUIWindowBeforeFallbackCreation() {
        XCTAssertFalse(AppLaunchWindowPolicy.shouldCreateImmediateManualWindowOnLaunch)
    }

    func testAppUsesOneIdentifiedSwiftUIWindowWithoutADelayedManualFallback() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("QiemanDashboardApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("Window(\"观澜\", id: AppSceneIdentifier.mainWindow)"))
        XCTAssertTrue(source.contains(".defaultSize(width: 1200, height: 800)"))
        XCTAssertTrue(source.contains("registerMainWindowSceneOpener"))
        XCTAssertFalse(source.contains("WindowGroup {"))
        XCTAssertFalse(source.contains("Task.sleep(nanoseconds: 500_000_000)"))
    }

    // MARK: - Early reveal queuing (double-window fix)

    func testEarlyRevealWaitsForSceneWithinLaunchGrace() {
        XCTAssertTrue(AppMainWindowRevealPolicy.shouldWaitForSceneWindow(
            hasSceneOpener: false,
            launchGraceElapsed: false
        ))
        XCTAssertFalse(AppMainWindowRevealPolicy.shouldWaitForSceneWindow(
            hasSceneOpener: true,
            launchGraceElapsed: false
        ))
        XCTAssertFalse(AppMainWindowRevealPolicy.shouldWaitForSceneWindow(
            hasSceneOpener: false,
            launchGraceElapsed: true
        ))
    }

    @MainActor
    func testShowMainWindowBeforeSceneRegistrationQueuesInsteadOfCreatingManualWindow() {
        let delegate = QiemanApplicationDelegate()

        delegate.showMainWindow()

        XCTAssertNil(delegate.mainWindow)
        XCTAssertFalse(NSApplication.shared.windows.contains {
            $0.identifier == NSUserInterfaceItemIdentifier("QiemanDashboard.mainWindow")
        })
    }

    @MainActor
    func testPendingRevealFlushedWhenSceneOpenerRegisters() {
        let delegate = QiemanApplicationDelegate()
        delegate.showMainWindow()

        var openerCalled = false
        delegate.registerMainWindowSceneOpener { openerCalled = true }

        XCTAssertTrue(openerCalled)
    }

    @MainActor
    func testGraceElapsedWithoutSceneFallsBackToManualWindow() {
        let delegate = QiemanApplicationDelegate()
        delegate.configure(model: AppModel())
        delegate.finishLaunchingDate = Date(timeIntervalSinceNow: -10)

        delegate.showMainWindow()

        let created = delegate.mainWindow
        XCTAssertNotNil(created)
        XCTAssertEqual(created?.identifier, NSUserInterfaceItemIdentifier("QiemanDashboard.mainWindow"))
        created?.delegate = nil
        created?.identifier = nil
        created?.orderOut(nil)
        created?.close()
    }

    // MARK: - Duplicate reconciliation

    func testDuplicatePolicyPrefersSceneWindowOverTrackedManualWindow() {
        let manual = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let scene = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        manual.isReleasedWhenClosed = false
        scene.isReleasedWhenClosed = false
        defer {
            manual.close()
            scene.close()
        }

        let keep = AppMainWindowDuplicatePolicy.windowToKeep(
            candidates: [manual, scene],
            trackedWindow: manual,
            isSceneWindow: { $0 === scene }
        )

        XCTAssertTrue(keep === scene)
    }

    func testDuplicatePolicyKeepsTrackedWindowWithoutSceneCandidate() {
        let tracked = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        tracked.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        defer {
            tracked.close()
            other.close()
        }

        let keep = AppMainWindowDuplicatePolicy.windowToKeep(
            candidates: [tracked, other],
            trackedWindow: tracked,
            isSceneWindow: { _ in false }
        )

        XCTAssertTrue(keep === tracked)
    }

    @MainActor
    func testShowMainWindowCollapsesDuplicateMainWindowsToOne() {
        let delegate = QiemanApplicationDelegate()
        let first = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let second = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        first.title = "观澜"
        second.title = "观澜"
        first.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        first.orderFront(nil)
        second.orderFront(nil)
        defer {
            for window in [first, second] {
                window.delegate = nil
                window.orderOut(nil)
                window.close()
            }
        }

        delegate.showMainWindow()

        XCTAssertTrue(first.isVisible)
        XCTAssertFalse(second.isVisible)
        XCTAssertTrue(delegate.mainWindow === first)
    }

    @MainActor
    func testTrackingSceneWindowAfterManualFallbackDiscardsStrayManualWindow() throws {
        let delegate = QiemanApplicationDelegate()
        delegate.configure(model: AppModel())
        delegate.finishLaunchingDate = Date(timeIntervalSinceNow: -10)
        delegate.showMainWindow()
        let manual = try XCTUnwrap(delegate.mainWindow)
        // createMainWindow must opt out of isReleasedWhenClosed so the
        // discard-close below cannot free the instance that the defer block
        // still touches (use-after-free crashed CI with SIGSEGV, and shipped
        // as the v4.2.1 login-launch SIGSEGV in objc_release).
        XCTAssertFalse(manual.isReleasedWhenClosed)

        let scene = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        scene.title = "观澜"
        scene.isReleasedWhenClosed = false
        scene.orderFront(nil)
        defer {
            scene.delegate = nil
            scene.orderOut(nil)
            scene.close()
            manual.delegate = nil
            manual.orderOut(nil)
            manual.close()
        }

        let tracked = delegate.trackSwiftUISceneMainWindow(scene)

        XCTAssertTrue(tracked)
        XCTAssertTrue(delegate.mainWindow === scene)
        XCTAssertFalse(manual.isVisible)
    }

    @MainActor
    func testCreateMainWindowOptsOutOfReleaseOnClose() throws {
        let delegate = QiemanApplicationDelegate()
        delegate.configure(model: AppModel())

        delegate.createMainWindow()

        let window = try XCTUnwrap(delegate.mainWindow)
        // isReleasedWhenClosed = true makes close() release the window while
        // AppKit may still hold transient references (state restoration,
        // window list) — the v4.2.1 login-launch over-release crash.
        XCTAssertFalse(window.isReleasedWhenClosed)
        // Mirror discardDuplicateMainWindow cleanup: without the release-on-
        // close the closed window lingers in NSApp.windows and would pollute
        // later tests' global window-list assertions.
        window.delegate = nil
        window.identifier = nil
        window.title = ""
        window.orderOut(nil)
        window.close()
    }

    @MainActor
    func testDarkAppearanceOverridesALightSystemWindow() throws {
        let model = AppModel()
        let originalAppearance = model.appearance
        defer { model.appearance = originalAppearance }
        model.appearance = .dark

        let delegate = QiemanApplicationDelegate()
        delegate.configure(model: model)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        defer { window.close() }

        XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), .aqua)

        delegate.syncWindowAppearances(in: [window])

        XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)
    }

    @MainActor
    func testFollowingSystemClearsDarkAppearanceFromEntireViewHierarchy() throws {
        let application = NSApplication.shared
        let originalApplicationAppearance = application.appearance
        application.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        defer { application.appearance = originalApplicationAppearance }

        let model = AppModel()
        let originalModelAppearance = model.appearance
        defer { model.appearance = originalModelAppearance }
        model.appearance = .dark

        let delegate = QiemanApplicationDelegate()
        delegate.configure(model: model)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let rootView = NSView(frame: window.contentView?.bounds ?? .zero)
        let nestedView = NSView(frame: rootView.bounds)
        nestedView.appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        rootView.addSubview(nestedView)
        window.contentView = rootView
        defer { window.close() }

        delegate.syncWindowAppearances(in: [window])
        XCTAssertEqual(nestedView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)

        model.appearance = .system
        delegate.syncWindowAppearances(in: [window])

        XCTAssertNil(window.appearance)
        XCTAssertNil(rootView.appearance)
        XCTAssertNil(nestedView.appearance)
        XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), .aqua)
        XCTAssertEqual(rootView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), .aqua)
        XCTAssertEqual(nestedView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), .aqua)
    }
}
