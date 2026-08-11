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
        loadManagerWatchTimeline()
        loadPortfolioInsightSnapshots()
        loadTrendAnalysisState()
        loadMarketCloseReviewArchive()
        loadNextHourGuidanceState()
        loadTrendTrackingState()
        loadInvestmentIntelligenceState()
    }

    func loadManagerWatchTimeline() {
        guard let managerWatchTimelineFileURL else { return }
        do {
            managerWatchTimelineEvents = try ManagerWatchTimelineStore().load(from: managerWatchTimelineFileURL)
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

    func recordManagerWatchTimelineEvent(_ event: ManagerWatchTimelineEvent) {
        guard let managerWatchTimelineFileURL else { return }
        do {
            try ManagerWatchTimelineStore().append(event, to: managerWatchTimelineFileURL)
            managerWatchTimelineEvents = try ManagerWatchTimelineStore().load(from: managerWatchTimelineFileURL)
        } catch {
            managerWatchTimelineEvents = ManagerWatchTimelineStore.pruned(managerWatchTimelineEvents + [event])
            errorMessage = error.localizedDescription
        }
    }

    func recordPortfolioInsightSnapshotIfPossible(createdAt: String? = nil) {
        guard let portfolioInsightSnapshotsFileURL, !personalAssetRows.isEmpty else { return }
        let snapshot = PortfolioInsightSnapshot.make(
            rows: personalAssetRows,
            createdAt: createdAt ?? Self.timestampString()
        )
        do {
            try PortfolioSnapshotInsightStore().append(snapshot, to: portfolioInsightSnapshotsFileURL)
            portfolioInsightSnapshots = try PortfolioSnapshotInsightStore().load(from: portfolioInsightSnapshotsFileURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
