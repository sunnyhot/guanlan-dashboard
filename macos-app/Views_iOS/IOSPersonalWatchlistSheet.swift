#if os(iOS)
import SwiftUI
import Charts

// MARK: - iOS 关注列表
//
// 复用 personalWatchlistRecords + add/removePersonalWatchlistItem。
// 每行：名称/代码 + sparkline（30 日，自绘 Path 轻量版）+ 最新价/涨跌。
// 点击行 → 详情 Sheet（Swift Charts 大走势图 + 基准价 RuleMark）。

struct IOSPersonalWatchlistSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingAdd = false
    @State private var detailRecord: PersonalWatchlistRecord?

    var body: some View {
        NavigationStack {
            List {
                if model.personalWatchlistRecords.isEmpty {
                    Section {
                        Text("暂无关注。点击右上角添加基金或股票。").foregroundStyle(IOSDesign.muted)
                    }
                } else {
                    ForEach(model.personalWatchlistRecords) { record in
                        Button {
                            detailRecord = record
                        } label: {
                            IOSWatchlistRow(record: record) { detailRecord = record }
                        }
                        .buttonStyle(.plain)
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
            .sheet(item: $detailRecord) { record in
                IOSWatchlistDetailSheet(record: record)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

// MARK: - Sparkline（自绘 Path，轻量，避免每行嵌 Charts）

struct IOSWatchlistSparkline: View {
    let points: [Double]
    var tone: IOSStatTile.StatTone

    private var color: Color { tone.color }

    var body: some View {
        GeometryReader { geo in
            if points.count < 2 {
                Rectangle().fill(Color.clear)
            } else {
                let w = geo.size.width
                let h = geo.size.height
                let minV = points.min() ?? 0
                let maxV = points.max() ?? 1
                let range = max(maxV - minV, 0.0001)
                let stepX = w / CGFloat(points.count - 1)
                Path { p in
                    for (idx, value) in points.enumerated() {
                        let x = CGFloat(idx) * stepX
                        let y = h - CGFloat((value - minV) / range) * h
                        if idx == 0 { p.move(to: CGPoint(x: x, y: y)) }
                        else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

// MARK: - 共享关注行（首页关注卡 + 关注列表 Sheet 复用）

struct IOSWatchlistRow: View {
    let record: PersonalWatchlistRecord
    var showsBaseline: Bool = true
    var isPinned: Bool = false
    var onTap: (() -> Void)? = nil

    private var item: PersonalWatchlistItem { record.item }
    private var baseline: Double? { record.baseline?.price }
    private var latest: Double? { record.dailyPoints.last?.price }
    private var change: Double? {
        guard let b = baseline, let l = latest else { return nil }
        return l - b
    }
    private var changePct: Double? {
        guard let b = baseline, let c = change, b > 0 else { return nil }
        return c / b * 100
    }

    var body: some View {
        HStack(spacing: IOSDesign.spaceS) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: IOSDesign.spaceXS) {
                    Text(item.normalizedName ?? item.code)
                        .font(IOSDesign.sansBody(15, weight: .medium))
                        .foregroundStyle(IOSDesign.ink)
                        .lineLimit(1)
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(AppPalette.warning)
                    }
                }
                Text(item.code).font(IOSDesign.sansBody(12)).foregroundStyle(IOSDesign.muted)
                if showsBaseline, let baseline {
                    Text("起始 \(String(format: "%.4f", baseline))")
                        .font(IOSDesign.sansBody(11))
                        .foregroundStyle(IOSDesign.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            IOSWatchlistSparkline(points: Array(record.dailyPoints.suffix(30)).map(\.price), tone: marketTone(for: change))
                .frame(width: 64, height: 28)

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
        .contentShape(Rectangle())
        .padding(.vertical, IOSDesign.spaceXS)
        .onTapGesture { onTap?() }
    }
}

// MARK: - 关注详情 Sheet（大走势图 + 基准价）

struct IOSWatchlistDetailSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let record: PersonalWatchlistRecord

    private var baseline: Double? { record.baseline?.price }
    private var latest: Double? { record.dailyPoints.last?.price }
    private var points: [PersonalWatchlistDailyPoint] { record.dailyPoints }

    private var change: Double? {
        guard let b = baseline, let l = latest else { return nil }
        return l - b
    }
    private var changePct: Double? {
        guard let b = baseline, let c = change, b > 0 else { return nil }
        return c / b * 100
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: IOSDesign.spaceM) {
                    headerCard
                    if points.count >= 2 {
                        trendChart
                    } else {
                        IOSEmptyState(title: "走势数据不足", subtitle: "至少需要 2 个数据点才能绘制走势图。")
                    }
                }
                .padding(IOSDesign.spaceM)
            }
            .background(IOSDesign.paper)
            .navigationTitle(record.item.normalizedName ?? record.item.code)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
        }
    }

    private var headerCard: some View {
        IOSSectionCard(title: record.item.normalizedName ?? record.item.code, subtitle: record.item.code, icon: "star.fill") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: IOSDesign.spaceS) {
                IOSStatTile(title: "最新价", value: latest.map { String(format: "%.4f", $0) } ?? "—")
                IOSStatTile(title: "起始价", value: baseline.map { String(format: "%.4f", $0) } ?? "—")
                IOSStatTile(title: "涨跌", value: change.map { String(format: "%+.4f", $0) } ?? "—", tone: marketTone(for: change))
                IOSStatTile(title: "涨跌幅", value: changePct.map { String(format: "%+.2f%%", $0) } ?? "—", tone: marketTone(for: changePct))
            }
        }
    }

    private var trendChart: some View {
        IOSSectionCard(title: "价格走势", subtitle: "\(points.count) 个数据点", icon: "chart.line.uptrend.xyaxis") {
            Chart(points) { point in
                LineMark(
                    x: .value("日期", point.date),
                    y: .value("价格", point.price)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(IOSDesign.accent)
                .lineStyle(StrokeStyle(lineWidth: 2))

                AreaMark(
                    x: .value("日期", point.date),
                    y: .value("价格", point.price)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(
                    colors: [IOSDesign.accent.opacity(0.25), IOSDesign.accent.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                ))

                if let baseline {
                    RuleMark(y: .value("起始价", baseline))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(IOSDesign.muted.opacity(0.6))
                        .annotation(position: .topTrailing, spacing: 4) {
                            Text("起始")
                                .font(.system(size: 9))
                                .foregroundStyle(IOSDesign.muted)
                        }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisValueLabel {
                        if let s = value.as(String.self) {
                            Text(shortDate(s)).font(.system(size: 10))
                        }
                    }
                    AxisGridLine().foregroundStyle(IOSDesign.ink.opacity(0.08))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel().font(.system(size: 10))
                    AxisGridLine().foregroundStyle(IOSDesign.ink.opacity(0.08))
                }
            }
            .frame(height: 220)
        }
    }

    private func shortDate(_ raw: String) -> String {
        // 取 MM-dd 或 yyyy-MM-dd 前 10 位
        raw.count >= 10 ? String(raw.prefix(10)) : raw
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
