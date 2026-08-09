import Foundation

// MARK: - Investment Plan CRUD

extension AppModel {

    func updateInvestmentPlansStatus(_ row: PersonalAssetAggregateRow, status: String, activeOnly: Bool = false, archivedOnly: Bool = false) {
        let targetIDs = Set(row.plans.filter { plan in
            if activeOnly {
                return plan.isActivePlan
            }
            if archivedOnly {
                return plan.isPausedPlan || plan.isEndedPlan
            }
            return true
        }.map(\.id))
        guard !targetIDs.isEmpty else {
            noticeMessage = "没有找到需要调整状态的计划。"
            return
        }
        guard let investmentPlanFileURL else {
            errorMessage = "应用数据目录还没准备好，暂时无法调整计划状态。"
            return
        }

        do {
            let nextPlans = investmentPlans.map { plan -> PersonalInvestmentPlan in
                guard targetIDs.contains(plan.id) else { return plan }
                return replacingInvestmentPlan(plan, status: status)
            }
            investmentPlans = nextPlans.sorted(by: sortInvestmentPlans)
            clearInvestmentPlanCaches()
            rebuildAssetRows()
            try investmentPlansStore.save(investmentPlans, to: investmentPlanFileURL)
            let itemText = row.fundCode.map { "\(row.fundName)（\($0)）" } ?? row.fundName
            noticeMessage = "已将 \(itemText) 的 \(targetIDs.count) 条计划调整为\(status)。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateInvestmentPlanStatus(_ planID: UUID, status: String) {
        guard let investmentPlanFileURL else {
            errorMessage = "应用数据目录还没准备好，暂时无法调整计划状态。"
            return
        }
        guard let existingPlan = investmentPlans.first(where: { $0.id == planID }) else {
            errorMessage = "没有找到这条定投计划。"
            return
        }

        do {
            let normalizedStatus = normalizedInvestmentPlanStatus(status)
            let nextPlans = investmentPlans.map { plan -> PersonalInvestmentPlan in
                guard plan.id == planID else { return plan }
                return replacingInvestmentPlan(plan, status: normalizedStatus)
            }
            investmentPlans = nextPlans.sorted(by: sortInvestmentPlans)
            clearInvestmentPlanCaches()
            rebuildAssetRows()
            try investmentPlansStore.save(investmentPlans, to: investmentPlanFileURL)
            let itemText = existingPlan.fundCode.map { "\(existingPlan.fundName)（\($0)）" } ?? existingPlan.fundName
            noticeMessage = "已将 \(itemText) 的计划调整为\(normalizedStatus)。"
            Task { await applyPersonalAssetAutomation() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func addInvestmentPlan(
        planTypeLabel: String,
        fundName: String,
        fundCode: String,
        scheduleText: String,
        amountText: String,
        investedPeriodsText: String,
        cumulativeInvestedAmountText: String,
        paymentMethod: String,
        nextExecutionDate: String,
        status: String,
        note: String
    ) -> Bool {
        guard let investmentPlanFileURL else {
            errorMessage = "应用数据目录还没准备好，暂时无法添加定投计划。"
            return false
        }
        guard let plan = validatedInvestmentPlan(
            id: UUID(),
            planTypeLabel: planTypeLabel,
            fundName: fundName,
            fundCode: fundCode,
            scheduleText: scheduleText,
            amountText: amountText,
            investedPeriodsText: investedPeriodsText,
            cumulativeInvestedAmountText: cumulativeInvestedAmountText,
            paymentMethod: paymentMethod,
            nextExecutionDate: nextExecutionDate,
            status: status,
            note: note
        ) else {
            return false
        }

        do {
            investmentPlans.append(plan)
            investmentPlans.sort(by: sortInvestmentPlans)
            clearInvestmentPlanCaches()
            rebuildAssetRows()
            try investmentPlansStore.save(investmentPlans, to: investmentPlanFileURL)
            let itemText = plan.fundCode.map { "\(plan.fundName)（\($0)）" } ?? plan.fundName
            noticeMessage = "已添加 \(itemText) 的定投计划。"
            Task { await applyPersonalAssetAutomation() }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func updateInvestmentPlan(
        _ planID: UUID,
        planTypeLabel: String,
        fundName: String,
        fundCode: String,
        scheduleText: String,
        amountText: String,
        investedPeriodsText: String,
        cumulativeInvestedAmountText: String,
        paymentMethod: String,
        nextExecutionDate: String,
        status: String,
        note: String
    ) -> Bool {
        guard let existingIndex = investmentPlans.firstIndex(where: { $0.id == planID }) else {
            errorMessage = "没有找到这条定投计划。"
            return false
        }
        guard let investmentPlanFileURL else {
            errorMessage = "应用数据目录还没准备好，暂时无法保存定投计划。"
            return false
        }
        guard let plan = validatedInvestmentPlan(
            id: planID,
            planTypeLabel: planTypeLabel,
            fundName: fundName,
            fundCode: fundCode,
            scheduleText: scheduleText,
            amountText: amountText,
            investedPeriodsText: investedPeriodsText,
            cumulativeInvestedAmountText: cumulativeInvestedAmountText,
            paymentMethod: paymentMethod,
            nextExecutionDate: nextExecutionDate,
            status: status,
            note: note
        ) else {
            return false
        }

        do {
            var nextPlans = investmentPlans
            nextPlans[existingIndex] = plan
            investmentPlans = nextPlans.sorted(by: sortInvestmentPlans)
            clearInvestmentPlanCaches()
            rebuildAssetRows()
            try investmentPlansStore.save(investmentPlans, to: investmentPlanFileURL)

            let itemText = plan.fundCode.map { "\(plan.fundName)（\($0)）" } ?? plan.fundName
            noticeMessage = "已更新 \(itemText) 的定投计划。"
            Task { await applyPersonalAssetAutomation() }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteInvestmentPlan(_ planID: UUID) {
        guard let investmentPlanFileURL else {
            errorMessage = "应用数据目录还没准备好，暂时无法删除定投计划。"
            return
        }
        guard let existingPlan = investmentPlans.first(where: { $0.id == planID }) else {
            errorMessage = "没有找到这条定投计划。"
            return
        }

        do {
            let nextPlans = investmentPlans.filter { $0.id != planID }
            investmentPlans = nextPlans.sorted(by: sortInvestmentPlans)
            clearInvestmentPlanCaches()
            rebuildAssetRows()
            if investmentPlans.isEmpty {
                try investmentPlansStore.delete(at: investmentPlanFileURL)
            } else {
                try investmentPlansStore.save(investmentPlans, to: investmentPlanFileURL)
            }
            let itemText = existingPlan.fundCode.map { "\(existingPlan.fundName)（\($0)）" } ?? existingPlan.fundName
            noticeMessage = "已删除 \(itemText) 的定投计划。"
            Task { await applyPersonalAssetAutomation() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadInvestmentPlans() {
        guard let investmentPlanFileURL else { return }
        do {
            investmentPlans = try investmentPlansStore.load(from: investmentPlanFileURL)
                .sorted(by: sortInvestmentPlans)
            clearInvestmentPlanCaches()
            rebuildAssetRows()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
