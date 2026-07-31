import SwiftUI

private enum PersonalInvestmentPlanFormField: Hashable {
    case planType, fundName, fundCode, schedule, amount, investedPeriods, cumulativeAmount, paymentMethod, nextExecution, note
}

struct PersonalInvestmentPlanAddSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var planTypeText = "定投"
    @State private var fundNameText = ""
    @State private var fundCodeText = ""
    @State private var scheduleText = ""
    @State private var amountText = ""
    @State private var investedPeriodsText = ""
    @State private var cumulativeAmountText = ""
    @State private var paymentMethodText = ""
    @State private var nextExecutionDateText = ""
    @State private var status: PersonalInvestmentPlanStatusOption = .active
    @State private var noteText = ""
    @State private var inlineErrorMessage = ""
    @FocusState private var focusedField: PersonalInvestmentPlanFormField?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "calendar.badge.clock")
                    .font(AppPalette.appFont(.title, weight: .semibold))
                    .foregroundStyle(AppPalette.info)
                VStack(alignment: .leading, spacing: 4) {
                    Text("添加计划档案")
                        .font(AppPalette.appFont(.title2, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text("手动补录定投、智能定投或涨跌幅计划，保存后可继续修改状态。")
                        .font(AppPalette.appFont(.subheadline))
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 10) {
                planField("计划类型", text: $planTypeText, placeholder: "定投 / 智能定投", field: .planType)
                planField("基金名称", text: $fundNameText, placeholder: "基金名称", field: .fundName)
                planField("基金代码", text: $fundCodeText, placeholder: "例如 013308", field: .fundCode)
                planField("计划说明", text: $scheduleText, placeholder: "每周三定投 / 每周五定投-涨跌幅模式", field: .schedule)
                planField("金额", text: $amountText, placeholder: "500.00元 / 250.00~1,000.00元", field: .amount)
                planField("已投期数", text: $investedPeriodsText, placeholder: "可留空", field: .investedPeriods)
                planField("累计投入", text: $cumulativeAmountText, placeholder: "可留空", field: .cumulativeAmount)
                planField("支付方式", text: $paymentMethodText, placeholder: "可留空", field: .paymentMethod)
                planField("下次执行", text: $nextExecutionDateText, placeholder: "进行中计划必填", field: .nextExecution)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("状态")
                    .font(AppPalette.appFont(.subheadline, weight: .medium))
                    .foregroundStyle(AppPalette.muted)
                Picker("状态", selection: $status) {
                    ForEach(PersonalInvestmentPlanStatusOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 260)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("备注")
                    .font(AppPalette.appFont(.subheadline, weight: .medium))
                    .foregroundStyle(AppPalette.muted)
                TextField("可留空", text: $noteText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                            .stroke(AppPalette.line.opacity(0.7), lineWidth: 1)
                    )
                    .focused($focusedField, equals: .note)
            }

            inlinePlanError

            HStack(spacing: 10) {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .buttonStyle(.appSecondary)
                .keyboardShortcut(.cancelAction)

                Button("添加") {
                    inlineErrorMessage = ""
                    if model.addInvestmentPlan(
                        planTypeLabel: planTypeText,
                        fundName: fundNameText,
                        fundCode: fundCodeText,
                        scheduleText: scheduleText,
                        amountText: amountText,
                        investedPeriodsText: investedPeriodsText,
                        cumulativeInvestedAmountText: cumulativeAmountText,
                        paymentMethod: paymentMethodText,
                        nextExecutionDate: nextExecutionDateText,
                        status: status.rawValue,
                        note: noteText
                    ) {
                        dismiss()
                    } else {
                        presentInlineError()
                    }
                }
                .buttonStyle(.appPrimary)
                .tint(AppPalette.info)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 620)
    }

    private var inlinePlanError: some View {
        Group {
            if !inlineErrorMessage.isEmpty {
                ToastBar(text: inlineErrorMessage, tint: AppPalette.danger, onDismiss: { inlineErrorMessage = "" })
            }
        }
    }

    private func planField(_ label: String, text: Binding<String>, placeholder: String, field: PersonalInvestmentPlanFormField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(AppPalette.appFont(.subheadline, weight: .medium))
                .foregroundStyle(AppPalette.muted)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                        .stroke(AppPalette.line.opacity(0.7), lineWidth: 1)
                )
                .focused($focusedField, equals: field)
        }
    }

    private func presentInlineError() {
        inlineErrorMessage = model.errorMessage.isEmpty ? "保存失败，请检查填写内容。" : model.errorMessage
        model.errorMessage = ""
        if planTypeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            focusedField = .planType
        } else if fundNameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  fundCodeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            focusedField = .fundName
        } else if scheduleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            focusedField = .schedule
        } else if amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            focusedField = .amount
        } else if status == .active, nextExecutionDateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            focusedField = .nextExecution
        }
    }
}

struct PersonalInvestmentPlanEditSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let plan: PersonalInvestmentPlan

    @State private var planTypeText: String
    @State private var fundNameText: String
    @State private var fundCodeText: String
    @State private var scheduleText: String
    @State private var amountText: String
    @State private var investedPeriodsText: String
    @State private var cumulativeAmountText: String
    @State private var paymentMethodText: String
    @State private var nextExecutionDateText: String
    @State private var status: PersonalInvestmentPlanStatusOption
    @State private var noteText: String
    @State private var inlineErrorMessage = ""
    @FocusState private var focusedField: PersonalInvestmentPlanFormField?

    init(plan: PersonalInvestmentPlan) {
        self.plan = plan
        _planTypeText = State(initialValue: plan.planTypeLabel)
        _fundNameText = State(initialValue: plan.fundName)
        _fundCodeText = State(initialValue: plan.fundCode ?? "")
        _scheduleText = State(initialValue: plan.scheduleText)
        _amountText = State(initialValue: plan.amountText)
        _investedPeriodsText = State(initialValue: plan.investedPeriods.map(String.init) ?? "")
        _cumulativeAmountText = State(initialValue: plan.cumulativeInvestedAmount.map { Self.amountFieldText($0) } ?? "")
        _paymentMethodText = State(initialValue: plan.paymentMethod ?? "")
        _nextExecutionDateText = State(initialValue: plan.nextExecutionDate)
        _status = State(initialValue: PersonalInvestmentPlanStatusOption(status: plan.normalizedStatus))
        _noteText = State(initialValue: plan.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(AppPalette.appFont(.title, weight: .semibold))
                    .foregroundStyle(AppPalette.brand)
                VStack(alignment: .leading, spacing: 4) {
                    Text("编辑定投计划")
                        .font(AppPalette.appFont(.title2, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text(plan.fundCode.map { "\(plan.fundName)（\($0)）" } ?? plan.fundName)
                        .font(AppPalette.appFont(.subheadline))
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 10) {
                planField("计划类型", text: $planTypeText, placeholder: "定投 / 智能定投", field: .planType)
                planField("基金名称", text: $fundNameText, placeholder: "基金名称", field: .fundName)
                planField("基金代码", text: $fundCodeText, placeholder: "例如 013308", field: .fundCode)
                planField("计划说明", text: $scheduleText, placeholder: "每周三定投 / 每周五定投-涨跌幅模式", field: .schedule)
                planField("金额", text: $amountText, placeholder: "500.00元 / 250.00~1,000.00元", field: .amount)
                planField("已投期数", text: $investedPeriodsText, placeholder: "例如 12", field: .investedPeriods)
                planField("累计投入", text: $cumulativeAmountText, placeholder: "例如 6000.00", field: .cumulativeAmount)
                planField("支付方式", text: $paymentMethodText, placeholder: "余额宝", field: .paymentMethod)
                planField("下次执行", text: $nextExecutionDateText, placeholder: "2026-05-01(星期五)", field: .nextExecution)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("状态")
                    .font(AppPalette.appFont(.subheadline, weight: .medium))
                    .foregroundStyle(AppPalette.muted)
                Picker("状态", selection: $status) {
                    ForEach(PersonalInvestmentPlanStatusOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 260)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("备注")
                    .font(AppPalette.appFont(.subheadline, weight: .medium))
                    .foregroundStyle(AppPalette.muted)
                TextField("可留空", text: $noteText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                            .stroke(AppPalette.line.opacity(0.7), lineWidth: 1)
                    )
                    .focused($focusedField, equals: .note)
            }

            inlinePlanError

            HStack(spacing: 10) {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .buttonStyle(.appSecondary)
                .keyboardShortcut(.cancelAction)

                Button("保存") {
                    inlineErrorMessage = ""
                    if model.updateInvestmentPlan(
                        plan.id,
                        planTypeLabel: planTypeText,
                        fundName: fundNameText,
                        fundCode: fundCodeText,
                        scheduleText: scheduleText,
                        amountText: amountText,
                        investedPeriodsText: investedPeriodsText,
                        cumulativeInvestedAmountText: cumulativeAmountText,
                        paymentMethod: paymentMethodText,
                        nextExecutionDate: nextExecutionDateText,
                        status: status.rawValue,
                        note: noteText
                    ) {
                        dismiss()
                    } else {
                        presentInlineError()
                    }
                }
                .buttonStyle(.appPrimary)
                .tint(AppPalette.brand)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 620)
    }

    private var inlinePlanError: some View {
        Group {
            if !inlineErrorMessage.isEmpty {
                ToastBar(text: inlineErrorMessage, tint: AppPalette.danger, onDismiss: { inlineErrorMessage = "" })
            }
        }
    }

    private func planField(_ label: String, text: Binding<String>, placeholder: String, field: PersonalInvestmentPlanFormField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(AppPalette.appFont(.subheadline, weight: .medium))
                .foregroundStyle(AppPalette.muted)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.controlRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                        .stroke(AppPalette.line.opacity(0.7), lineWidth: 1)
                )
                .focused($focusedField, equals: field)
        }
    }

    private func presentInlineError() {
        inlineErrorMessage = model.errorMessage.isEmpty ? "保存失败，请检查填写内容。" : model.errorMessage
        model.errorMessage = ""
        if planTypeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            focusedField = .planType
        } else if fundNameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  fundCodeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            focusedField = .fundName
        } else if scheduleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            focusedField = .schedule
        } else if amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            focusedField = .amount
        } else if status == .active, nextExecutionDateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            focusedField = .nextExecution
        }
    }

    private static func amountFieldText(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.0000001 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.2f", value)
    }
}
