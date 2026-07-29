import SwiftUI

/// 带模糊搜索建议的代码输入框。用户输入名称/拼音/代码，实时显示匹配的基金和股票列表。
/// 选择一条后自动填充代码，并通知外部。
struct FundSearchField: View {
    @Binding var code: String
    var onSelect: (FundSearchResult) -> Void
    var label: String = "代码或名称"
    var placeholder: String = "搜索基金/股票名称、代码"

    @State private var results: [FundSearchResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var showResults = false
    @FocusState private var isFocused: Bool

    private let client = FundSearchClient()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(AppPalette.appFont(.footnote, weight: .medium))
                    .foregroundStyle(AppPalette.muted)
                TextField(label, text: $code, prompt: Text(placeholder))
                    .font(AppPalette.appFont(.body))
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onChange(of: code) { _, newValue in
                        handleSearchChange(newValue)
                    }
                if !code.isEmpty {
                    Button {
                        code = ""
                        results = []
                        showResults = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(AppPalette.appFont(.footnote))
                            .foregroundStyle(AppPalette.muted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                    .stroke(showResults ? AppPalette.brand.opacity(0.5) : AppPalette.hairline.opacity(AppPalette.borderLight), lineWidth: 1)
            )

            if showResults && !results.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { result in
                        Button {
                            code = result.code
                            onSelect(result)
                            showResults = false
                            isFocused = false
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(result.name)
                                        .font(AppPalette.appFont(.body, weight: .medium))
                                        .foregroundStyle(AppPalette.ink)
                                        .lineLimit(1)
                                    Text("\(result.code) · \(result.category)")
                                        .font(AppPalette.appFont(.caption))
                                        .foregroundStyle(AppPalette.muted)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(AppPalette.appFont(.caption))
                                    .foregroundStyle(AppPalette.muted)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                        .stroke(AppPalette.hairline.opacity(AppPalette.borderLight), lineWidth: 1)
                )
                .shadow(color: AppPalette.sectionShadowColor, radius: AppPalette.sectionShadowRadius, y: AppPalette.sectionShadowY)
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if showResults && isSearching {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("搜索中…")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                        .stroke(AppPalette.hairline.opacity(AppPalette.borderLight), lineWidth: 1)
                )
                .padding(.top, 2)
            } else if showResults && code.count >= 1 && results.isEmpty && !isSearching {
                Text("没有匹配「\(code)」的结果")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                            .stroke(AppPalette.hairline.opacity(AppPalette.borderLight), lineWidth: 1)
                    )
                    .padding(.top, 2)
            }
        }
    }

    private func handleSearchChange(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()

        guard !trimmed.isEmpty else {
            results = []
            showResults = false
            return
        }

        showResults = isFocused
        isSearching = true

        searchTask = Task {
            // 防抖：输入停顿 300ms 后再搜索
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            let searchResults = await client.search(trimmed)

            await MainActor.run {
                guard !Task.isCancelled else { return }
                results = searchResults
                isSearching = false
                showResults = isFocused || !searchResults.isEmpty
            }
        }
    }
}
