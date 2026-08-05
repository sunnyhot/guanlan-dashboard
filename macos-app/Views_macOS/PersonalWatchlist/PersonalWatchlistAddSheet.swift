import SwiftUI

struct PersonalWatchlistAddSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var category: PersonalWatchlistCategory = .offExchangeFund
    @State private var codeText = ""
    @State private var resolution: PersonalAssetCodeResolution?
    @State private var isResolving = false
    @State private var isSaving = false
    @State private var inlineErrorMessage = ""
    @State private var lookupRequestID = UUID()
    @State private var lookupTask: Task<Void, Never>?
    @FocusState private var isCodeFocused: Bool

    private var lookupKey: String {
        "\(category.rawValue):\(codeText.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: category == .stock ? "chart.line.uptrend.xyaxis" : "star.circle")
                    .font(AppPalette.appFont(.title, weight: .semibold))
                    .foregroundStyle(categoryTint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("添加关注")
                        .font(AppPalette.appFont(.title2, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text("选择标的类型并输入代码。加入时会读取当前有效价格，作为之后对比的固定起点。")
                        .font(AppPalette.appFont(.subheadline))
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer()
            }

            Picker("类型", selection: $category) {
                ForEach(PersonalWatchlistCategory.allCases) { category in
                    Text(category.displayName).tag(category)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 6) {
                Text("代码或名称")
                    .font(AppPalette.appFont(.footnote, weight: .semibold))
                    .foregroundStyle(AppPalette.muted)
                FundSearchField(code: $codeText, onSelect: { result in
                    codeText = result.code
                    category = result.assetType == .stock ? .stock : .offExchangeFund
                    resolution = PersonalAssetCodeResolution(
                        assetType: result.assetType,
                        code: result.code,
                        displayName: result.name
                    )
                    isCodeFocused = false
                })
            }

            lookupStatus

            if !inlineErrorMessage.isEmpty {
                ToastBar(
                    text: inlineErrorMessage,
                    tint: AppPalette.danger,
                    onDismiss: { inlineErrorMessage = "" }
                )
            }

            HStack(spacing: 10) {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.appSecondary)
                    .keyboardShortcut(.cancelAction)

                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("读取起始价…")
                        }
                    } else {
                        Text("开始关注")
                    }
                }
                .buttonStyle(.appPrimary)
                .tint(categoryTint)
                .disabled(resolution == nil || isSaving)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
        .task {
            isCodeFocused = true
        }
        .onChange(of: lookupKey, initial: true) { _, _ in
            scheduleCodeResolution()
        }
        .onDisappear {
            lookupTask?.cancel()
        }
    }

    @ViewBuilder
    private var lookupStatus: some View {
        HStack(spacing: AppPalette.spaceS) {
            if isResolving {
                ProgressView()
                    .controlSize(.small)
                Text("正在确认代码与名称…")
            } else if let resolution {
                Image(systemName: "checkmark.circle.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text(resolution.displayName ?? "未查到名称，将按代码保存")
                        .fontWeight(.semibold)
                    Text("\(category.displayName) · \(resolution.code)")
                        .font(AppPalette.appFont(.caption, design: .monospaced))
                }
            } else if codeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Image(systemName: "info.circle")
                Text("输入代码后会自动核对标的。")
            } else {
                Image(systemName: "exclamationmark.circle")
                Text("暂未识别这个代码，请检查类型与代码。")
            }
            Spacer()
        }
        .font(AppPalette.appFont(.subheadline))
        .foregroundStyle(resolution == nil ? AppPalette.muted : categoryTint)
        .padding(.horizontal, 10)
        .padding(.vertical, AppPalette.spaceS)
        .background(
            (resolution == nil ? AppPalette.muted : categoryTint)
                .opacity(AppPalette.accentSubtle),
            in: RoundedRectangle(cornerRadius: AppPalette.cardRadius)
        )
    }

    private var categoryTint: Color {
        switch category {
        case .offExchangeFund: return AppPalette.brand
        case .onExchangeFund: return AppPalette.accentWarm
        case .stock: return AppPalette.info
        }
    }

    private var codePlaceholder: String {
        switch category {
        case .offExchangeFund: return "例如 021550"
        case .onExchangeFund: return "例如 510300 / 159915"
        case .stock: return "例如 600519 / HK:00700 / US:AAPL"
        }
    }

    private func scheduleCodeResolution() {
        lookupTask?.cancel()
        inlineErrorMessage = ""
        let requestedCategory = category
        let code = codeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let prepared = model.preparePersonalWatchlistCode(
            category: requestedCategory,
            codeText: code
        )
        resolution = prepared
        guard let prepared else {
            isResolving = false
            return
        }

        isResolving = true
        let requestID = UUID()
        lookupRequestID = requestID
        lookupTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            let resolved = await model.resolvePersonalWatchlistCode(
                category: requestedCategory,
                codeText: code
            )
            guard !Task.isCancelled, requestID == lookupRequestID else { return }

            resolution = resolved ?? prepared
            isResolving = false
        }
    }

    private func save() async {
        guard let prepared = model.preparePersonalWatchlistCode(category: category, codeText: codeText) else {
            return
        }
        lookupTask?.cancel()
        isResolving = false
        let currentResolution = resolution.flatMap { candidate in
            candidate.assetType == prepared.assetType
                && candidate.code == prepared.code
                && candidate.stockMarket == prepared.stockMarket
                && candidate.fundMarket == prepared.fundMarket
                ? candidate
                : nil
        }
        inlineErrorMessage = ""
        isSaving = true
        defer { isSaving = false }

        if await model.addPersonalWatchlistItem(
            category: category,
            resolution: currentResolution ?? prepared
        ) {
            dismiss()
        } else {
            inlineErrorMessage = model.errorMessage.isEmpty ? "添加关注失败，请稍后重试。" : model.errorMessage
            model.errorMessage = ""
        }
    }
}
