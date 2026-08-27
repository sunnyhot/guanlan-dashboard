import SwiftUI

// MARK: - 持仓资产分类编辑器（sheet；产品重构 §6.2 / §8）
//
// 列出正权重持仓的解析结果（用户显式 / 股票规则 / 系统识别 / 待归类），
// 用户可为任何持仓显式选择五类之一——用户事件不被系统识别覆盖。

struct AssetClassAssignmentEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    struct Row: Identifiable {
        let id: String
        let name: String
        let code: String
        let assetType: PersonalAssetType
        var current: StrategicAssetClassification
    }

    @State private var rows: [Row] = []
    @State private var expandedUnresolved = true
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppPalette.spaceL) {
            header
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: AppPalette.spaceS) {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                    if rows.isEmpty {
                        Text("暂无正权重持仓。")
                            .font(AppPalette.appFont(.footnote))
                            .foregroundStyle(AppPalette.muted)
                    }
                }
                .padding(.horizontal, 1)
            }
            footer
        }
        .padding(AppPalette.spaceL)
        .frame(width: 560, height: 460)
        .onAppear(perform: reload)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("持仓资产归类")
                .font(AppPalette.appFont(.title3, weight: .bold))
            Text("为待归类的持仓选择战略资产类（股票 / 固收 / 商品 / 现金 / 另类）。你的选择不会被系统自动识别覆盖。")
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            if let unresolvedCount = unresolvedCount, unresolvedCount > 0 {
                Text("\(unresolvedCount) 项待归类")
                    .font(AppPalette.appFont(.footnote, weight: .medium))
                    .foregroundStyle(AppPalette.warning)
            }
            Spacer()
            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.appPrimary)
                .controlSize(.small)
        }
    }

    private var unresolvedCount: Int? {
        rows.filter {
            if case .unresolved = $0.current { return true }
            return false
        }.count
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: AppPalette.spaceM) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: AppPalette.spaceS) {
                    Text(row.name.isEmpty ? row.code : row.name)
                        .font(AppPalette.appFont(.subheadline, weight: .medium))
                    Text(row.code)
                        .font(AppPalette.appFont(.caption, design: .monospaced))
                        .foregroundStyle(AppPalette.muted)
                }
                Text(originText(row.current))
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(originTint(row.current))
            }
            Spacer(minLength: 0)
            // v4.4.1 修复：selection 用 Optional——未归类显示「待归类」而不是
            // 默认「股票」（旧实现里 unresolved 默认 .equity，再选「股票」不触发
            // set，表现为「不能保存」）
            Picker(
                "资产类",
                selection: Binding(
                    get: { resolvedSelection(row) },
                    set: { newValue in
                        guard let newValue else { return }   // 选「待归类」不写事件
                        save(row: row, assetClass: newValue)
                    }
                )
            ) {
                Text("待归类").tag(AssetClass?.none)
                ForEach(AssetClass.allCases, id: \.self) { assetClass in
                    Text(IntelligencePresentationFormatter.assetClassName(assetClass))
                        .tag(AssetClass?.some(assetClass))
                }
            }
            .labelsHidden()
            .frame(width: 124)
            .disabled(row.assetType == .stock)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, AppPalette.spaceS)
        .background(
            row.current == .unresolved
                ? AppPalette.warning.opacity(0.05) : Color.clear,
            in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
    }

    /// 股票行按规则恒为股票（分类是事实不是选择）。
    private func resolvedSelection(_ row: Row) -> AssetClass? {
        if row.assetType == .stock { return .equity }
        return row.current.assetClass
    }

    private func save(row: Row, assetClass: AssetClass) {
        // v4.4.1 修复：失败必须可见（此前 _ = 吞结果，runtime 未就绪 /
        // 写入失败时用户毫无感知，表现为「不能保存」）
        switch model.saveAssetClassAssignment(
            subjectKey: row.id, assetClass: assetClass
        ) {
        case .success:
            saveError = nil
            // 乐观更新本地行（不等异步 reload——picker 立即反映选择）
            if let index = rows.firstIndex(where: { $0.id == row.id }) {
                rows[index].current = .resolved(assetClass, origin: .user)
            }
            reload()
        case .failure(let error):
            saveError = "\(error.title)：\(error.message)（诊断码 \(error.diagnosticCode)）"
        }
    }

    // MARK: - 数据装配（AppModel published → 行快照）

    private func reload() {
        guard let runtime = model.intelligenceRuntime else { return }
        let rowsInput = model.personalAssetRows
        let disclosures = model.portfolioLookThroughSnapshot?.disclosures ?? [:]
        Task.detached(priority: .userInitiated) {
            let assignments = (try? runtime.assignmentStore.currentAssignments()) ?? [:]
            let resolved = StrategicAssetClassificationResolver.resolve(
                rows: rowsInput, assignments: assignments,
                disclosures: disclosures, now: Date())
            let pending = rowsInput
                .filter { $0.effectiveHoldingAmount > 0 && !($0.fundCode ?? "").isEmpty }
                .sorted { ($0.fundName, $0.key) < ($1.fundName, $1.key) }
                .map { row in
                    Row(
                        id: "fund|\(row.fundCode ?? "")",
                        name: row.fundName,
                        code: row.fundCode ?? "",
                        assetType: row.assetType,
                        current: resolved.classification["fund|\(row.fundCode ?? "")"] ?? .unresolved)
                }
            await MainActor.run {
                self.rows = pending
            }
        }
    }

    private func originText(_ classification: StrategicAssetClassification) -> String {
        switch classification {
        case let .resolved(_, origin):
            switch origin {
            case .user: return "你选择的分类"
            case .stockRule: return "股票（规则）"
            case .systemInferred(let date): return "系统识别（披露 \(date)）"
            }
        case .unresolved:
            return "待归类——不生成执行计划"
        }
    }

    private func originTint(_ classification: StrategicAssetClassification) -> Color {
        switch classification {
        case .resolved:
            return AppPalette.muted
        case .unresolved:
            return AppPalette.warning
        }
    }
}
