#if os(iOS)
import SwiftUI

// MARK: - iOS 估值告警管理(单资产)
//
// 复用 upsertPortfolioValuationAlertProfile/removePortfolioValuationAlertProfile。
// 展示该资产的告警规则列表,可添加/启用/禁用/删除单条规则。

struct IOSValuationAlertSheet: View {
    let row: PersonalAssetAggregateRow
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var profile: PortfolioValuationAlertProfile
    @State private var showingAddRule = false

    init(row: PersonalAssetAggregateRow) {
        self.row = row
        _profile = State(initialValue: PortfolioValuationAlertProfile(
            fundCode: row.fundCode ?? row.key,
            rules: [], breachedRuleIDs: [], lastTriggeredAt: [:]
        ))
    }

    var body: some View {
        NavigationStack {
            List {
                if profile.rules.isEmpty {
                    Section {
                        Text("暂无告警规则。点击右上角添加。").foregroundStyle(IOSDesign.muted)
                    }
                } else {
                    ForEach(profile.rules) { rule in
                        ruleRow(rule)
                    }
                    .onDelete { indexSet in
                        profile.rules.remove(atOffsets: indexSet)
                        save()
                    }
                }
            }
            .navigationTitle("估值告警")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAddRule = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingAddRule) {
                IOSAlertRuleEditSheet { newRule in
                    profile.rules.append(newRule)
                    save()
                }
            }
            .onAppear {
                if let code = row.fundCode {
                    profile = model.portfolioValuationAlertProfile(for: code)
                }
            }
        }
    }

    private func ruleRow(_ rule: PortfolioValuationAlertRule) -> some View {
        Toggle(isOn: Binding(
            get: { rule.isEnabled },
            set: {
                if let idx = profile.rules.firstIndex(where: { $0.id == rule.id }) {
                    profile.rules[idx].isEnabled = $0
                    save()
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(rule.side.displayName) · \(rule.metric.displayName)")
                    .font(IOSDesign.sansBody(14, weight: .medium))
                Text("\(rule.direction.displayName) \(thresholdText(rule))")
                    .font(IOSDesign.sansBody(12))
                    .foregroundStyle(IOSDesign.muted)
            }
        }
        .tint(IOSDesign.accent)
    }

    private func thresholdText(_ rule: PortfolioValuationAlertRule) -> String {
        switch rule.metric {
        case .estimatePrice: return String(format: "%.4f", rule.threshold)
        default: return String(format: "%.1f%%", rule.threshold)
        }
    }

    private func save() {
        model.upsertPortfolioValuationAlertProfile(profile)
    }
}

// MARK: - 添加告警规则 Sheet

struct IOSAlertRuleEditSheet: View {
    let onAdd: (PortfolioValuationAlertRule) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var metric: PortfolioValuationAlertMetric = .holdingProfitPct
    @State private var side: PortfolioValuationAlertSide = .sell
    @State private var direction: PortfolioValuationAlertDirection = .above
    @State private var thresholdText = "20"

    var body: some View {
        NavigationStack {
            Form {
                Picker("指标", selection: $metric) {
                    ForEach(PortfolioValuationAlertMetric.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("方向", selection: $side) {
                    ForEach(PortfolioValuationAlertSide.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("条件", selection: $direction) {
                    ForEach(PortfolioValuationAlertDirection.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                LabeledContent {
                    TextField(metric == .estimatePrice ? "净值,如 1.2345" : "百分比,如 20", text: $thresholdText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                } label: {
                    Text(metric == .estimatePrice ? "阈值" : "阈值(%)")
                }
            }
            .navigationTitle("添加规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("添加") { add() }.bold().disabled(threshold == nil)
                }
            }
        }
    }

    private var threshold: Double? {
        Double(thresholdText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func add() {
        guard let t = threshold else { return }
        onAdd(PortfolioValuationAlertRule(metric: metric, side: side, direction: direction, threshold: t))
        dismiss()
    }
}
#endif
