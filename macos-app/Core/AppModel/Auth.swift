#if canImport(AppKit)
import AppKit
#endif
import Foundation

// MARK: - Comments & Data Directory

extension AppModel {
    func loadCommentsForSelectedPost() async {
        guard let post = selectedPost, let postID = post.postId else { return }
        let sortType = commentSortType
        let managerBrokerUserID = onlyManagerReplies ? (post.brokerUserId ?? "") : ""
        let requestKey = [
            String(postID),
            sortType,
            managerBrokerUserID
        ].joined(separator: "|")

        activeCommentsRequestKey = requestKey
        commentsPayload = nil
        isLoadingComments = true
        errorMessage = ""
        defer {
            if activeCommentsRequestKey == requestKey {
                isLoadingComments = false
            }
        }

        do {
            let payload = try await nativeClient.fetchComments(
                postID: postID,
                sortType: sortType,
                pageNum: 1,
                pageSize: 10,
                managerBrokerUserID: managerBrokerUserID
            )
            guard activeCommentsRequestKey == requestKey else { return }
            commentsPayload = payload
        } catch {
            guard activeCommentsRequestKey == requestKey else { return }
            errorMessage = error.localizedDescription
        }
    }

    func openDataDirectory() {
        dataController.openDataDirectory()
    }
}

// MARK: - App Settings, Window & Status

extension AppModel {
    func selectPlatformAction(_ actionID: String) {
        selectedPlatformActionID = actionID
    }

    func updateLaunchAtLoginEnabled(_ isEnabled: Bool) {
        setLaunchAtLoginEnabled(isEnabled)
    }

    func showMainWindow(section: AppSection) {
        selectedSection = section
        revealMainWindowIfNeeded()
    }

    /// 终止整个应用进程。提供给菜单栏弹框与设置面板的「退出应用」入口复用，
    /// 避免在多个 View 里直接耦合 NSApplication。
    func quitApplication() {
        NSApplication.shared.terminate(nil)
    }

    func refreshDataForSectionIfNeeded(_ section: AppSection) {
        if section == .portfolio, hasPersonalWatchlist, !isRefreshingPersonalWatchlist {
            Task { try? await refreshPersonalWatchlist(updateNotice: false) }
        }

        let decision = RefreshDecision.sectionTriggered(
            section: section,
            lastLatestRefreshAt: lastLatestRefreshAt,
            lastPortfolioRefreshAt: lastPortfolioRefreshAt,
            hasForumPosts: hasForumPosts,
            hasPlatformActions: hasPlatformActions,
            hasPersonalPortfolio: hasPersonalPortfolio,
            hasPortfolioSnapshot: userPortfolioSnapshot != nil,
            isRefreshingLatest: isRefreshing,
            isRefreshingPortfolio: isRefreshingPortfolio
        )

        switch decision {
        case .skip:
            if section == .platform,
               selectedPlatformActivityTab == .forum,
               hasForumPosts {
                ensureSelectedForumPost()
            }
            return
        case .refreshPortfolio:
            Task { try? await refreshUserPortfolio(updateNotice: false) }
        case .refreshLatest:
            Task { try? await refreshLatest(persist: false, updateNotice: false) }
        }
    }

    func ensureSelectedForumPost(preferredID: String? = nil) {
        guard currentSnapshot?.snapshotType == "posts" else {
            selectedPostID = nil
            return
        }
        let records = currentSnapshot?.records ?? []
        guard !records.isEmpty else {
            selectedPostID = nil
            return
        }
        if let preferredID, records.contains(where: { $0.id == preferredID }) {
            selectedPostID = preferredID
            return
        }
        if let selectedPostID, records.contains(where: { $0.id == selectedPostID }) {
            return
        }
        selectedPostID = records.first?.id
    }

    func ensureSelectedPlatformAction(preferredID: String? = nil) {
        let actions = platformPayload?.actions ?? []
        guard !actions.isEmpty else {
            selectedPlatformActionID = nil
            return
        }
        if let preferredID, actions.contains(where: { $0.id == preferredID }) {
            selectedPlatformActionID = preferredID
            return
        }
        if let selectedPlatformActionID, actions.contains(where: { $0.id == selectedPlatformActionID }) {
            return
        }
        selectedPlatformActionID = actions.first?.id
    }

    var managerWatchFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("manager-watch-settings.json", isDirectory: false)
    }

    var preferredManagerWatchName: String {
        let primary = form.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !primary.isEmpty {
            return primary
        }
        let secondary = form.managerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return secondary.isEmpty ? "ETF拯救世界" : secondary
    }

    func refreshLaunchAtLoginStatus() {
        #if os(macOS)
        if let mac = launchAtLoginController as? macOSLaunchAtLoginController {
            mac.syncAgentIfNeeded()
        }
        #endif
        launchAtLoginEnabled = launchAtLoginController.isInstalled
    }

    func setLaunchAtLoginEnabled(_ isEnabled: Bool) {
        let failure = launchAtLoginController.setEnabled(isEnabled)
        refreshLaunchAtLoginStatus()

        if let failure {
            errorMessage = "设置开机自启失败：\(failure)"
        } else {
            noticeMessage = isEnabled ? "已开启开机自启。" : "已关闭开机自启。"
        }
    }

    func revealMainWindowIfNeeded() {
        #if os(macOS)
        appDelegate?.closePopover()
        NSApplication.shared.activate(ignoringOtherApps: true)

        if let appDelegate {
            appDelegate.showMainWindow()
            return
        }

        if let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
            return
        }

        appDelegate?.createMainWindow()

        DispatchQueue.main.async {
            if let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
        #endif
    }
}
