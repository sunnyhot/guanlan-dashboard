import AppKit
import Foundation

extension AppModel {
    var managerWatchTimelineSummary: ManagerWatchTimelineSummary {
        ManagerWatchTimelineSummary.make(events: managerWatchTimelineEvents)
    }

    var portfolioSnapshotInsightSummary: PortfolioSnapshotInsightSummary {
        PortfolioSnapshotInsightSummary.make(
            snapshots: portfolioInsightSnapshots,
            currentRows: personalAssetRows
        )
    }

    func loadEnhancementState() {
        loadMonthlyReportExportMetadata()
        loadManagerWatchTimeline()
        loadImportUndoSnapshot()
        loadPortfolioInsightSnapshots()
        loadTrendAnalysisState()
        loadNextHourGuidanceState()
        loadTradeSignalState()
        loadTrendTrackingState()
    }

    func loadMonthlyReportExportMetadata() {
        guard let monthlyReportExportMetadataURL else { return }
        do {
            lastMonthlyReportExport = try MonthlyReportExportMetadataStore().load(from: monthlyReportExportMetadataURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadManagerWatchTimeline() {
        guard let managerWatchTimelineFileURL else { return }
        do {
            managerWatchTimelineEvents = try ManagerWatchTimelineStore().load(from: managerWatchTimelineFileURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadImportUndoSnapshot() {
        guard let importUndoSnapshotFileURL else { return }
        do {
            importUndoSnapshot = try ImportUndoSnapshotStore().load(from: importUndoSnapshotFileURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadPortfolioInsightSnapshots() {
        guard let portfolioInsightSnapshotsFileURL else { return }
        do {
            portfolioInsightSnapshots = try PortfolioSnapshotInsightStore().load(from: portfolioInsightSnapshotsFileURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyMonthlyReportToPasteboard(_ report: MonthlyReportSummary) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report.markdown, forType: .string)
        noticeMessage = "已复制月报 Markdown。"
    }

    func archiveMonthlyReport(overwriteConfirmed: Bool = false) {
        guard let dataDirectoryURL else {
            errorMessage = "应用数据目录还没准备好，暂时无法导出月报。"
            return
        }

        do {
            let metadata = try MonthlyReportExporter().archive(
                report: monthlyReportSummary,
                in: dataDirectoryURL,
                exportedAt: Self.timestampString(),
                overwriteConfirmed: overwriteConfirmed
            )
            try persistMonthlyReportExportMetadata(metadata)
            pendingOverwriteReportURL = nil
            noticeMessage = "已导出月报：\(URL(fileURLWithPath: metadata.filePath).lastPathComponent)"
        } catch MonthlyReportExportError.archiveAlreadyExists(let url) {
            pendingOverwriteReportURL = url
            errorMessage = "月报已存在，确认覆盖后可重新导出：\(url.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveMonthlyReportAs(to url: URL) {
        do {
            let metadata = try MonthlyReportExporter().saveAs(
                report: monthlyReportSummary,
                to: url,
                exportedAt: Self.timestampString()
            )
            try persistMonthlyReportExportMetadata(metadata)
            noticeMessage = "已另存月报：\(url.lastPathComponent)"
        } catch {
            errorMessage = "月报写入失败：\(url.path)；\(error.localizedDescription)"
        }
    }

    func recordManagerWatchTimelineEvent(_ event: ManagerWatchTimelineEvent) {
        guard let managerWatchTimelineFileURL else { return }
        do {
            try ManagerWatchTimelineStore().append(event, to: managerWatchTimelineFileURL)
            managerWatchTimelineEvents = try ManagerWatchTimelineStore().load(from: managerWatchTimelineFileURL)
        } catch {
            managerWatchTimelineEvents = ManagerWatchTimelineStore.pruned(managerWatchTimelineEvents + [event])
        }
    }

    func recordPortfolioInsightSnapshotIfPossible(createdAt: String? = nil) {
        guard let portfolioInsightSnapshotsFileURL, !personalAssetRows.isEmpty else { return }
        let snapshot = PortfolioInsightSnapshot.make(rows: personalAssetRows, createdAt: createdAt ?? Self.timestampString())
        do {
            try PortfolioSnapshotInsightStore().append(snapshot, to: portfolioInsightSnapshotsFileURL)
            portfolioInsightSnapshots = try PortfolioSnapshotInsightStore().load(from: portfolioInsightSnapshotsFileURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func prepareImportPreview(target: PersonalDataImportTarget, mode: PersonalDataSaveMode) {
        do {
            let createdAt = Self.timestampString()
            if draft(for: target).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                activeImportPreviewSession = emptyImportPreview(target: target, mode: mode, createdAt: createdAt)
                selectedEnhancementTab = .importPreview
                return
            }

            switch target {
            case .holdings:
                let imported = try importedPortfolioHoldings(from: portfolioDraft)
                activeImportPreviewSession = ImportPreviewSession.makeHoldings(
                    imported: imported,
                    existing: userPortfolioHoldings,
                    mode: mode,
                    store: portfolioStore,
                    createdAt: createdAt
                )
            case .pendingTrades:
                let imported = try importedPendingTrades(from: pendingTradesDraft)
                activeImportPreviewSession = ImportPreviewSession.makePendingTrades(
                    imported: imported,
                    existing: pendingTrades,
                    mode: mode,
                    store: pendingTradesStore,
                    createdAt: createdAt
                )
            case .investmentPlans:
                let imported = try importedInvestmentPlans(from: investmentPlansDraft)
                activeImportPreviewSession = ImportPreviewSession.makeInvestmentPlans(
                    imported: imported,
                    existing: investmentPlans,
                    mode: mode,
                    store: investmentPlansStore,
                    createdAt: createdAt
                )
            }
            selectedEnhancementTab = .importPreview
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirmActiveImportPreview() {
        guard let session = activeImportPreviewSession, session.canConfirm else {
            errorMessage = "当前录入预览存在阻塞项，不能确认写入。"
            return
        }

        do {
            switch session.target {
            case .holdings:
                try confirmHoldingsImportPreview(mode: session.mode, createdAt: session.createdAt)
            case .pendingTrades:
                try confirmPendingTradesImportPreview(mode: session.mode, createdAt: session.createdAt)
            case .investmentPlans:
                try confirmInvestmentPlansImportPreview(mode: session.mode, createdAt: session.createdAt)
            }
            activeImportPreviewSession = nil
            selectedEnhancementTab = .importPreview
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var canUndoLatestImport: Bool {
        guard let importUndoSnapshot else { return false }
        return importUndoSnapshot.isValid(
            currentHoldings: userPortfolioHoldings,
            currentPendingTrades: pendingTrades,
            currentInvestmentPlans: investmentPlans
        )
    }

    func undoLatestImport() {
        guard let snapshot = importUndoSnapshot else {
            errorMessage = "没有可撤销的录入。"
            return
        }
        guard snapshot.isValid(
            currentHoldings: userPortfolioHoldings,
            currentPendingTrades: pendingTrades,
            currentInvestmentPlans: investmentPlans
        ) else {
            invalidateLatestImportUndo()
            errorMessage = "本地数据已变化，无法安全撤销上次录入。"
            return
        }

        do {
            if let portfolioFileURL {
                userPortfolioHoldings = snapshot.restoreHoldings
                if userPortfolioHoldings.isEmpty {
                    try portfolioStore.delete(at: portfolioFileURL)
                } else {
                    try portfolioStore.save(userPortfolioHoldings, to: portfolioFileURL)
                }
                userPortfolioSnapshot = nil
            }
            if let pendingTradeFileURL {
                pendingTrades = snapshot.restorePendingTrades.sorted { $0.occurredAt > $1.occurredAt }
                if pendingTrades.isEmpty {
                    try pendingTradesStore.delete(at: pendingTradeFileURL)
                } else {
                    try pendingTradesStore.save(pendingTrades, to: pendingTradeFileURL)
                }
            }
            if let investmentPlanFileURL {
                investmentPlans = snapshot.restoreInvestmentPlans.sorted(by: sortInvestmentPlans)
                if investmentPlans.isEmpty {
                    try investmentPlansStore.delete(at: investmentPlanFileURL)
                } else {
                    try investmentPlansStore.save(investmentPlans, to: investmentPlanFileURL)
                }
            }
            clearCachedComputedProperties()
            rebuildAssetRows()
            invalidateLatestImportUndo()
            noticeMessage = "已撤销上次录入。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func invalidateLatestImportUndo() {
        importUndoSnapshot = nil
        guard let importUndoSnapshotFileURL else { return }
        try? ImportUndoSnapshotStore().delete(at: importUndoSnapshotFileURL)
    }

    private func confirmHoldingsImportPreview(mode: PersonalDataSaveMode, createdAt: String) throws {
        guard let portfolioFileURL, let importUndoSnapshotFileURL else {
            throw LiveRefreshError(message: "应用数据目录还没准备好，暂时无法保存持仓。")
        }
        let imported = try importedPortfolioHoldings(from: portfolioDraft)
        let nextHoldings = mode == .merge ? portfolioStore.merging(imported, into: userPortfolioHoldings) : imported
        let snapshot = ImportUndoSnapshot.make(
            target: .holdings,
            mode: mode,
            createdAt: createdAt.isEmpty ? Self.timestampString() : createdAt,
            beforeHoldings: userPortfolioHoldings,
            beforePendingTrades: pendingTrades,
            beforeInvestmentPlans: investmentPlans,
            afterHoldings: nextHoldings,
            afterPendingTrades: pendingTrades,
            afterInvestmentPlans: investmentPlans
        )

        try ImportUndoSnapshotStore().save(snapshot, to: importUndoSnapshotFileURL)
        userPortfolioHoldings = nextHoldings
        userPortfolioSnapshot = nil
        rebuildAssetRows()
        try portfolioStore.save(nextHoldings, to: portfolioFileURL)
        portfolioDraft = ""
        importUndoSnapshot = snapshot
        noticeMessage = "已\(mode.actionText)保存 \(imported.count) 条个人持仓，正在按代码补全名称。"
        Task {
            let resolvedCount = await resolveAndPersistPortfolioNames()
            try? await refreshUserPortfolio(updateNotice: false)
            if resolvedCount > 0 {
                noticeMessage = "已\(mode.actionText)保存 \(imported.count) 条个人持仓，并通过代码补全 \(resolvedCount) 个名称。"
            } else {
                noticeMessage = "已\(mode.actionText)保存 \(imported.count) 条个人持仓。"
            }
        }
    }

    private func confirmPendingTradesImportPreview(mode: PersonalDataSaveMode, createdAt: String) throws {
        guard let pendingTradeFileURL, let importUndoSnapshotFileURL else {
            throw LiveRefreshError(message: "应用数据目录还没准备好，暂时无法保存买入中记录。")
        }
        let imported = try importedPendingTrades(from: pendingTradesDraft)
        let nextTrades = mode == .merge
            ? pendingTradesStore.merging(imported, into: pendingTrades)
            : imported.sorted { $0.occurredAt > $1.occurredAt }
        let snapshot = ImportUndoSnapshot.make(
            target: .pendingTrades,
            mode: mode,
            createdAt: createdAt.isEmpty ? Self.timestampString() : createdAt,
            beforeHoldings: userPortfolioHoldings,
            beforePendingTrades: pendingTrades,
            beforeInvestmentPlans: investmentPlans,
            afterHoldings: userPortfolioHoldings,
            afterPendingTrades: nextTrades,
            afterInvestmentPlans: investmentPlans
        )

        try ImportUndoSnapshotStore().save(snapshot, to: importUndoSnapshotFileURL)
        pendingTrades = nextTrades
        pendingTradesDraft = ""
        clearPendingTradeCaches()
        rebuildAssetRows()
        try pendingTradesStore.save(nextTrades, to: pendingTradeFileURL)
        importUndoSnapshot = snapshot
        noticeMessage = "已\(mode.actionText)保存 \(imported.count) 条买入中记录。"
        Task { await applyPersonalAssetAutomation() }
    }

    private func confirmInvestmentPlansImportPreview(mode: PersonalDataSaveMode, createdAt: String) throws {
        guard let investmentPlanFileURL, let importUndoSnapshotFileURL else {
            throw LiveRefreshError(message: "应用数据目录还没准备好，暂时无法保存定投计划。")
        }
        let imported = try importedInvestmentPlans(from: investmentPlansDraft)
        let nextPlans = mode == .merge
            ? investmentPlansStore.merging(imported, into: investmentPlans).sorted(by: sortInvestmentPlans)
            : imported.sorted(by: sortInvestmentPlans)
        let snapshot = ImportUndoSnapshot.make(
            target: .investmentPlans,
            mode: mode,
            createdAt: createdAt.isEmpty ? Self.timestampString() : createdAt,
            beforeHoldings: userPortfolioHoldings,
            beforePendingTrades: pendingTrades,
            beforeInvestmentPlans: investmentPlans,
            afterHoldings: userPortfolioHoldings,
            afterPendingTrades: pendingTrades,
            afterInvestmentPlans: nextPlans
        )

        try ImportUndoSnapshotStore().save(snapshot, to: importUndoSnapshotFileURL)
        investmentPlans = nextPlans
        investmentPlansDraft = ""
        clearInvestmentPlanCaches()
        rebuildAssetRows()
        try investmentPlansStore.save(nextPlans, to: investmentPlanFileURL)
        importUndoSnapshot = snapshot
        noticeMessage = "已\(mode.actionText)保存 \(imported.count) 条定投计划。"
        Task { await applyPersonalAssetAutomation() }
    }

    private func emptyImportPreview(
        target: PersonalDataImportTarget,
        mode: PersonalDataSaveMode,
        createdAt: String
    ) -> ImportPreviewSession {
        switch target {
        case .holdings:
            return ImportPreviewSession.makeHoldings(imported: [], existing: userPortfolioHoldings, mode: mode, store: portfolioStore, createdAt: createdAt)
        case .pendingTrades:
            return ImportPreviewSession.makePendingTrades(imported: [], existing: pendingTrades, mode: mode, store: pendingTradesStore, createdAt: createdAt)
        case .investmentPlans:
            return ImportPreviewSession.makeInvestmentPlans(imported: [], existing: investmentPlans, mode: mode, store: investmentPlansStore, createdAt: createdAt)
        }
    }

    private func persistMonthlyReportExportMetadata(_ metadata: MonthlyReportExportMetadata) throws {
        guard let monthlyReportExportMetadataURL else { return }
        try MonthlyReportExportMetadataStore().save(metadata, to: monthlyReportExportMetadataURL)
        lastMonthlyReportExport = metadata
    }
}
