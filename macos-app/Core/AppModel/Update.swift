#if canImport(AppKit)
import AppKit
#endif
import Foundation

// MARK: - App Update Management

/// 2026-09-02:Homebrew cask 安装检测。brew 安装的应用由 `brew upgrade` 管理,
/// 应用内更新退位为提示——否则应用内覆盖安装会让 brew 认为 cask 被改动、
/// 两套更新互相打架。判定:Caskroom 里存在本应用 cask 的版本回执目录
/// (Apple Silicon /opt/homebrew、Intel /usr/local;不调 brew 命令,零开销;
/// brew 卸载会移除该目录,检测自动失效)。
enum HomebrewCaskInstallation {
    static let caskToken = "guanlan"

    static var defaultCaskroomRoots: [String] {
        ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]
    }

    static func isManaged(caskroomRoots: [String] = defaultCaskroomRoots) -> Bool {
        caskroomRoots.contains { root in
            let tokenPath = (root as NSString).appendingPathComponent(caskToken)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: tokenPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return false }
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: tokenPath)) ?? []
            return !versions.isEmpty
        }
    }
}

extension AppModel {
    /// 本应用是否由 Homebrew cask 安装(brew 管升级,应用内安装退位)。
    var isHomebrewManagedApp: Bool {
        HomebrewCaskInstallation.isManaged()
    }

    func checkForUpdates(userInitiated: Bool) async {
        guard !isCheckingForUpdates else { return }
        if userInitiated {
            errorMessage = ""
        }

        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }

        do {
            let update = try await updateService.checkForUpdate()
            if let update {
                availableUpdate = update
                if isHomebrewManagedApp {
                    // brew 管理:仍检查(知道有新版),但不弹安装弹窗、不覆盖安装。
                    isPresentingUpdateSheet = false
                    noticeMessage = "发现新版本 \(update.version)。本应用由 Homebrew 管理，请运行 brew upgrade 更新。"
                } else {
                    isPresentingUpdateSheet = true
                    noticeMessage = "发现新版本 \(update.version)，可以下载并重启安装。"
                }
            } else if userInitiated {
                noticeMessage = "已经是最新版本：\(updateService.currentVersion)。"
            }
        } catch {
            if userInitiated {
                errorMessage = error.localizedDescription
            }
        }
    }

    func downloadAndInstallAvailableUpdate() async {
        guard let update = availableUpdate else { return }
        guard !isInstallingUpdate else { return }
        if isHomebrewManagedApp {
            errorMessage = "本应用由 Homebrew 管理，请运行 brew upgrade 更新；应用内覆盖安装已停用。"
            return
        }

        isInstallingUpdate = true
        errorMessage = ""
        updateInstallProgress = "正在准备更新…"
        updateDownloadFraction = 0
        defer {
            isInstallingUpdate = false
        }

        do {
            try await updateService.install(release: update) { [weak self] message, fraction in
                guard let self else { return }
                self.updateInstallProgress = message
                self.updateDownloadFraction = fraction
            }
            updateDownloadFraction = 0
            updateInstallProgress = "安装器已启动，应用即将重启…"
            noticeMessage = "更新包已准备好，正在重启应用完成覆盖安装。"
            try? await Task.sleep(nanoseconds: 600_000_000)
            #if os(macOS)
            NSApplication.shared.terminate(nil)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            Darwin.exit(0)
            #endif
        } catch {
            updateDownloadFraction = 0
            updateInstallProgress = ""
            errorMessage = error.localizedDescription
        }
    }

    func openAvailableUpdateReleasePage() {
        guard let update = availableUpdate else { return }
        updateService.openUpdateDestination(for: update)
        noticeMessage = "已打开更新页。"
    }

    func dismissUpdateSheet() {
        isPresentingUpdateSheet = false
    }

    func scheduleAutomaticUpdateCheckIfNeeded() {
        guard autoCheckForUpdatesOnLaunch else { return }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await self?.checkForUpdates(userInitiated: false)
        }
    }
}
