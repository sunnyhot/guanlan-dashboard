
#if os(iOS)
import SwiftUI
import UIKit
import UserNotifications

// MARK: - iOS App Entry

/// iOS application entry point.
///
/// Mirrors the macOS app: a single `WindowGroup` hosting the shared
/// `ContentView` with the shared `AppModel` injected. macOS-only surface
/// (menu bar, self-updater, launch-at-login, dock/activation policy) is absent
/// on iOS — those capabilities are abstracted behind cross-platform protocols
/// (see `AppUpdateService`, `LaunchAtLoginController`, `LinkOpener`).
///
/// Notification handling must be wired via `UIApplicationDelegateAdaptor`:
/// `UNUserNotificationCenter.delegate` is weak, so the delegate must be retained
/// by the app delegate (which is itself retained by SwiftUI).
@main
struct QiemanDashboardiOSApp: App {
    @UIApplicationDelegateAdaptor(QiemanAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .tint(AppPalette.brand)
                .onAppear {
                    // Once AppModel is alive and its `.qiemanNotificationDeepLink`
                    // subscription is active, deliver any cold-launch payload cached
                    // by the app delegate.
                    appDelegate.deliverColdLaunchDeepLinkIfNeeded(model: model)
                }
        }
    }
}

// MARK: - iOS App Delegate (UNUserNotificationCenter + cold-launch payload)

@MainActor
final class QiemanAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Cached deep-link payload captured during a cold launch triggered by a
    /// notification tap, before the SwiftUI model subscription was active.
    private var pendingColdLaunchPayload: NotificationDeepLinkPayload?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Install the notification center delegate before launch completes.
        // Apple requires this be set by the time the app finishes launching.
        UNUserNotificationCenter.current().delegate = self

        // Capture a cold-launch notification tap (launched by tapping a notif).
        if let notification = launchOptions?[.remoteNotification] as? [AnyHashable: Any],
           let payload = NotificationDeepLinkPayload(userInfo: notification) {
            pendingColdLaunchPayload = payload
        }
        return true
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Foreground presentation mirrors macOS: show banner, sound, and list.
        [.banner, .sound, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let payload = NotificationDeepLinkPayload(userInfo: userInfo) else { return }
        // Broadcast via the shared deep-link notification; AppModel subscribes to
        // `.qiemanNotificationDeepLink` and routes it via `handleNotificationDeepLink`.
        NotificationCenter.default.post(name: .qiemanNotificationDeepLink, object: payload)
    }

    /// Deliver a cold-launch deep-link payload once AppModel has subscribed.
    /// Called from the SwiftUI `onAppear` after the model is alive.
    func deliverColdLaunchDeepLinkIfNeeded(model: AppModel) {
        guard let payload = pendingColdLaunchPayload else { return }
        pendingColdLaunchPayload = nil
        // The model's `.qiemanNotificationDeepLink` subscription is now active,
        // so posting routes the payload to `handleNotificationDeepLink`.
        NotificationCenter.default.post(name: .qiemanNotificationDeepLink, object: payload)
    }
}
#endif
