#if os(iOS)
import SwiftUI

// MARK: - iOS 待确认交易编辑 Sheet
//
// 复用 addPendingTrade/updatePendingTrade/deletePendingTrade。字段对齐
// macOS PersonalPendingTradeEditSheet,用 iOS Form 原生排版。

struct IOSPendingTradeEditSheet: View {
    let row: PersonalAssetAggregateRow?
    let trade: PersonalPendingTrade?
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var occurredAt = ""
    @State private var actionLabel = "买入"
    @State private var fundName = ""
    @State private var fundCode = ""
    @State private var targetFundName = ""
    @State private var targetFundCode = ""
    @State private var amountText = ""
    @State private var status = "交易进行中"
    @State private var note = ""
    @FocusState private var focused: Bool

    private var isEditing: Bool { trade != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("标的") {
                    TextField("基金名称", text: $fundName).focused($focused)
                    TextField("基金代码", text: $fundCode).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("交易") {
                    Picker("动作", selection: $actionLabel) {
                        ForEach(["买入", "卖出", "转换", "分红"], id: \.self) { Text($0).tag($0) }
                    }
                    TextField("金额,如 1000", text: $amountText).keyboardType(.decimalPad)
                    DatePicker("发生时间", selection: dateBinding, displayedComponents: .date)
                    Picker("状态", selection: $status) {
                        ForEach(["交易进行中", "已成交", "已撤销"], id: \.self) { Text($0).tag($0) }
                    }
                }
                if actionLabel == "转换" {
                    Section("转入标的(可选)") {
                        TextField("转入基金名称", text: $targetFundName)
                        TextField("转入基金代码", text: $targetFundCode).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                Section("备注") {
                    TextField("可留空", text: $note, axis: .vertical).lineLimit(2...4)
                }
                if isEditing {
                    Section { Button("删除此待确认交易", role: .destructive) { delete() } }
                }
            }
            .navigationTitle(isEditing ? "编辑待确认" : "添加待确认")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("保存") { submit() }.bold() }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { focused = false } }
            }
            .onAppear { loadInitial() }
        }
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                return f.date(from: occurredAt) ?? Date()
            },
            set: {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                occurredAt = f.string(from: $0)
            }
        )
    }

    private func loadInitial() {
        if let trade {
            occurredAt = String(trade.occurredAt.prefix(10))
            actionLabel = trade.actionLabel
            fundName = trade.fundName
            fundCode = trade.fundCode ?? ""
            targetFundName = trade.targetFundName ?? ""
            targetFundCode = trade.targetFundCode ?? ""
            amountText = trade.amountText
            status = trade.status
            note = trade.note ?? ""
        } else if let row {
            fundName = row.fundName
            fundCode = row.fundCode ?? ""
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            occurredAt = f.string(from: Date())
        } else {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            occurredAt = f.string(from: Date())
        }
    }

    private func submit() {
        let ok: Bool
        if let trade {
            ok = model.updatePendingTrade(
                trade.id,
                occurredAt: occurredAt, actionLabel: actionLabel,
                fundName: fundName, fundCode: fundCode,
                targetFundName: targetFundName, targetFundCode: targetFundCode,
                amountText: amountText, status: status, note: note
            )
        } else {
            ok = model.addPendingTrade(
                occurredAt: occurredAt, actionLabel: actionLabel,
                fundName: fundName, fundCode: fundCode,
                targetFundName: targetFundName, targetFundCode: targetFundCode,
                amountText: amountText, status: status, note: note
            )
        }
        if ok { dismiss() }
    }

    private func delete() {
        if let trade { model.deletePendingTrade(trade.id) }
        dismiss()
    }
}

// MARK: - iOS 投资计划编辑 Sheet

struct IOSInvestmentPlanEditSheet: View {
    let row: PersonalAssetAggregateRow?
    let plan: PersonalInvestmentPlan?
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var planTypeLabel = "定投"
    @State private var fundName = ""
    @State private var fundCode = ""
    @State private var scheduleText = ""
    @State private var amountText = ""
    @State private var investedPeriodsText = ""
    @State private var cumulativeInvestedAmountText = ""
    @State private var paymentMethod = ""
    @State private var nextExecutionDate = ""
    @State private var status = "进行中"
    @State private var note = ""
    @FocusState private var focused: Bool

