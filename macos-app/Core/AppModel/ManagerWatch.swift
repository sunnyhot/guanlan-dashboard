import Foundation

// MARK: - Manager Watch

extension AppModel {
    func syncManagerWatchTargetsFromCurrentForm() {
        let prodCode = form.prodCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let managerName = preferredManagerWatchName
        if !prodCode.isEmpty {
            managerWatchSettings.prodCode = prodCode
        }
        if !managerName.isEmpty {
            managerWatchSettings.managerName = managerName
        }
        persistManagerWatchSettings(restartLoop: false)
        noticeMessage = "已把通知巡检目标同步成当前查询参数。"
    }

    func updateManagerWatchEnabled(_ isEnabled: Bool) {
        Task { await setManagerWatchEnabled(isEnabled) }
    }

    func updateManagerWatchInterval(_ intervalMinutes: Int) {
        managerWatchSettings.intervalMinutes = max(5, intervalMinutes)
        persistManagerWatchSettings()
        if managerWatchSettings.isEnabled {
            noticeMessage = "通知巡检频率已调整为 \(managerWatchSettings.intervalLabel)。"
        }
    }

    func updateManagerWatchForumEnabled(_ isEnabled: Bool) {
        managerWatchSettings.watchForum = isEnabled
        persistManagerWatchSettings()
    }

    func updateManagerWatchPlatformEnabled(_ isEnabled: Bool) {
        managerWatchSettings.watchPlatform = isEnabled
        persistManagerWatchSettings()
    }

    func saveManagerWatchConfiguration() {
        persistManagerWatchSettings()
        noticeMessage = "已保存主理人通知巡检设置。"
    }

    func runManagerWatchNow() {
        Task { await performManagerWatchPoll(sendNotifications: true, manual: true) }
    }

