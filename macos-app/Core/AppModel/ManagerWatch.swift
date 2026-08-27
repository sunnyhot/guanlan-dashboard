import Foundation

// MARK: - Manager Watch

extension AppModel {
    var managerWatchAvailableAdjustmentSources: [ManagerWatchAdjustmentSource] {
        let prodCode = managerWatchSettings.prodCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            ManagerWatchAdjustmentSource.longWin(prodCode: prodCode)
        ] + alfaPortfolios.map {
            ManagerWatchAdjustmentSource.alfa(code: $0.poCode, name: $0.name)
        }
    }

    var managerWatchSelectedAdjustmentSources: [ManagerWatchAdjustmentSource] {
        let availableByID = Dictionary(
            uniqueKeysWithValues: managerWatchAvailableAdjustmentSources.map { ($0.id, $0) }
        )
        return managerWatchSettings.selectedAdjustmentSourceIDs
            .compactMap { sourceID in
                if let source = availableByID[sourceID] {
                    return source
                }
                guard let code = ManagerWatchAdjustmentSource.alfaCode(from: sourceID) else {
                    return nil
                }
                return .alfa(code: code, name: code)
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func reconcileManagerWatchAdjustmentSources() {
        let validIDs = Set(managerWatchAvailableAdjustmentSources.map(\.id))
        let removedIDs = managerWatchSettings.selectedAdjustmentSourceIDs.subtracting(validIDs)
        guard !removedIDs.isEmpty else { return }
        managerWatchSettings.selectedAdjustmentSourceIDs.subtract(removedIDs)
        for sourceID in removedIDs {
            managerWatchSettings.latestSeenAdjustmentIDs.removeValue(forKey: sourceID)
            managerWatchSettings.adjustmentBaselineTargetKeys.removeValue(forKey: sourceID)
        }
        persistManagerWatchSettings(restartLoop: false)
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
        persistManagerWatchSettings(restartLoop: false)
        if managerWatchSettings.isEnabled {
            restartManagerWatchLoop(immediate: isEnabled)
        }
    }

    func updateManagerWatchAdjustmentSource(_ source: ManagerWatchAdjustmentSource, isSelected: Bool) {
        if isSelected {
            managerWatchSettings.selectedAdjustmentSourceIDs.insert(source.id)
        } else {
            managerWatchSettings.selectedAdjustmentSourceIDs.remove(source.id)
        }
        managerWatchSettings.latestSeenAdjustmentIDs.removeValue(forKey: source.id)
        managerWatchSettings.adjustmentBaselineTargetKeys.removeValue(forKey: source.id)
        persistManagerWatchSettings(restartLoop: false)
        if managerWatchSettings.isEnabled {
            restartManagerWatchLoop(immediate: true)
        }
    }

    func updateManagerWatchNotificationsEnabled(_ isEnabled: Bool) {
        Task {
            if isEnabled {
                let granted = await notificationManager.requestAuthorizationIfNeeded()
                managerWatchSettings.notificationsEnabled = granted
                managerWatchSettings.lastNotificationErrorMessage = granted
                    ? nil
                    : "系统通知权限未开启"
                persistManagerWatchSettings(restartLoop: false)
                noticeMessage = granted
                    ? "已开启巡检系统通知。"
                    : "巡检仍会运行，但系统通知权限未开启。"
            } else {
                managerWatchSettings.notificationsEnabled = false
                managerWatchSettings.lastNotificationErrorMessage = nil
                persistManagerWatchSettings(restartLoop: false)
                noticeMessage = "已关闭系统通知，巡检记录仍会继续更新。"
            }
        }
    }

    func saveManagerWatchConfiguration() {
        managerWatchSettings.prodCode = managerWatchSettings.prodCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
        managerWatchSettings.managerName = managerWatchSettings.managerName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        persistManagerWatchSettings(restartLoop: false)
        if managerWatchSettings.isEnabled {
            restartManagerWatchLoop(immediate: true)
        }
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
        if isEnabled, managerWatchSettings.notificationsEnabled {
            let granted = await notificationManager.requestAuthorizationIfNeeded()
            if !granted {
                managerWatchSettings.notificationsEnabled = false
                managerWatchSettings.lastNotificationErrorMessage = "系统通知权限未开启"
            }
        }
        if isEnabled {
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
        if isEnabled {
            noticeMessage = managerWatchSettings.notificationsEnabled
                ? "已开启巡检，新增动态会发送系统通知。"
                : "已开启巡检；系统通知未启用，命中结果仍会保存在应用内。"
        } else {
            noticeMessage = "已关闭主理人通知巡检。"
        }
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
        guard !isManagerWatchPolling else {
            if manual {
                noticeMessage = "巡检正在进行，请稍候。"
            }
            return
        }
        isManagerWatchPolling = true
        defer { isManagerWatchPolling = false }

        let prodCode = managerWatchSettings.prodCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let managerName = managerWatchSettings.managerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let adjustmentSources = managerWatchSelectedAdjustmentSources

        guard managerWatchSettings.watchForum || !adjustmentSources.isEmpty else {
            completeManagerWatchValidationFailure(
                title: "巡检范围为空",
                detail: "至少选择一个调仓来源或开启论坛发言巡检。",
                prodCode: prodCode,
                managerName: managerName,
                manual: manual
            )
            return
        }
        if managerWatchSettings.watchForum, prodCode.isEmpty || managerName.isEmpty {
            completeManagerWatchValidationFailure(
                title: "论坛巡检目标缺失",
                detail: "论坛发言巡检需要产品代码和主理人名称。",
                prodCode: prodCode,
                managerName: managerName,
                manual: manual
            )
            return
        }
        if adjustmentSources.contains(where: { $0.kind == .longWin && $0.code.isEmpty }) {
            completeManagerWatchValidationFailure(
                title: "长赢调仓目标缺失",
                detail: "长赢调仓巡检需要产品代码。",
                prodCode: prodCode,
                managerName: managerName,
                manual: manual
            )
            return
        }

        managerWatchSettings.lastCheckedAt = Self.timestampString()

        var updateTitles: [String] = []
        var pendingNotifications: [(title: String, subtitle: String, body: String, deepLink: NotificationDeepLinkPayload?)] = []
        var encounteredErrors: [String] = []
        var notificationErrors: [String] = []
        var didEstablishBaseline = false

        if managerWatchSettings.watchForum {
            do {
                let snapshot = try await fetchForumWatchSnapshot(prodCode: prodCode, managerName: managerName)
                let baselineTargetKey = "forum|\(prodCode)|\(managerName)"
                let hasBaseline = managerWatchSettings.forumBaselineTargetKey == baselineTargetKey
                let previousID = managerWatchSettings.latestSeenForumRecordID
                let newRecords = unseenItems(
                    snapshot.records,
                    previousID: previousID,
                    baselineEstablished: hasBaseline
                )
                if !hasBaseline {
                    didEstablishBaseline = true
                }
                if hasBaseline, !newRecords.isEmpty {
                    updateTitles.append("论坛发言 \(newRecords.count) 条")
                    managerWatchSettings.lastHitAt = managerWatchSettings.lastCheckedAt
                    if sendNotifications,
                       managerWatchSettings.notificationsEnabled,
                       let latest = newRecords.first {
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
                managerWatchSettings.forumBaselineTargetKey = baselineTargetKey
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

        for source in adjustmentSources {
            do {
                let platform = try await fetchManagerWatchAdjustmentPayload(for: source)
                let actions = platform.actions ?? []
                let hasBaseline = managerWatchSettings.adjustmentBaselineTargetKeys[source.id]
                    == source.baselineTargetKey
                let previousID = managerWatchSettings.latestSeenAdjustmentIDs[source.id]
                let newActions = unseenItems(
                    actions,
                    previousID: previousID,
                    baselineEstablished: hasBaseline
                )
                if !hasBaseline {
                    didEstablishBaseline = true
                }
                if hasBaseline, !newActions.isEmpty {
                    updateTitles.append("\(source.displayName) \(newActions.count) 条")
                    managerWatchSettings.lastHitAt = managerWatchSettings.lastCheckedAt
                    if sendNotifications,
                       managerWatchSettings.notificationsEnabled,
                       let latest = newActions.first {
                        pendingNotifications.append((
                            title: "\(source.displayName) 有 \(newActions.count) 条新调仓",
                            subtitle: source.detailText,
                            body: platformNotificationBody(for: latest),
                            deepLink: NotificationDeepLinkPayload(
                                type: .platformAction,
                                targetID: latest.id,
                                prodCode: source.kind == .longWin ? source.code : nil,
                                managerName: source.name,
                                adjustmentSourceKind: source.kind,
                                adjustmentSourceCode: source.code
                            )
                        ))
                    }
                    recordManagerWatchTimelineEvent(
                        ManagerWatchTimelineEvent(
                            kind: .platformHit,
                            prodCode: source.code,
                            managerName: source.displayName,
                            title: "命中\(source.displayName) \(newActions.count) 条",
                            detail: newActions.first.map(platformNotificationBody(for:)) ?? "发现新的平台调仓",
                            targetID: newActions.first?.id
                        )
                    )
                }
                managerWatchSettings.latestSeenAdjustmentIDs[source.id] = actions.first?.id
                managerWatchSettings.adjustmentBaselineTargetKeys[source.id] = source.baselineTargetKey
            } catch {
                encounteredErrors.append("\(source.displayName)失败：\(error.localizedDescription)")
                recordManagerWatchTimelineEvent(
                    ManagerWatchTimelineEvent(
                        kind: .failed,
                        prodCode: source.code,
                        managerName: source.displayName,
                        title: "\(source.displayName)巡检失败",
                        detail: error.localizedDescription,
                        errorMessage: error.localizedDescription
                    )
                )
            }
        }

        var canSendNotifications = managerWatchSettings.notificationsEnabled
        if !pendingNotifications.isEmpty, canSendNotifications {
            canSendNotifications = await notificationManager.requestAuthorizationIfNeeded()
            if !canSendNotifications {
                managerWatchSettings.notificationsEnabled = false
                notificationErrors.append("系统通知权限未开启")
            }
        }
        if canSendNotifications {
            for item in pendingNotifications {
                do {
                    try await notificationManager.send(
                        title: item.title,
                        subtitle: item.subtitle,
                        body: item.body,
                        deepLink: item.deepLink
                    )
                } catch {
                    notificationErrors.append(error.localizedDescription)
                }
            }
        }

        let previousErrorMessage = managerWatchSettings.lastErrorMessage
        if encounteredErrors.isEmpty {
            managerWatchSettings.lastSuccessAt = managerWatchSettings.lastCheckedAt
            managerWatchSettings.lastErrorMessage = nil
            if !updateTitles.isEmpty {
                managerWatchSettings.lastResultSummary = "命中 \(updateTitles.joined(separator: "、"))"
            } else if didEstablishBaseline {
                managerWatchSettings.lastResultSummary = "巡检完成，已静默建立新目标基线"
            } else {
                managerWatchSettings.lastResultSummary = "巡检完成，无新增动态"
            }
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
            } else if manual, updateTitles.isEmpty {
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
            managerWatchSettings.lastResultSummary = "巡检失败：\(managerWatchSettings.lastErrorMessage ?? "")"
            if manual {
                errorMessage = managerWatchSettings.lastErrorMessage ?? ""
            }
        }
        managerWatchSettings.lastNotificationErrorMessage = notificationErrors.isEmpty
            ? nil
            : "系统通知发送失败：\(notificationErrors.joined(separator: "；"))"
        if !notificationErrors.isEmpty {
            managerWatchSettings.lastResultSummary = [
                managerWatchSettings.lastResultSummary,
                managerWatchSettings.lastNotificationErrorMessage
            ]
            .compactMap { $0 }
            .joined(separator: "；")
        }

        persistManagerWatchSettings(restartLoop: false)

        if manual {
            if !updateTitles.isEmpty {
                let deliveryText = pendingNotifications.isEmpty
                    ? "，结果已记录"
                    : (notificationErrors.isEmpty ? "，系统通知已发送" : "，但系统通知发送失败")
                noticeMessage = "巡检完成，命中 \(updateTitles.joined(separator: "、"))\(deliveryText)。"
            } else if encounteredErrors.isEmpty {
                noticeMessage = managerWatchSettings.lastResultSummary ?? "巡检完成，目前没有新增动态。"
            }
        }
    }

    func completeManagerWatchValidationFailure(
        title: String,
        detail: String,
        prodCode: String,
        managerName: String,
        manual: Bool
    ) {
        managerWatchSettings.lastCheckedAt = Self.timestampString()
        managerWatchSettings.lastErrorMessage = detail
        managerWatchSettings.lastResultSummary = "\(title)：\(detail)"
        persistManagerWatchSettings(restartLoop: false)
        recordManagerWatchTimelineEvent(
            ManagerWatchTimelineEvent(
                kind: .failed,
                prodCode: prodCode,
                managerName: managerName,
                title: title,
                detail: detail,
                errorMessage: detail
            )
        )
        if manual {
            errorMessage = detail
        }
    }

    func fetchManagerWatchAdjustmentPayload(
        for source: ManagerWatchAdjustmentSource
    ) async throws -> PlatformPayload {
        switch source.kind {
        case .longWin:
            return try await platformClient.fetchPlatformPayload(prodCode: source.code)
        case .alfa:
            return try await alfaClient.fetchAlfaPayload(poCode: source.code)
        }
    }

    func fetchForumWatchSnapshot(prodCode: String, managerName: String) async throws -> SnapshotPayload {
        var watchForm = QueryFormState()
        watchForm.mode = .groupManager
        watchForm.prodCode = prodCode
        watchForm.managerName = managerName
        watchForm.userName = managerName
        watchForm.pages = "1"
        watchForm.pageSize = "50"
        return try await nativeClient.fetchSnapshot(form: watchForm)
    }

    func unseenItems<T: Identifiable>(
        _ items: [T],
        previousID: T.ID?,
        baselineEstablished: Bool
    ) -> [T] where T.ID: Equatable {
        guard baselineEstablished else { return [] }
        guard let previousID else {
            return Array(items.prefix(min(items.count, 20)))
        }
        if let index = items.firstIndex(where: { $0.id == previousID }) {
            guard index > 0 else { return [] }
            return Array(items.prefix(index))
        }
        return Array(items.prefix(min(items.count, 20)))
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
        case .portfolioValuationAlert:
            selectedSection = .portfolio
        case .investmentIntelligenceSection:
            // W3.1 链路 A 完成通知深链:进 AI 研判页并滚动到对应区段锚点。
            selectedSection = .enhancement
            pendingInvestmentSectionAnchor = InvestmentTodayResearchRow.Kind(rawValue: payload.targetID)
        }
    }

    func openWorkbenchTrend(targetID: String? = nil) {
        selectedSection = .enhancement
        if let targetID {
            // 通知深链跳到 AI 研判单页；命中跟踪项时设置 selectedTrendTrackingItemID，
            // 页面会监听它并自动展开底部折叠的旧趋势跟踪清单。
            _ = selectTrackingItem(forTargetID: targetID)
        }
    }

    func openPlatformAction(_ payload: NotificationDeepLinkPayload) {
        selectedPlatformActivityTab = .adjustments
        selectedSection = .platform

        if payload.adjustmentSourceKind == .alfa,
           let poCode = payload.adjustmentSourceCode,
           alfaPortfolios.contains(where: { $0.poCode == poCode }) {
            selectedPlatformAdjustmentViewMode = .alfa
            selectedAlfaPoCode = poCode
            selectedAlfaActionID = payload.targetID
            if alfaPayload?.prodCode == poCode,
               (alfaPayload?.actions ?? []).contains(where: { $0.id == payload.targetID }) {
                return
            }
            Task {
                await selectAlfaPortfolio(poCode)
                selectedAlfaActionID = payload.targetID
                if !(alfaPayload?.actions ?? []).contains(where: { $0.id == payload.targetID }) {
                    noticeMessage = "已刷新投顾组合，原通知对应动作可能已归档。"
                }
            }
            return
        }

        selectedPlatformAdjustmentViewMode = .longWin
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
