import Foundation

// MARK: - alfa 投顾组合管理

extension AppModel {

    var alfaPortfoliosFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("alfa-portfolios.json", isDirectory: false)
    }

    /// 当前单选的投顾组合。
    var selectedAlfaPortfolio: AlfaPortfolioCatalogItem? {
        guard let selectedAlfaPoCode else { return nil }
        return alfaPortfolios.first { $0.poCode == selectedAlfaPoCode }
    }

    /// 当前组合的调仓列表。alfaPayload 不再保存多组合聚合数据。
    var filteredAlfaActions: [PlatformActionPayload] {
        guard let selectedAlfaPoCode,
              alfaPayload?.prodCode == selectedAlfaPoCode else { return [] }
        return alfaPayload?.actions ?? []
    }

    /// 当前组合的持仓列表。只有选中单个组合时才返回数据。
    var filteredAlfaHoldings: [AlfaHoldingPart] {
        guard let selectedAlfaPoCode else { return [] }
        return alfaHoldings.filter { $0.sourcePoCode == selectedAlfaPoCode }
    }

    /// 从磁盘加载已添加的投顾组合列表（首次落盘预置一个有调仓记录的组合）。
    func loadAlfaPortfolios() {
        guard let url = alfaPortfoliosFileURL else { return }
        let loaded = alfaPortfolioStore.load(from: url)
        alfaPortfolios = loaded
        selectedAlfaPoCode = loaded.first?.poCode
        reconcileManagerWatchAdjustmentSources()
        // 首次运行：落盘默认组合
        if !FileManager.default.fileExists(atPath: url.path) {
            try? alfaPortfolioStore.save(loaded, to: url)
        }
    }

    /// 批量验证所有已添加组合，只保留近一年有调仓记录的活跃组合。
    /// 展示数据始终只取当前选中的一个组合，不再合并多组合。
    func fetchAllAlfaPayloads() async {
        let portfolios = alfaPortfolios
        guard !portfolios.isEmpty else {
            selectedAlfaPoCode = nil
            alfaPayload = nil
            alfaHoldings = []
            return
        }
        guard !isLoadingAlfa else { return }
        isLoadingAlfa = true
        defer { isLoadingAlfa = false }
        alfaError = nil

        let (payloadsByCode, errorsByCode) = await fetchAlfaAdjustmentsConcurrent(
            codes: portfolios.map(\.poCode)
        )
        let removedCodes = Self.inactiveAlfaPortfolioCodes(
            portfolios: portfolios,
            successfulPayloads: payloadsByCode,
            referenceDate: Date()
        )

        if !removedCodes.isEmpty {
            let removedNames = portfolios
                .filter { removedCodes.contains($0.poCode) }
                .map(\.name)
            alfaPortfolios.removeAll { removedCodes.contains($0.poCode) }
            persistAlfaPortfolios()
            noticeMessage = "已移除 \(removedNames.count) 个不活跃组合：\(removedNames.joined(separator: "、"))"
        }

        selectedAlfaPoCode = Self.preferredAlfaPoCode(
            current: selectedAlfaPoCode,
            portfolios: alfaPortfolios
        )

        guard let selectedAlfaPoCode else {
            alfaPayload = nil
            alfaHoldings = []
            return
        }

        guard let selectedPayload = payloadsByCode[selectedAlfaPoCode] else {
            alfaPayload = nil
            alfaHoldings = []
            alfaError = errorsByCode[selectedAlfaPoCode] ?? "当前组合数据拉取失败，请稍后重试。"
            return
        }

        alfaPayload = selectedPayload
        do {
            alfaHoldings = try await alfaClient.fetchAlfaComposition(poCode: selectedAlfaPoCode)
        } catch {
            alfaHoldings = []
            alfaError = "当前持仓拉取失败：\(error.localizedDescription)"
        }
    }

    /// 并发抓取多组合调仓，按组合码保留成功结果和失败原因。
    private func fetchAlfaAdjustmentsConcurrent(
        codes: [String]
    ) async -> ([String: PlatformPayload], [String: String]) {
        var payloadsByCode: [String: PlatformPayload] = [:]
        var errorsByCode: [String: String] = [:]
        await withTaskGroup(of: (String, PlatformPayload?, String?).self) { group in
            for code in codes {
                group.addTask { [weak self] in
                    guard let self else { return (code, nil, nil) }
                    do {
                        return (code, try await self.alfaClient.fetchAlfaPayload(poCode: code), nil)
                    } catch {
                        return (code, nil, error.localizedDescription)
                    }
                }
            }
            for await (code, payload, error) in group {
                if let payload {
                    payloadsByCode[code] = payload
                } else if let error {
                    errorsByCode[code] = error
                }
            }
        }
        return (payloadsByCode, errorsByCode)
    }

    /// 纯函数：删除“请求成功但近一年无调仓”的组合；请求失败或日期异常的组合保留，避免误删。
    static func inactiveAlfaPortfolioCodes(
        portfolios: [AlfaPortfolioCatalogItem],
        successfulPayloads: [String: PlatformPayload],
        referenceDate: Date
    ) -> Set<String> {
        Set(portfolios.compactMap { portfolio in
            guard let payload = successfulPayloads[portfolio.poCode] else { return nil }
            return isAlfaPayloadActive(payload, referenceDate: referenceDate) ? nil : portfolio.poCode
        })
    }

    /// 最近一年内（含临界日）至少有一笔调仓即视为活跃。
    /// 有动作但日期不可解析时保守保留，避免接口字段异常导致误删。
    static func isAlfaPayloadActive(
        _ payload: PlatformPayload,
        referenceDate: Date
    ) -> Bool {
        let actions = payload.actions ?? []
        guard !actions.isEmpty else { return false }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"

        let datedActions = actions.compactMap { action in
            action.txnDate.flatMap(formatter.date(from:))
        }
        guard !datedActions.isEmpty else { return true }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let referenceDay = calendar.startOfDay(for: referenceDate)
        guard let cutoff = calendar.date(byAdding: .year, value: -1, to: referenceDay) else {
            return true
        }
        return datedActions.contains { $0 >= cutoff }
    }

    /// 纯函数：维持现有单选；选中项被清理后回落到第一个有效组合。
    static func preferredAlfaPoCode(
        current: String?,
        portfolios: [AlfaPortfolioCatalogItem]
    ) -> String? {
        if let current, portfolios.contains(where: { $0.poCode == current }) {
            return current
        }
        return portfolios.first?.poCode
    }

    /// 刷新全部组合并清理确认近一年无调仓记录的组合。
    func refreshAlfaPayload() async {
        await fetchAllAlfaPayloads()
    }

    /// 切换到一个组合，仅拉取这个组合的调仓与持仓。
    func selectAlfaPortfolio(_ poCode: String) async {
        guard alfaPortfolios.contains(where: { $0.poCode == poCode }) else { return }
        selectedAlfaPoCode = poCode
        await fetchSelectedAlfaPortfolio()
    }

    private func fetchSelectedAlfaPortfolio() async {
        guard let poCode = selectedAlfaPoCode, !isLoadingAlfa else { return }
        isLoadingAlfa = true
        alfaError = nil
        alfaPayload = nil
        alfaHoldings = []

        do {
            let payload = try await alfaClient.fetchAlfaPayload(poCode: poCode)
            guard Self.isAlfaPayloadActive(payload, referenceDate: Date()) else {
                let removedName = alfaPortfolioName(for: poCode) ?? poCode
                removeAlfaPortfolio(poCode)
                noticeMessage = "已移除不活跃组合：\(removedName)"
                isLoadingAlfa = false
                if selectedAlfaPoCode != nil {
                    await fetchSelectedAlfaPortfolio()
                }
                return
            }

            guard selectedAlfaPoCode == poCode else {
                isLoadingAlfa = false
                return
            }
            alfaPayload = payload
            do {
                alfaHoldings = try await alfaClient.fetchAlfaComposition(poCode: poCode)
            } catch {
                alfaHoldings = []
                alfaError = "当前持仓拉取失败：\(error.localizedDescription)"
            }
        } catch {
            alfaError = error.localizedDescription
        }
        isLoadingAlfa = false
    }

    /// 拉取可选组合目录（hand-picked），供"添加组合"使用。
    func loadAlfaCatalog() async {
        guard !isLoadingAlfaCatalog else { return }
        isLoadingAlfaCatalog = true
        do {
            alfaCatalog = try await alfaClient.fetchPortfolioCatalog()
        } catch {
            alfaCatalog = []
        }
        isLoadingAlfaCatalog = false
    }

    /// 验证并添加组合。近一年无公开调仓记录时不加入本地列表。
    func addAlfaPortfolio(_ item: AlfaPortfolioCatalogItem) async -> Bool {
        guard !alfaPortfolios.contains(where: { $0.poCode == item.poCode }),
              !isLoadingAlfa else { return false }
        isLoadingAlfa = true
        alfaError = nil
        do {
            let payload = try await alfaClient.fetchAlfaPayload(poCode: item.poCode)
            guard Self.isAlfaPayloadActive(payload, referenceDate: Date()) else {
                noticeMessage = "\(item.name) 近一年无公开调仓记录，未添加。"
                isLoadingAlfa = false
                return false
            }
            let holdings = (try? await alfaClient.fetchAlfaComposition(poCode: item.poCode)) ?? []

            alfaPortfolios.append(item)
            selectedAlfaPoCode = item.poCode
            alfaPayload = payload
            alfaHoldings = holdings
            persistAlfaPortfolios()
            isLoadingAlfa = false
            return true
        } catch {
            alfaError = error.localizedDescription
            isLoadingAlfa = false
            return false
        }
    }

    /// 通过组合码添加（校验存在性并拉取名称），用于 catalog 之外的手动添加。
    func addAlfaPortfolioByCode(_ poCode: String) async -> Bool {
        let trimmed = poCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !alfaPortfolios.contains(where: { $0.poCode == trimmed }) else {
            return false
        }
        do {
            let name = try await alfaClient.fetchPortfolioName(poCode: trimmed) ?? trimmed
            return await addAlfaPortfolio(
                AlfaPortfolioCatalogItem(poCode: trimmed, name: name, author: "", category: "")
            )
        } catch {
            return false
        }
    }

    /// 移除投顾组合。
    func removeAlfaPortfolio(_ poCode: String) {
        alfaPortfolios.removeAll { $0.poCode == poCode }
        if selectedAlfaPoCode == poCode {
            selectedAlfaPoCode = alfaPortfolios.first?.poCode
            alfaPayload = nil
            alfaHoldings = []
        }
        reconcileManagerWatchAdjustmentSources()
        persistAlfaPortfolios()
    }

    /// 组合名映射，便于列表行展示来源。
    func alfaPortfolioName(for poCode: String?) -> String? {
        guard let poCode else { return nil }
        return alfaPortfolios.first { $0.poCode == poCode }?.name
    }

    private func persistAlfaPortfolios() {
        guard let url = alfaPortfoliosFileURL else { return }
        try? alfaPortfolioStore.save(alfaPortfolios, to: url)
    }
}
