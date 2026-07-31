#if os(iOS)
import SwiftUI

// MARK: - iOS 关注列表
//
// 复用 personalWatchlistRecords + add/removePersonalWatchlistItem。
// 展示关注的基金/股票(代码解析名称)、起始价、最新价、涨跌。可添加/删除。

struct IOSPersonalWatchlistSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                if model.personalWatchlistRecords.isEmpty {
                    Section {
                        Text("暂无关注。点击右上角添加基金或股票。").foregroundStyle(IOSDesign.muted)
                    }
                } else {
                    ForEach(model.personalWatchlistRecords) { record in
                        watchlistRow(record)
                    }
                    .onDelete { indexSet in
                        for i in indexSet {
                            model.removePersonalWatchlistItem(model.personalWatchlistRecords[i].item.id)
                        }
                    }
                }
            }
            .navigationTitle("关注列表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .refreshable {
                try? await model.refreshPersonalWatchlist(updateNotice: true)
            }
            .sheet(isPresented: $showingAdd) {
                IOSAddWatchlistItemSheet()
            }
        }
    }

    private func watchlistRow(_ record: PersonalWatchlistRecord) -> some View {
        let item = record.item
        let baseline = record.baseline?.price
        let latest = record.dailyPoints.last?.price
        let change: Double? = {
            guard let b = baseline, let l = latest else { return nil }
            return l - b
        }()
        let changePct: Double? = {
            guard let b = baseline, let c = change, b > 0 else { return nil }
            return c / b * 100
        }()
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.normalizedName ?? item.code)
                        .font(IOSDesign.sansBody(15, weight: .medium))
                        .foregroundStyle(IOSDesign.ink)
                    Text(item.code).font(IOSDesign.sansBody(12)).foregroundStyle(IOSDesign.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if let latest {
                        Text(String(format: "%.4f", latest))
                            .font(IOSDesign.monoNumber(15))
                            .foregroundStyle(IOSDesign.ink)
                    } else {
                        Text("—").foregroundStyle(IOSDesign.muted)
                    }
                    if let changePct {
                        Text(String(format: "%+.2f%%", changePct))
                            .font(IOSDesign.monoNumber(12, weight: .medium))
                            .foregroundStyle(marketTone(for: changePct).color)
                    }
                }
            }
            if let baseline {
                Text("起始 \(String(format: "%.4f", baseline))")
                    .font(IOSDesign.sansBody(11))
                    .foregroundStyle(IOSDesign.muted)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 添加关注 Sheet

struct IOSAddWatchlistItemSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var codeText = ""
    @State private var category: PersonalWatchlistCategory = .offExchangeFund
    @State private var resolution: PersonalAssetCodeResolution?
    @State private var isResolving = false
    @State private var inlineError = ""

    private var lookupKey: String { codeText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $category) {
                    ForEach(PersonalWatchlistCategory.allCases) { Text($0.displayName).tag($0) }
                }
                Section("代码") {
                    TextField("基金/股票代码", text: $codeText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !statusText.isEmpty {
                        Label(statusText, systemImage: isResolving ? "arrow.clockwise" : "checkmark.circle.fill")
                            .font(IOSDesign.sansBody(13))
                            .foregroundStyle(IOSDesign.accent)
                    }
                }
                if !inlineError.isEmpty {
                    Section { Text(inlineError).foregroundStyle(AppPalette.marketGain) }
                }
            }
            .navigationTitle("添加关注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("添加") { submit() }.bold().disabled(resolution == nil || isResolving)
                }
            }
            .task(id: lookupKey) { await resolve() }
        }
    }

    private var statusText: String {
        if lookupKey.isEmpty { return "" }
        if isResolving { return "识别中…" }
        guard let resolution else { return "" }
        if let name = resolution.displayName, !name.isEmpty { return "✓ \(name)" }
        return "✓ 代码有效"
    }

    private func resolve() async {
        let code = lookupKey
        resolution = nil
        guard !code.isEmpty else { isResolving = false; return }
        isResolving = true
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }
        resolution = await model.resolvePersonalAssetCode(code)
        isResolving = false
    }

    private func submit() {
        inlineError = ""
        guard let resolution else { inlineError = "请输入有效代码。"; return }
        Task {
            let ok = await model.addPersonalWatchlistItem(category: category, resolution: resolution)
            await MainActor.run {
                if ok { dismiss() }
                else { inlineError = model.errorMessage.isEmpty ? "添加失败。" : model.errorMessage }
            }
        }
    }
}
#endif
