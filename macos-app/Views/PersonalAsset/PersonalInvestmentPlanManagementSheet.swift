import SwiftUI

struct PersonalInvestmentPlanManagementSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let row: PersonalAssetAggregateRow

    @State private var editingPlan: PersonalInvestmentPlan?
    @State private var deletingPlan: PersonalInvestmentPlan?
    @State private var inlineErrorMessage = ""

    private let planIDs: Set<UUID>

    init(row: PersonalAssetAggregateRow) {
        self.row = row
        self.planIDs = Set(row.plans.map(\.id))
    }

    private var plans: [PersonalInvestmentPlan] {
        model.investmentPlans
            .filter { planIDs.contains($0.id) }
            .sorted(by: comparePlans)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "calendar.badge.clock")
                    .font(AppPalette.appFont(.title, weight: .semibold))
                    .foregroundStyle(AppPalette.brand)
                VStack(alignment: .leading, spacing: 4) {
                    Text("管理定投计划")
                        .font(AppPalette.appFont(.title2, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text(row.fundCode.map { "\(row.fundName)（\($0)）" } ?? row.fundName)
                        .font(AppPalette.appFont(.subheadline))
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .buttonStyle(.appSecondary)
                .keyboardShortcut(.cancelAction)
            }

            if !inlineErrorMessage.isEmpty {
                ToastBar(text: inlineErrorMessage, tint: AppPalette.danger, onDismiss: { inlineErrorMessage = "" })
            }

            if plans.isEmpty {
                Text("这条资产当前没有定投计划。")
                    .font(AppPalette.appFont(.body))
                    .foregroundStyle(AppPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 10) {
                        ForEach(plans) { plan in
                            PersonalInvestmentPlanManageRow(
                                plan: plan,
                                onEdit: { editingPlan = plan },
                                onStatusChange: { status in
                                    inlineErrorMessage = ""
                                    model.updateInvestmentPlanStatus(plan.id, status: status.rawValue)
                                    captureModelError()
                                },
                                onDelete: { deletingPlan = plan }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 520)
            }
        }
        .padding(18)
        .frame(width: 720)
        .frame(minHeight: 360)
        .sheet(item: $editingPlan) { plan in
            PersonalInvestmentPlanEditSheet(plan: plan)
        }
        .alert("删除定投计划？", isPresented: deleteConfirmationBinding) {
            Button("删除", role: .destructive) {
                if let deletingPlan {
                    inlineErrorMessage = ""
                    model.deleteInvestmentPlan(deletingPlan.id)
                    captureModelError()
                }
                deletingPlan = nil
            }
            Button("取消", role: .cancel) {
                deletingPlan = nil
            }
        } message: {
            Text(deleteConfirmationMessage)
        }
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { deletingPlan != nil },
            set: { isPresented in
                if !isPresented {
                    deletingPlan = nil
                }
            }
        )
    }

    private var deleteConfirmationMessage: String {
        guard let deletingPlan else { return "" }
        let itemText = deletingPlan.fundCode.map { "\(deletingPlan.fundName)（\($0)）" } ?? deletingPlan.fundName
        return "会从本地保存的数据中删除 \(itemText) 的这条定投计划。这个操作不会影响任何外部账户。"
    }

    private func comparePlans(_ lhs: PersonalInvestmentPlan, _ rhs: PersonalInvestmentPlan) -> Bool {
        let lhsRank = statusRank(lhs)
        let rhsRank = statusRank(rhs)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        if lhs.nextExecutionDate != rhs.nextExecutionDate {
            return lhs.nextExecutionDate < rhs.nextExecutionDate
        }
        return lhs.fundName.localizedStandardCompare(rhs.fundName) == .orderedAscending
    }

    private func captureModelError() {
        guard !model.errorMessage.isEmpty else { return }
        inlineErrorMessage = model.errorMessage
        model.errorMessage = ""
    }

    private func statusRank(_ plan: PersonalInvestmentPlan) -> Int {
        if plan.isActivePlan { return 0 }
        if plan.isPausedPlan { return 1 }
        return 2
    }
}

private struct PersonalInvestmentPlanManageRow: View {
    let plan: PersonalInvestmentPlan
    let onEdit: () -> Void
    let onStatusChange: (PersonalInvestmentPlanStatusOption) -> Void
    let onDelete: () -> Void

    private var statusOption: PersonalInvestmentPlanStatusOption {
        PersonalInvestmentPlanStatusOption(status: plan.normalizedStatus)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(plan.planTypeLabel)
                            .font(AppPalette.appFont(.body, weight: .bold))
                            .foregroundStyle(plan.isDrawdownMode ? AppPalette.info : AppPalette.brand)
                        Text(plan.fundName)
                            .font(AppPalette.appFont(.headline, weight: .semibold))
                            .foregroundStyle(AppPalette.ink)
                            .lineLimit(1)
                            .help(plan.fundName)
                        ToolbarBadge(title: plan.normalizedStatus, tint: statusOption.tint)
                        if plan.isDrawdownMode {
                            ToolbarBadge(title: "涨跌幅模式", tint: AppPalette.info)
                        }
                    }
                    HStack(spacing: 8) {
                        if let fundCode = plan.fundCode, !fundCode.isEmpty {
                            Text(fundCode)
                        }
                        Text(plan.scheduleText)
                        Text(plan.nextExecutionDate.isEmpty ? "无下次时间" : plan.nextExecutionDate)
                    }
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(plan.amountRangeText)
                        .font(AppPalette.appFont(.title3, weight: .bold, design: .rounded))
                        .foregroundStyle(AppPalette.ink)
                    Text(plan.cumulativeInvestedAmount.map(currencyText) ?? "累计 —")
                        .font(AppPalette.appFont(.footnote))
                        .foregroundStyle(AppPalette.muted)
                }
            }

            HStack(spacing: 8) {
                Button {
                    onEdit()
                } label: {
                    Label("编辑", systemImage: "square.and.pencil")
                }
                .buttonStyle(.appSecondary)

                Menu {
                    ForEach(PersonalInvestmentPlanStatusOption.allCases) { option in
                        Button {
                            onStatusChange(option)
                        } label: {
                            HStack {
                                Text(option.rawValue)
                                if option == statusOption {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label("状态", systemImage: "archivebox")
                }
                .buttonStyle(.appSecondary)

                Spacer()

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .buttonStyle(.appDanger)
            }
            .font(AppPalette.appFont(.body, weight: .semibold))
        }
        .padding(12)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                .stroke(AppPalette.line.opacity(0.55), lineWidth: 1)
        )
    }
}
