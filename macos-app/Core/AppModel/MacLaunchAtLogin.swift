#if os(macOS)
import Foundation
import ServiceManagement

/// macOS launch-at-login: `SMAppService.mainApp` (primary) plus a legacy
/// `LaunchAgent` fallback for builds where SMAppService is unavailable.
@MainActor
final class macOSLaunchAtLoginController: LaunchAtLoginController {
    private let launchAgent = LaunchAtLoginAgent()

    var isInstalled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled || launchAgent.isInstalled
        }
        return launchAgent.isInstalled
    }

    var statusText: String {
        if launchAgent.isInstalled {
            return "已开启"
        }
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled: return "已开启"
            case .requiresApproval: return "待系统授权"
            case .notFound: return "当前构建不支持"
            case .notRegistered: return "已关闭"
            @unknown default: return "未知"
            }
        }
        return "已关闭"
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> String? {
        var failures: [String] = []

        // Register SMAppService first when enabling.
        if #available(macOS 13.0, *), enabled {
            do {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        // Install/uninstall the legacy LaunchAgent fallback.
        do {
            if enabled {
                try launchAgent.install()
            } else {
                try launchAgent.uninstall()
            }
        } catch {
            failures.append(error.localizedDescription)
        }

        // Unregister SMAppService when disabling.
        if #available(macOS 13.0, *), !enabled {
            do {
                switch SMAppService.mainApp.status {
                case .enabled, .requiresApproval:
                    try SMAppService.mainApp.unregister()
                case .notFound, .notRegistered:
                    break
                @unknown default:
                    break
                }
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        return failures.isEmpty ? nil : failures.joined(separator: "；")
    }

    /// Keep the LaunchAgent in sync when SMAppService is the active mode
    /// (mirrors the original `refreshLaunchAtLoginStatus` side effect).
    func syncAgentIfNeeded() {
        if #available(macOS 13.0, *) {
            let serviceEnabled = SMAppService.mainApp.status == .enabled
            if serviceEnabled && !launchAgent.isInstalled {
                try? launchAgent.install()
            }
        }
    }
}
#endif
