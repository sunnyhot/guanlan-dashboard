import Foundation

// MARK: - Platform Filter Computed Properties

extension AppModel {
    var platformActionPresentation: PlatformActionPresentation {
        let telemetryStart = PerformanceTelemetry.start()
        let actions = platformPayload?.actions ?? []
        let presentation = PlatformActionPresentation.make(
            actions: actions,
            sideFilter: filterState.sideFilter,
            searchText: filterState.debouncedSearchText,
            currentPage: filterState.currentPage,
            pageSize: filterState.pageSize,
            buyCount: platformPayload?.buyCount,
            sellCount: platformPayload?.sellCount
        )
        PerformanceTelemetry.record(
            "platform.actions.presentation",
            startedAt: telemetryStart,
            metadata: [
                "inputCount": "\(actions.count)",
                "filteredCount": "\(presentation.filteredActions.count)",
                "pageCount": "\(presentation.pageActions.count)",
                "sideFilter": filterState.sideFilter.rawValue,
                "hasQuery": "\(!filterState.debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)"
            ]
        )
        return presentation
    }
}
