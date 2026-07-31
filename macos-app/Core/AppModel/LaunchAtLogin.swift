import Foundation

// MARK: - LaunchAtLoginController

/// Cross-platform launch-at-login abstraction.
///
/// macOS uses `SMAppService.mainApp` plus a legacy `LaunchAgent` fallback.
/// iOS has no equivalent concept, so the iOS implementation is a no-op and the
/// settings UI hides this option. Consumers (`AppModel/Auth.swift`,
/// `AppModel/ComputedProperties.swift`) depend only on this protocol.
@MainActor
protocol LaunchAtLoginController: AnyObject {
    /// Whether launch-at-login is currently registered with the OS.
    var isInstalled: Bool { get }

    /// A short status string for display in Settings.
    var statusText: String { get }

    /// Enable or disable launch-at-login.
    /// - Returns: a non-empty error message if registration failed (nil on success).
    @discardableResult
    func setEnabled(_ enabled: Bool) -> String?
}

// MARK: - Platform Factory

/// Construct the platform-default launch-at-login controller.
@MainActor
func makeDefaultLaunchAtLoginController() -> any LaunchAtLoginController {
    #if os(macOS)
    return macOSLaunchAtLoginController()
    #else
    return NoOpLaunchAtLoginController()
    #endif
}

/// Fallback no-op used on platforms without launch-at-login (iOS).
@MainActor
final class NoOpLaunchAtLoginController: LaunchAtLoginController {
    var isInstalled: Bool { false }
    var statusText: String { "当前平台不支持" }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> String? { nil }
}
