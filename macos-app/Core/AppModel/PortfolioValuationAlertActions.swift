import Foundation

// MARK: - Portfolio Valuation Alert

extension AppModel {

    /// 启动时从磁盘加载
    func loadSavedPortfolioValuationAlerts() {
        do {
            if let portfolioValuationAlertFileURL {
                portfolioValuationAlertProfiles = try portfolioValuationAlertStore.load(
                    from: portfolioValuationAlertFileURL)
            }
            if let portfolioValuationAlertSettingsFileURL {
                portfolioValuationAlertSettings = try portfolioValuationAlertSettingsStore.load(
                    from: portfolioValuationAlertSettingsFileURL)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 持久化 profiles
    private func persistPortfolioValuationAlerts() {
        guard let portfolioValuationAlertFileURL else { return }
        try? portfolioValuationAlertStore.save(
            portfolioValuationAlertProfiles, to: portfolioValuationAlertFileURL)
    }

    /// 持久化设置
    private func persistPortfolioValuationAlertSettings() {
        guard let portfolioValuationAlertSettingsFileURL else { return }
        try? portfolioValuationAlertSettingsStore.save(
            portfolioValuationAlertSettings, to: portfolioValuationAlertSettingsFileURL)
    }

    /// 获取某标的的 profile（不存在则建空）
    func portfolioValuationAlertProfile(for fundCode: String) -> PortfolioValuationAlertProfile {
        portfolioValuationAlertProfiles[fundCode]
            ?? PortfolioValuationAlertProfile(fundCode: fundCode)
    }

    /// 保存/更新某标的的 profile
    func upsertPortfolioValuationAlertProfile(_ profile: PortfolioValuationAlertProfile) {
        var next = profile
        // 清理：移除已不存在于 rules 的 breached/lastTriggered 残留
        let validIDs = Set(next.rules.map(\.id))
        next.breachedRuleIDs.formIntersection(validIDs)
        next.lastTriggeredAt = next.lastTriggeredAt.filter { validIDs.contains($0.key) }
        portfolioValuationAlertProfiles[next.fundCode] = next
        persistPortfolioValuationAlerts()
    }

    /// 删除某标的的 profile（持仓删除时联动）
    func removePortfolioValuationAlertProfile(fundCode: String) {
        guard portfolioValuationAlertProfiles.removeValue(forKey: fundCode) != nil else { return }
        persistPortfolioValuationAlerts()
    }

    /// 设置全局开关
    func setPortfolioValuationAlertEnabled(_ enabled: Bool) {
        portfolioValuationAlertSettings.isEnabled = enabled
        persistPortfolioValuationAlertSettings()
    }

    /// 评估所有持仓的预警并发通知（挂在 60s 刷新循环末尾）
    func evaluatePortfolioValuationAlerts() async {
        guard portfolioValuationAlertSettings.isEnabled else { return }
        guard let snapshot = userPortfolioSnapshot else { return }

        // Phase 1: 在内存中评估全部规则，构建待持久化的工作副本，暂不落盘。
        // pendingFires 仅记录 .fire 分支（受通知授权门控）；
        // .clear 始终生效（与授权无关，属于状态清理）；.hold/.idle 永不改动。
        var nextProfiles: [String: PortfolioValuationAlertProfile] = [:]
        var pendingFires: [(rule: PortfolioValuationAlertRule, fundName: String, fundCode: String, value: Double?)] = []
        var firedRuleIDsByFundCode: [String: Set<UUID>] = [:]

        for row in snapshot.rows {
            let fundCode = row.holding.fundCode
            guard let original = portfolioValuationAlertProfiles[fundCode],
                  original.hasActiveRules else { continue }

            let context = PortfolioValuationAlertContext(
                holdingProfitPct: row.profitPct,
                estimateChangePct: row.estimateChangePct,
                estimatePrice: row.estimatePrice
            )

            var profile = original
            var firedIDs: Set<UUID> = []
            for rule in profile.rules where rule.isEnabled {
                let isBreached = profile.breachedRuleIDs.contains(rule.id)
                let evaluation = PortfolioValuationAlertEvaluator.evaluate(
                    rule: rule, context: context, isCurrentlyBreached: isBreached)
                switch evaluation {
                case .fire:
                    // 先写入工作副本；若最终授权被拒，会回滚这一插入。
                    profile.breachedRuleIDs.insert(rule.id)
                    profile.lastTriggeredAt[rule.id] = Self.currentTimestamp()
                    firedIDs.insert(rule.id)
                    pendingFires.append((rule, row.fundName, fundCode, observedValue(rule: rule, context: context)))
                case .clear:
                    profile.breachedRuleIDs.remove(rule.id)
                case .hold, .idle:
                    break
                }
            }

            if profile != original {
                nextProfiles[fundCode] = profile
                firedRuleIDsByFundCode[fundCode] = firedIDs
            }
        }

        // Phase 2: 仅当存在待发送的 .fire 时才请求授权；否则只需落盘清理。
        let authorized: Bool
        if pendingFires.isEmpty {
            authorized = true
        } else {
            authorized = await notificationManager.requestAuthorizationIfNeeded()
        }

        if !authorized {
            // 授权被拒：回滚所有 .fire 的影响（让规则保持未触发，待授权后再触发），
            // 但保留 .clear 的清理效果。
            for (fundCode, firedIDs) in firedRuleIDsByFundCode {
                guard var profile = nextProfiles[fundCode] else { continue }
                profile.breachedRuleIDs.subtract(firedIDs)
                for id in firedIDs { profile.lastTriggeredAt.removeValue(forKey: id) }
                if profile != portfolioValuationAlertProfiles[fundCode] {
                    nextProfiles[fundCode] = profile
                } else {
                    nextProfiles.removeValue(forKey: fundCode)
                }
            }
            pendingFires = []
        }

        guard !nextProfiles.isEmpty else { return }
        for (fundCode, profile) in nextProfiles {
            portfolioValuationAlertProfiles[fundCode] = profile
        }
        persistPortfolioValuationAlerts()

        guard !pendingFires.isEmpty else { return }
        for payload in pendingFires {
            let title = payload.rule.side == .sell
                ? "估值预警 · 提醒卖出"
                : "估值预警 · 提醒加仓"
            let body = PortfolioValuationAlertEvaluator.describe(
                rule: payload.rule, fundName: payload.fundName,
                fundCode: payload.fundCode, observedValue: payload.value)
            try? await notificationManager.send(
                title: title, body: body,
                deepLink: NotificationDeepLinkPayload(
                    type: .portfolioValuationAlert,
                    targetID: "\(payload.fundCode):\(payload.rule.id.uuidString)"
                )
            )
        }
    }

    private func observedValue(
        rule: PortfolioValuationAlertRule,
        context: PortfolioValuationAlertContext
    ) -> Double? {
        switch rule.metric {
        case .holdingProfitPct: return context.holdingProfitPct
        case .estimateChangePct: return context.estimateChangePct
        case .estimatePrice: return context.estimatePrice
        }
    }

    private static func currentTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date())
    }
}
