import SwiftUI

struct PlatformSearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    let onSubmit: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppPalette.muted)
                .font(AppPalette.appFont(.body))

            TextField("搜索基金名称或代码…", text: $text)
                .textFieldStyle(.plain)
                .font(AppPalette.appFont(.headline))
                .foregroundStyle(AppPalette.ink)
                .onSubmit { onSubmit() }
                .focused($isFocused)
                .onReceive(NotificationCenter.default.publisher(for: .qiemanFocusSearch)) { _ in
                    isFocused = true
                }

            if !text.isEmpty {
                Button {
                    text = ""
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppPalette.muted)
                        .font(AppPalette.appFont(.body))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                .stroke(isFocused ? AppPalette.brand.opacity(0.50) : AppPalette.line.opacity(0.45), lineWidth: 1)
        )
    }
}