    private var isEditing: Bool { plan != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("标的") {
                    TextField("基金名称", text: $fundName).focused($focused)
                    TextField("基金代码", text: $fundCode).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("计划") {
                    Picker("类型", selection: $planTypeLabel) {
                        ForEach(["定投", "网格", "止盈", "其他"], id: \.self) { Text($0).tag($0) }
                    }
                    TextField("周期,如 每月10日", text: $scheduleText)
                    TextField("每期金额,如 500", text: $amountText).keyboardType(.decimalPad)
                    TextField("已投期数", text: $investedPeriodsText).keyboardType(.numberPad)
                    TextField("累计已投金额", text: $cumulativeInvestedAmountText).keyboardType(.decimalPad)
                    TextField("支付方式,如 余额宝", text: $paymentMethod)
                    DatePicker("下次执行", selection: nextDateBinding, displayedComponents: .date)
                    Picker("状态", selection: $status) {
                        ForEach(["进行中", "已暂停", "已终止"], id: \.self) { Text($0).tag($0) }
                    }
                }
                Section("备注") {
                    TextField("可留空", text: $note, axis: .vertical).lineLimit(2...4)
                }
                if isEditing {
                    Section { Button("删除此投资计划", role: .destructive) { delete() } }
                }
            }
            .navigationTitle(isEditing ? "编辑计划" : "添加计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("保存") { submit() }.bold() }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { focused = false } }
            }
            .onAppear { loadInitial() }
        }
    }

    private var nextDateBinding: Binding<Date> {
        Binding(
            get: { DateFormatter.yyyyMMdd.date(from: nextExecutionDate) ?? Date() },
            set: { nextExecutionDate = DateFormatter.yyyyMMdd.string(from: $0) }
        )
    }

    private func loadInitial() {
        if let plan {
            planTypeLabel = plan.planTypeLabel
            fundName = plan.fundName
            fundCode = plan.fundCode ?? ""
            scheduleText = plan.scheduleText
            amountText = plan.amountText
            investedPeriodsText = plan.investedPeriods.map { String($0) } ?? ""
            cumulativeInvestedAmountText = plan.cumulativeInvestedAmount.map { String($0) } ?? ""
            paymentMethod = plan.paymentMethod ?? ""
            nextExecutionDate = String(plan.nextExecutionDate.prefix(10))
            status = plan.status
            note = plan.note ?? ""
        } else if let row {
            fundName = row.fundName
            fundCode = row.fundCode ?? ""
            nextExecutionDate = DateFormatter.yyyyMMdd.string(from: Date())
        } else {
            nextExecutionDate = DateFormatter.yyyyMMdd.string(from: Date())
        }
    }

    private func submit() {
        let ok: Bool
        if let plan {
            ok = model.updateInvestmentPlan(
                plan.id,
                planTypeLabel: planTypeLabel, fundName: fundName, fundCode: fundCode,
                scheduleText: scheduleText, amountText: amountText,
                investedPeriodsText: investedPeriodsText,
                cumulativeInvestedAmountText: cumulativeInvestedAmountText,
                paymentMethod: paymentMethod, nextExecutionDate: nextExecutionDate,
                status: status, note: note
            )
        } else {
            ok = model.addInvestmentPlan(
                planTypeLabel: planTypeLabel, fundName: fundName, fundCode: fundCode,
                scheduleText: scheduleText, amountText: amountText,
                investedPeriodsText: investedPeriodsText,
                cumulativeInvestedAmountText: cumulativeInvestedAmountText,
                paymentMethod: paymentMethod, nextExecutionDate: nextExecutionDate,
                status: status, note: note
            )
        }
        if ok { dismiss() }
    }

    private func delete() {
        if let plan { model.deleteInvestmentPlan(plan.id) }
        dismiss()
    }
}

// MARK: - 日期格式辅助

private extension DateFormatter {
    static let yyyyMMdd: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
#endif
