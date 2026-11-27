import Foundation

// MARK: - 基金估值校准（收盘落账 / 次日结算 / 注入融合引擎）

extension AppModel {
    var fundEstimateCalibrationFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("fund-estimate-calibration.json", isDirectory: false)
    }

    /// 启动时加载台账并注入客户端。必须在 dataDirectoryURL 就绪后调用。
    func loadSavedFundEstimateCalibration() {
        do {
            if let url = fundEstimateCalibrationFileURL {
                fundEstimateCalibrationLedger = try fundEstimateCalibrationStore.load(from: url)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        var ledger = fundEstimateCalibrationLedger
        ledger.pruneStalePending(olderThanDays: 14)
        fundEstimateCalibrationLedger = ledger
        // 注入台账快照：`fetchFundQuote` 在 TaskGroup 后台任务里调用 provider，
        // 不能跨到 MainActor 读 AppModel 状态（assumeIsolated 在非主线程会 trap）。
        // 台账是值类型，直接复制一份给后台任务只读；台账变化时由 publish 重注入。
        publishEstimateLedgerToClient()
        platformClient.lookThroughProvider = { [weak self] fundCode in
            await self?.fundLookThroughClient.fetchDisclosures(fundCodes: [fundCode]).disclosures[fundCode]
        }
    }

    /// 把当前台账快照重新注入客户端（台账变更后调用）。
    private func publishEstimateLedgerToClient() {
        let snapshot = fundEstimateCalibrationLedger
        platformClient.estimateLedgerProvider = { snapshot }
    }

    /// 刷新拿到 snapshot 后调用：
    /// 1. 用新到的官方净值结算等待中的记录（算误差）；
    /// 2. 对接近收盘（≥ 14:45 Asia/Shanghai）且为今日的估值，记录为 pending（同日取更晚的）。
    func updateFundEstimateCalibration(with snapshot: UserPortfolioSnapshot) {
        var ledger = fundEstimateCalibrationLedger
        let now = Date()
        let settledAt = ISO8601DateFormatter().string(from: now)
        var changed = false

        // 1. 结算：官方净值已公布时，行上的 `estimateChangePct` 即为该净值日的真实涨幅
        //    （`latestHistoryQuote` / `fetchLatestFundNavQuote` 把当日官方涨幅填进该字段，
        //    且 `estimatePrice == nil`）。用它结算等待中的记录。
        for row in snapshot.rows where row.holding.assetType == .fund {
            let code = row.holding.normalizedFundCode
            guard let officialDate = row.officialNavDate.map({ String($0.prefix(10)) }),
                  let actual = row.estimateChangePct,
                  actual.isFinite,
                  row.estimatePrice == nil,
                  row.priceSource == "official_nav" else {
                continue
            }
            if ledger.settle(
                fundCode: code,
                actualChangePctByDate: [officialDate: actual],
                settledAt: settledAt
            ) > 0 {
                changed = true
            }
        }

        // 2. 落账：今日估值且接近收盘。
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        formatter.dateFormat = "HHmm"
        let hhmm = Int(formatter.string(from: now)) ?? 0
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: now)
        let nearClose = hhmm >= 1445 && hhmm <= 1500
        guard nearClose else {
            if changed { persistFundEstimateCalibration(ledger) }
            return
        }

        for row in snapshot.rows where row.holding.assetType == .fund {
            guard let changePct = row.estimateChangePct,
                  let estimateTime = row.estimatePriceTime,
                  changePct.isFinite,
                  estimateTime.hasPrefix(today) else { continue }
            let source = row.estimateSource ?? FundEstimateSource.eastmoneyLegacyEstimate.rawValue
            let record = FundEstimateCalibrationRecord(
                fundCode: row.holding.normalizedFundCode,
                tradeDate: today,
                estimatedChangePct: changePct,
                source: source,
                estimatedAt: estimateTime
            )
            if ledger.recordEstimate(record) {
                changed = true
            }
        }
        if changed { persistFundEstimateCalibration(ledger) }
    }

    private func persistFundEstimateCalibration(_ ledger: FundEstimateCalibrationLedger) {
        fundEstimateCalibrationLedger = ledger
        publishEstimateLedgerToClient()
        guard let url = fundEstimateCalibrationFileURL else { return }
        try? fundEstimateCalibrationStore.save(ledger, to: url)
    }
}
