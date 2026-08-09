#if canImport(AppKit)
import AppKit
#endif
import Foundation

// MARK: - App Update Management

extension AppModel {
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
                isPresentingUpdateSheet = true
                noticeMessage = "发现新版本 \(update.version)，可以下载并重启安装。"
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
