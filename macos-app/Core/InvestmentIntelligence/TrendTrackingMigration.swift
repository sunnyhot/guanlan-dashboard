import Foundation

// TrendTrackingItem → DecisionCase 迁移(Slice 6)。
//
// 复核方案第 15.2 节 + docs/ai-pipeline-baseline.md 第 9.4 节:
// - 旧 triggerConditions/invalidatingConditions 是自然语言 → 不得迁移为自动触发规则
// - 迁移标记为 manualReviewRequired(写入 detail + 事件 reason)
// - 原文件保留,迁移写入单独标记防止重复迁移
//
// Sunset 三阶段:
// - N 版:新旧同时读取,新写只写 DecisionCase(本 Slice 只做迁移,不改写入路径——那是 Slice 6 的后续)
// - N+1 版:UI 不再展示旧 Tracking
// - N+2 版:移除旧运行逻辑,但保留解码和导入能力

enum TrendTrackingMigration {

    /// 将旧 TrendTrackingItem 迁移为 DecisionCase。
    /// 纯函数,不读不写文件。调用方负责去重和持久化。
    static func migrate(_ item: TrendTrackingItem) -> DecisionCase {
        let caseKey = makeCaseKey(from: item)
        let decisionState = mapStatus(item.status)
        let lifecycle = mapLifecycle(item.status)

        var detailParts: [String] = []
        detailParts.append("来源:趋势报告(\(item.sourceGeneratedAt))")
        detailParts.append("操作建议:\(item.action.rawValue)")
        detailParts.append("理由:\(item.reason)")
        if !item.triggerConditions.isEmpty {
            detailParts.append("触发条件(人工复核):\(item.triggerConditions.joined(separator: "、"))")
        }
        if !item.invalidatingConditions.isEmpty {
            detailParts.append("失效条件(人工复核):\(item.invalidatingConditions.joined(separator: "、"))")
        }
        detailParts.append("[迁移自旧跟踪清单,条件为自然语言,不自动触发]")

        var cs = DecisionCase(
            id: item.id,  // 保持 ID 稳定,防止重复迁移
            caseKey: caseKey,
            kind: .concentrationRisk,  // 旧 Tracking 没有细分,统一归为集中度风险
            dimension: .directHolding,  // 默认维度
            subjectName: item.assetName,
            subjectCode: item.assetCode,
            lifecycle: lifecycle,
            decisionState: decisionState,
            metricValue: Double(item.confidence.score),
            metricLabel: "置信度 \(item.confidence.score)",
            metricDescription: "迁移自信任度 \(item.confidence.label)",
            title: "\(item.assetName) · \(item.action.rawValue)",
            detail: detailParts.joined(separator: "\n"),
            createdAt: item.createdAt,
            updatedAt: item.createdAt,
            events: [],
            userDisposition: mapDisposition(item.status)
        )

        // 把旧 statusHistory 转为 DecisionCaseEvent
        let migratedEvents = item.statusHistory.map { change -> DecisionCaseEvent in
            DecisionCaseEvent(
                at: change.at,
                type: .migrated,
                previousLifecycle: nil,
                newLifecycle: lifecycle,
                previousDecisionState: change.from.map { mapStatus($0) },
                newDecisionState: mapStatus(change.to),
                reason: "迁移自旧跟踪状态:\(change.from?.rawValue ?? "无") → \(change.to.rawValue)" + (change.note.isEmpty ? "" : "(\(change.note))"),
                actor: .migration
            )
        }
        cs.events = migratedEvents

        return cs
    }

    /// 批量迁移 + 去重(按 caseKey,保留已有用户处置)。
    /// - Parameters:
    ///   - existingCases: 已有的 DecisionCase(不覆盖用户已操作的)
    ///   - trackingItems: 旧跟踪项
    /// - Returns: 合并后的 DecisionCase 列表
    static func mergeMigrated(
        existingCases: [DecisionCase],
        trackingItems: [TrendTrackingItem]
    ) -> [DecisionCase] {
        var result = existingCases
        var consumedKeys = Set(existingCases.map(\.caseKey))

        for item in trackingItems {
            // 跳过已结束的旧项(ended → 不迁移)
            if item.status == .ended { continue }

            let migrated = migrate(item)
            if consumedKeys.contains(migrated.caseKey) { continue }
            consumedKeys.insert(migrated.caseKey)
            result.append(migrated)
        }

        return result
    }

    // MARK: - 映射

    /// 生成迁移后的 caseKey(加 legacy 前缀,与新生成的 Case 区分)。
    private static func makeCaseKey(from item: TrendTrackingItem) -> String {
        let subjectID = item.assetCode?.lowercased() ?? item.assetName.lowercased()
        return "legacy:\(item.action.rawValue)|\(subjectID)"
    }

    /// TrendTrackingStatus → PortfolioDecisionState。
    private static func mapStatus(_ status: TrendTrackingStatus) -> PortfolioDecisionState {
        switch status {
        case .observing: return .watch
        case .approaching: return .prepare
        case .triggered: return .adjustReview
        case .invalidated: return .exitReview
        case .staleData: return .insufficientEvidence
        case .processed: return .watch
        case .ended: return .stable
        }
    }

    /// TrendTrackingStatus → DecisionCaseLifecycle。
    private static func mapLifecycle(_ status: TrendTrackingStatus) -> DecisionCaseLifecycle {
        switch status {
        case .observing, .approaching, .triggered, .invalidated, .staleData, .processed:
            return .monitoring
        case .ended:
            return .closed
        }
    }

    /// TrendTrackingStatus → DecisionCaseUserDisposition。
    private static func mapDisposition(_ status: TrendTrackingStatus) -> DecisionCaseUserDisposition {
        switch status {
        case .observing, .approaching, .triggered, .invalidated, .staleData:
            return .acknowledged  // 旧项已在跟踪 → 视为已确认关注
        case .processed:
            return .resolved
        case .ended:
            return .closed
        }
    }
}