    func loadManagerWatchSettings() {
        guard let managerWatchFileURL else { return }
        do {
            managerWatchSettings = try managerWatchStore.load(from: managerWatchFileURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func persistManagerWatchSettings(restartLoop: Bool = true) {
        guard let managerWatchFileURL else { return }
        do {
            try managerWatchStore.save(managerWatchSettings, to: managerWatchFileURL)
        } catch {
            errorMessage = error.localizedDescription
        }
        if restartLoop {
            restartManagerWatchLoop(immediate: false)
        }
    }

    func setManagerWatchEnabled(_ isEnabled: Bool) async {
        if isEnabled {
            let granted = await notificationManager.requestAuthorizationIfNeeded()
            guard granted else {
                managerWatchSettings.isEnabled = false
                managerWatchSettings.lastErrorMessage = "系统通知权限未开启"
                persistManagerWatchSettings(restartLoop: false)
                errorMessage = "系统通知权限未开启。请在系统设置里允许\u{201c}且慢主理人\u{201d}的通知后再开启巡检。"
                return
            }
            if managerWatchSettings.prodCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                managerWatchSettings.prodCode = form.prodCode.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if managerWatchSettings.managerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                managerWatchSettings.managerName = preferredManagerWatchName
            }
        }

        managerWatchSettings.isEnabled = isEnabled
        managerWatchSettings.lastErrorMessage = nil
        persistManagerWatchSettings(restartLoop: false)
        restartManagerWatchLoop(immediate: isEnabled)
        noticeMessage = isEnabled
            ? "已开启主理人通知巡检，首次会先静默建立基线。"
            : "已关闭主理人通知巡检。"
    }

    func restartManagerWatchLoop(immediate: Bool) {
        managerWatchTask?.cancel()
        managerWatchTask = nil

        guard managerWatchSettings.isEnabled else { return }

        managerWatchTask = Task { [weak self] in
            guard let self else { return }
            if immediate {
                await self.performManagerWatchPoll(sendNotifications: true, manual: false)
            }
            while !Task.isCancelled {
                let interval = UInt64(max(5, self.managerWatchSettings.intervalMinutes) * 60) * 1_000_000_000
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { break }
                await self.performManagerWatchPoll(sendNotifications: true, manual: false)
            }
        }
    }

    func performManagerWatchPoll(sendNotifications: Bool, manual: Bool) async {
        let prodCode = managerWatchSettings.prodCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let managerName = managerWatchSettings.managerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prodCode.isEmpty, !managerName.isEmpty else {
            recordManagerWatchTimelineEvent(
                ManagerWatchTimelineEvent(
                    kind: .failed,
                    prodCode: prodCode,
                    managerName: managerName,
                    title: "巡检目标缺失",
                    detail: "通知巡检需要产品代码和主理人名称。",
                    errorMessage: "通知巡检需要产品代码和主理人名称。"
                )
            )
            if manual {
                errorMessage = "通知巡检需要产品代码和主理人名称。"
            }
            return
        }
        guard managerWatchSettings.watchForum || managerWatchSettings.watchPlatform else {
            recordManagerWatchTimelineEvent(
                ManagerWatchTimelineEvent(
                    kind: .failed,
                    prodCode: prodCode,
                    managerName: managerName,
                    title: "巡检范围为空",
                    detail: "至少要开启调仓或发言其中一项。",
                    errorMessage: "通知巡检至少要开启调仓或发言其中一项。"
                )
            )
            if manual {
                errorMessage = "通知巡检至少要开启\u{201c}调仓\u{201d}或\u{201c}发言\u{201d}其中一项。"
            }
            return
        }

        recordManagerWatchTimelineEvent(
            ManagerWatchTimelineEvent(
                kind: .pollStarted,
                prodCode: prodCode,
                managerName: managerName,
                title: manual ? "手动巡检开始" : "自动巡检开始",
                detail: managerWatchScopeText
            )
        )
        managerWatchSettings.lastCheckedAt = Self.timestampString()

        var updateTitles: [String] = []
        var pendingNotifications: [(title: String, subtitle: String, body: String, deepLink: NotificationDeepLinkPayload?)] = []
        var encounteredErrors: [String] = []

        if managerWatchSettings.watchForum {
            do {
                let snapshot = try await fetchForumWatchSnapshot(prodCode: prodCode, managerName: managerName)
                let previousID = managerWatchSettings.latestSeenForumRecordID
                let newRecords = unseenItems(snapshot.records, previousID: previousID)
                if previousID != nil, newRecords.isEmpty {
                    recordManagerWatchTimelineEvent(
                        ManagerWatchTimelineEvent(
                            kind: .duplicateSuppressed,
                            prodCode: prodCode,
                            managerName: managerName,
                            title: "发言无新增",
                            detail: "最新发言已在巡检基线内，未重复通知。"
                        )
                    )
                }
                if previousID != nil, !newRecords.isEmpty, sendNotifications {
                    if let latest = newRecords.first {
                        pendingNotifications.append((
                            title: "\(managerName) 有 \(newRecords.count) 条新发言",
                            subtitle: prodCode,
                            body: "\(latest.createdAt ?? "刚刚") · \(latest.titleText)",
                            deepLink: NotificationDeepLinkPayload(
                                type: .forumRecord,
                                targetID: latest.id,
                                prodCode: prodCode,
                                managerName: managerName
                            )
                        ))
                    }
                    updateTitles.append("新发言 \(newRecords.count) 条")
                    recordManagerWatchTimelineEvent(
                        ManagerWatchTimelineEvent(
                            kind: .forumHit,
                            prodCode: prodCode,
                            managerName: managerName,
                            title: "命中新发言 \(newRecords.count) 条",
                            detail: newRecords.first?.titleText ?? "发现新的主理人发言",
                            targetID: newRecords.first?.id
                        )
                    )
                }
                managerWatchSettings.latestSeenForumRecordID = snapshot.records.first?.id
            } catch {
                encounteredErrors.append("发言巡检失败：\(error.localizedDescription)")
                recordManagerWatchTimelineEvent(
                    ManagerWatchTimelineEvent(
                        kind: .failed,
                        prodCode: prodCode,
                        managerName: managerName,
                        title: "发言巡检失败",
                        detail: error.localizedDescription,
                        errorMessage: error.localizedDescription
                    )
                )
            }
        }

        if managerWatchSettings.watchPlatform {
            do {
                let platform = try await platformClient.fetchPlatformPayload(prodCode: prodCode)
                let actions = platform.actions ?? []
                let previousID = managerWatchSettings.latestSeenPlatformActionID
                let newActions = unseenItems(actions, previousID: previousID)
                if previousID != nil, newActions.isEmpty {
                    recordManagerWatchTimelineEvent(
                        ManagerWatchTimelineEvent(
                            kind: .duplicateSuppressed,
                            prodCode: prodCode,
                            managerName: managerName,
                            title: "调仓无新增",
                            detail: "最新调仓已在巡检基线内，未重复通知。"
                        )
                    )
                }
                if previousID != nil, !newActions.isEmpty, sendNotifications {
                    if let latest = newActions.first {
                        pendingNotifications.append((
                            title: "\(managerName) 有 \(newActions.count) 条新调仓",
                            subtitle: prodCode,
                            body: platformNotificationBody(for: latest),
                            deepLink: NotificationDeepLinkPayload(
                                type: .platformAction,
                                targetID: latest.id,
                                prodCode: prodCode,
                                managerName: managerName
                            )
                        ))
                    }
                    updateTitles.append("新调仓 \(newActions.count) 条")
                    recordManagerWatchTimelineEvent(
                        ManagerWatchTimelineEvent(
                            kind: .platformHit,
                            prodCode: prodCode,
                            managerName: managerName,
                            title: "命中新调仓 \(newActions.count) 条",
                            detail: newActions.first.map(platformNotificationBody(for:)) ?? "发现新的平台调仓",
                            targetID: newActions.first?.id
                        )
                    )
                }
                managerWatchSettings.latestSeenPlatformActionID = actions.first?.id
            } catch {
                encounteredErrors.append("调仓巡检失败：\(error.localizedDescription)")
                recordManagerWatchTimelineEvent(
                    ManagerWatchTimelineEvent(
                        kind: .failed,
                        prodCode: prodCode,
                        managerName: managerName,
                        title: "调仓巡检失败",
                        detail: error.localizedDescription,
                        errorMessage: error.localizedDescription
                    )
                )
            }
        }

        let previousErrorMessage = managerWatchSettings.lastErrorMessage
        if encounteredErrors.isEmpty {
            managerWatchSettings.lastSuccessAt = managerWatchSettings.lastCheckedAt
            managerWatchSettings.lastErrorMessage = nil
            if previousErrorMessage?.isEmpty == false {
                recordManagerWatchTimelineEvent(
                    ManagerWatchTimelineEvent(
                        kind: .recovered,
                        prodCode: prodCode,
                        managerName: managerName,
                        title: "巡检恢复",
                        detail: "上次失败后，本次巡检已恢复成功。"
                    )
                )
            } else if updateTitles.isEmpty {
                recordManagerWatchTimelineEvent(
                    ManagerWatchTimelineEvent(
                        kind: .noUpdates,
                        prodCode: prodCode,
                        managerName: managerName,
                        title: "巡检完成，无新增",
                        detail: managerWatchScopeText
                    )
                )
            }
        } else {
            managerWatchSettings.lastErrorMessage = encounteredErrors.joined(separator: "；")
            if manual {
                errorMessage = managerWatchSettings.lastErrorMessage ?? ""
            }
        }

        persistManagerWatchSettings(restartLoop: false)

        for item in pendingNotifications {
            await notificationManager.send(
                title: item.title,
                subtitle: item.subtitle,
                body: item.body,
                deepLink: item.deepLink
            )
        }

        if manual {
            if !pendingNotifications.isEmpty {
                noticeMessage = "巡检完成，已推送 \(updateTitles.joined(separator: "，"))。"
            } else if encounteredErrors.isEmpty {
                noticeMessage = "巡检完成，目前没有新的主理人调仓或发言。"
            }
        }
    }

    func fetchForumWatchSnapshot(prodCode: String, managerName: String) async throws -> SnapshotPayload {
        var watchForm = QueryFormState()
        watchForm.mode = .groupManager
        watchForm.prodCode = prodCode
        watchForm.managerName = managerName
        watchForm.userName = managerName
        watchForm.pages = "1"
        watchForm.pageSize = "10"
        return try await nativeClient.fetchSnapshot(form: watchForm, persist: false, outputDirectory: nil)
    }

    func unseenItems<T: Identifiable>(_ items: [T], previousID: T.ID?) -> [T] where T.ID: Equatable {
        guard let previousID else { return [] }
        if let index = items.firstIndex(where: { $0.id == previousID }) {
            guard index > 0 else { return [] }
            return Array(items.prefix(index))
        }
        return Array(items.prefix(min(items.count, 3)))
    }

    func platformNotificationBody(for action: PlatformActionPayload) -> String {
        let time = action.txnDate ?? action.createdAt ?? "刚刚"
        let target = action.fundName ?? action.fundCode ?? "未知标的"
        let change = action.valuationChangePct.map { String(format: "%+.2f%%", $0) } ?? "—"
        return "\(time) · \(action.displayTitle) · \(target) · 估值变化 \(change)"
    }

    func handleNotificationDeepLink(_ payload: NotificationDeepLinkPayload) {
        revealMainWindowIfNeeded()
        switch payload.type {
        case .platformAction:
            openPlatformAction(payload)
        case .forumRecord:
            openForumRecord(payload)
        case .workbenchTrend:
            openWorkbenchTrend(targetID: payload.targetID)
        case .personalWatchlist:
            selectedSection = .portfolio
        }
    }

    func openWorkbenchTrend(targetID: String? = nil) {
        selectedSection = .enhancement
        if let targetID {
            if targetID == "trade-signals" {
                // 旧深链：打开跟踪清单
                selectedWorkbenchSegment = .tracking
            } else if selectTrackingItem(forTargetID: targetID) {
                // 新深链：跟踪项 UUID → 跟踪清单并选中
                selectedWorkbenchSegment = .tracking
            } else {
                selectedWorkbenchSegment = .today
            }
        }
    }

    func openPlatformAction(_ payload: NotificationDeepLinkPayload) {
        selectedPlatformActivityTab = .adjustments
        selectedSection = .platform
        selectedPlatformActionID = payload.targetID

        let existingActions = platformPayload?.actions ?? []
        if existingActions.contains(where: { $0.id == payload.targetID }) {
            return
        }

        let prodCode = (payload.prodCode ?? managerWatchSettings.prodCode)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prodCode.isEmpty else {
            return
        }

        Task {
            do {
                let platform = try await platformClient.fetchPlatformPayload(prodCode: prodCode)
                platformPayload = platform
                _cachedMonthlyPlatformSummary = nil
                ensureSelectedPlatformAction(preferredID: payload.targetID)
                if selectedPlatformActionID == payload.targetID {
                    noticeMessage = "已定位到通知对应的调仓详情。"
                } else {
                    noticeMessage = "已刷新调仓列表，原通知对应动作可能已归档。"
                }
            } catch {
                errorMessage = "定位通知调仓失败：\(error.localizedDescription)"
            }
        }
    }

    func openForumRecord(_ payload: NotificationDeepLinkPayload) {
        selectedPlatformActivityTab = .forum
        selectedSection = .platform
        selectedPostID = payload.targetID

        if forumRecords.contains(where: { $0.id == payload.targetID }) {
            return
        }

        let prodCode = (payload.prodCode ?? managerWatchSettings.prodCode)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let managerName = (payload.managerName ?? managerWatchSettings.managerName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prodCode.isEmpty, !managerName.isEmpty else {
            return
        }

        Task {
            do {
                let snapshot = try await fetchForumWatchSnapshot(prodCode: prodCode, managerName: managerName)
                currentSnapshot = snapshot
                commentsPayload = nil
                ensureSelectedForumPost(preferredID: payload.targetID)
                if selectedPostID == payload.targetID {
                    noticeMessage = "已定位到通知对应的发言详情。"
                } else {
                    noticeMessage = "已刷新发言列表，原通知对应发言可能已归档。"
                }
            } catch {
                errorMessage = "定位通知发言失败：\(error.localizedDescription)"
            }
        }
    }
}
