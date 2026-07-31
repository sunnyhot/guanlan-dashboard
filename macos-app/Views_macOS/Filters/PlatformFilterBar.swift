import SwiftUI

struct PlatformFilterBar: View {
    @ObservedObject var filterState: PlatformFilterState
    @EnvironmentObject var model: AppModel

    var body: some View {
        let presentation = model.platformActionPresentation

        ViewThatFits {
            wideLayout(counts: presentation.counts)
            narrowLayout(counts: presentation.counts)
            compactLayout(counts: presentation.counts)
        }
        .padding(12)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: AppPalette.panelRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.panelRadius)
                .stroke(AppPalette.line.opacity(0.50), lineWidth: 1)
        )
    }

    // MARK: - Wide: single row toolbar

    private func wideLayout(counts: PlatformActionCounts) -> some View {
        HStack(spacing: 12) {
            PlatformSidePicker(
                selection: $filterState.sideFilter,
                counts: counts
            )

            PlatformSearchField(
                text: $filterState.searchText,
                onSubmit: { filterState.debouncedSearchText = filterState.searchText },
                onClear: { filterState.searchText = ""; filterState.debouncedSearchText = ""; filterState.currentPage = 0 }
            )
            .frame(maxWidth: 240)

            Spacer(minLength: 8)

            HoldingCountBadge(count: model.platformHoldings.count)
        }
    }

    // MARK: - Narrow: two rows

    private func narrowLayout(counts: PlatformActionCounts) -> some View {
        VStack(spacing: 8) {
            HStack {
                PlatformSidePicker(
                    selection: $filterState.sideFilter,
                    counts: counts
                )

                Spacer()

                HoldingCountBadge(count: model.platformHoldings.count)
            }

            PlatformSearchField(
                text: $filterState.searchText,
                onSubmit: { filterState.debouncedSearchText = filterState.searchText },
                onClear: { filterState.searchText = ""; filterState.debouncedSearchText = ""; filterState.currentPage = 0 }
            )
        }
    }

    // MARK: - Compact: Menu dropdown

    private func compactLayout(counts: PlatformActionCounts) -> some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(PlatformSideFilter.allCases) { filter in
                    Button {
                        filterState.sideFilter = filter
                    } label: {
                        Label(menuLabel(for: filter, counts: counts), systemImage: filter.systemImage)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: filterState.sideFilter.systemImage)
                    Text(filterState.sideFilter.rawValue)
                    Image(systemName: "chevron.down")
                        .font(AppPalette.appFont(.caption))
                }
                .font(AppPalette.appFont(.body, weight: .medium))
                .foregroundStyle(AppPalette.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(AppPalette.card, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                        .stroke(AppPalette.line.opacity(0.45), lineWidth: 1)
                )
            }

            PlatformSearchField(
                text: $filterState.searchText,
                onSubmit: { filterState.debouncedSearchText = filterState.searchText },
                onClear: { filterState.searchText = ""; filterState.debouncedSearchText = ""; filterState.currentPage = 0 }
            )
        }
    }

    private func menuLabel(for filter: PlatformSideFilter, counts: PlatformActionCounts) -> String {
        let count: Int
        switch filter {
        case .all: count = counts.all
        case .buy: count = counts.buy
        case .sell: count = counts.sell
        }
        return "\(filter.rawValue) (\(count))"
    }
}
