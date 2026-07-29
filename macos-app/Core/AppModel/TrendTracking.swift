import Foundation

extension AppModel {
    func loadTrendTrackingState() {
        guard let trendTrackingItemsFileURL else { return }
        do {
            trendTrackingItems = try TrendTrackingStore().load(from: trendTrackingItemsFileURL)
        } catch {
            errorMessage = error.localizedDescription
        }
        recoverSnoozedTrackingItems(now: Self.timestampString())
    }

    func saveTrendTrackingItems() {
        guard let trendTrackingItemsFileURL else { return }
        do {
            try TrendTrackingStore().save(trendTrackingItems, to: trendTrackingItemsFileURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 从今日研判的行动候选加入跟踪；同一标的+动作已有活跃项则忽略
    @discardableResult
    func addTrackingItem(from action: TrendActionCandidate, report: TrendAnalysisReport) -> Bool {
        let now = Self.timestampString()
        let row = Self.matchedRow(for: action, in: personalAssetRows)
        let candidate = TrendTrackingItem(
            sourceReportID: report.id,
            sourceGeneratedAt: report.generatedAt,
            assetKey: row?.key,
            assetName: row?.fundName ?? action.targetName ?? action.title,
            assetCode: row?.fundCode,
            action: action.kind,
            reason: action.detail,
            confidence: action.confidence,
            triggerConditions: action.triggerConditions,
            invalidatingConditions: action.invalidatingConditions,
            createdAt: now,
            status: .observing,
            statusHistory: [TrendTrackingStatusChange(at: now, from: nil, to: .observing, note: "加入跟踪")]
        )
        if trendTrackingItems.contains(where: { $0.isActive && $0.dedupeKey == candidate.dedupeKey }) {
            noticeMessage = "该标的和动作已在跟踪中。"
            return false
        }
        trendTrackingItems.insert(candidate, at: 0)
        saveTrendTrackingItems()
        noticeMessage = "已加入跟踪清单。"
        return true
    }

    func markTrackingItem(_ id: UUID, status: TrendTrackingStatus, note: String) {
        guard let index = trendTrackingItems.firstIndex(where: { $0.id == id }) else { return }
        let old = trendTrackingItems[index]
        guard old.status != status else { return }
        let now = Self.timestampString()
        trendTrackingItems[index].status = status
        if status != .processed {
            trendTrackingItems[index].snoozeUntil = nil
        }
        trendTrackingItems[index].statusHistory.append(
            TrendTrackingStatusChange(at: now, from: old.status, to: status, note: note)
        )
        saveTrendTrackingItems()
    }

    func snoozeTrackingItem(_ id: UUID, days: Int) {
        guard let index = trendTrackingItems.firstIndex(where: { $0.id == id }) else { return }
        let old = trendTrackingItems[index]
        let now = Self.timestampString()
        trendTrackingItems[index].status = .processed
        trendTrackingItems[index].snoozeUntil = Self.timestampString(addingDays: days)
        trendTrackingItems[index].statusHistory.append(
            TrendTrackingStatusChange(at: now, from: old.status, to: .processed, note: "暂缓\(days)天")
        )
        saveTrendTrackingItems()
    }

    func resumeTrackingItem(_ id: UUID) {
        markTrackingItem(id, status: .observing, note: "恢复跟踪")
    }

    func endTrackingItem(_ id: UUID) {
        markTrackingItem(id, status: .ended, note: "结束跟踪")
    }

    /// 取消跟踪：从清单物理移除（区别于「结束跟踪」保留历史）
    func removeTrackingItem(_ id: UUID) {
        trendTrackingItems.removeAll { $0.id == id }
        if selectedTrendTrackingItemID == id {
            selectedTrendTrackingItemID = nil
        }
        saveTrendTrackingItems()
        noticeMessage = "已取消跟踪。"
    }

    /// 启动/刷新时把暂缓到期（snoozeUntil <= now）的项恢复为观察中
    func recoverSnoozedTrackingItems(now: String) {
        var changed = false
        for index in trendTrackingItems.indices {
            let item = trendTrackingItems[index]
            guard item.status == .processed, let due = item.snoozeUntil, !due.isEmpty, due <= now else { continue }
            trendTrackingItems[index].status = .observing
            trendTrackingItems[index].snoozeUntil = nil
            trendTrackingItems[index].statusHistory.append(
                TrendTrackingStatusChange(at: now, from: .processed, to: .observing, note: "暂缓到期，恢复跟踪")
            )
            changed = true
        }
        if changed {
            saveTrendTrackingItems()
        }
    }

    /// 行动候选是否已有活跃跟踪项（供今日研判按钮态）
    func hasActiveTrackingItem(for action: TrendActionCandidate) -> Bool {
        guard let targetName = action.targetName?.trimmingCharacters(in: .whitespacesAndNewlines), !targetName.isEmpty else {
            return false
        }
        let key = targetName.lowercased()
        return trendTrackingItems.contains { item in
            guard item.isActive else { return false }
            return item.assetName.lowercased() == key
                || (item.assetCode?.lowercased() == key)
                || (item.assetKey?.lowercased() == key)
        }
    }

    /// 按 targetID（跟踪项 UUID）定位并选中跟踪项
    @discardableResult
    func selectTrackingItem(forTargetID targetID: String) -> Bool {
        guard let uuid = UUID(uuidString: targetID),
              trendTrackingItems.contains(where: { $0.id == uuid }) else {
            return false
        }
        selectedTrendTrackingItemID = uuid
        return true
    }

    // MARK: - 标的匹配

    private static func matchedRow(
        for action: TrendActionCandidate,
        in rows: [PersonalAssetAggregateRow]
    ) -> PersonalAssetAggregateRow? {
        guard let targetName = action.targetName?.trimmingCharacters(in: .whitespacesAndNewlines), !targetName.isEmpty else {
            return nil
        }
        var lookup: [String: PersonalAssetAggregateRow] = [:]
        for row in rows {
            lookup[row.fundName.lowercased()] = row
            lookup[row.key.lowercased()] = row
            if let code = row.fundCode {
                lookup[code.lowercased()] = row
            }
        }
        let key = targetName.lowercased()
        if let exact = lookup[key] {
            return exact
        }
        return lookup.first { element in key.contains(element.key) || element.key.contains(key) }?.value
    }

    static func timestampString(addingDays days: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
