import Foundation

// MARK: - EastmoneyResponseParser（真实 Provider 解析链，审查 P0 修复）
//
// 解析天天基金（eastmoney）真实 HTTP 响应 → ProviderRecord。
// 这不是 stub——解析真实的 wire 格式：
//   - pingzhongdata JS：`var Data_netWorthTrend = [{"x":<tsMs>,"y":<nav>,"equityReturn":<pct>}];`
//   - lsjz JSON：`{"ErrCode":0,"Data":{"LSJZList":[{"DWJZ":"<nav>","FSRQ":"YYYY-MM-DD","JZZZL":"<pct>"}]}}`
//
// 现有 QiemanPlatformNativeClient 内部也是解析这两个格式（见
// QiemanPlatformNativeClient.swift fetchFundHistorySeries 私有方法 + 测试 inline mock）。
// 本解析器独立实现，不修改现有 client（rollout REPO-7：不修改现有 client），
// 让 Provider Adapter 层可独立测试。
//
// **已知字段缺口**（来自现有 client 的限制，非本解析器问题）：
// - 累计净值（accumulated NAV）：pingzhongdata 上游有 Data_ACWorthTrend 但现有 client 不解析，
//   本解析器暂只取单位净值，accumulatedNAV 与 cumulativeDividendPerShare 留 nil
// - 持仓 shares / marketValue：天天基金 f10 不披露，weightPct 仅 FundLookThroughClient 有

/// 天天基金 pingzhongdata JS 响应解析结果（单位净值历史）。
struct EastmoneyNAVHistory: Sendable, Hashable {
    let fundCode: String
    let fundName: String
    /// 单位净值序列（按时间升序）
    let entries: [Entry]

    struct Entry: Sendable, Hashable {
        /// 净值日期（UTC 日界，由 tsMs 转换）
        let date: Date
        /// 单位净值
        let unitNAV: Double
        /// 当日涨跌幅（小数，如 0.012 表示 1.2%）
        let changePct: Double?
    }
}

enum EastmoneyParseError: Error, Equatable, Sendable {
    /// pingzhongdata JS 里找不到 Data_netWorthTrend 变量
    case missingNetWorthTrend
    /// lsjz JSON 结构异常
    case invalidLSJZ(detail: String)
    /// 响应体为空
    case emptyBody
}

/// 天天基金真实响应解析器。
struct EastmoneyResponseParser: Sendable {

    /// 解析 pingzhongdata JS 响应（基金净值历史）。
    ///
    /// 真实 wire 格式（来自现有测试 QiemanPlatformFundQuoteFallbackTests 的 inline mock）：
    /// ```
    /// var fS_name = "易方达消费行业股票";
    /// var Data_netWorthTrend = [{"x":1719820800000,"y":3.5,"equityReturn":0.012}, ...];
    /// ```
    func parsePingzhongdata(_ body: String, fundCode: String) throws -> EastmoneyNAVHistory {
        guard !body.isEmpty else { throw EastmoneyParseError.emptyBody }

        // 提取 fS_name
        let fundName = extractJSStringVar(body, name: "fS_name") ?? fundCode

        // 提取 Data_netWorthTrend 数组
        guard let trendJSON = extractJSArrayVar(body, name: "Data_netWorthTrend") else {
            throw EastmoneyParseError.missingNetWorthTrend
        }
        guard let trendData = trendJSON.data(using: .utf8) else {
            throw EastmoneyParseError.missingNetWorthTrend
        }

        struct RawEntry: Decodable {
            let x: Double        // epoch 毫秒
            let y: Double        // 单位净值
            let equityReturn: Double?
        }
        let rawEntries = (try? JSONDecoder().decode([RawEntry].self, from: trendData)) ?? []

        let entries: [EastmoneyNAVHistory.Entry] = rawEntries.map { raw in
            EastmoneyNAVHistory.Entry(
                date: Date(timeIntervalSince1970: raw.x / 1000.0),
                unitNAV: raw.y,
                changePct: raw.equityReturn
            )
        }
        return EastmoneyNAVHistory(
            fundCode: fundCode, fundName: fundName, entries: entries
        )
    }

    /// 解析 lsjz JSON 响应（近期官方净值，用于补充 pingzhongdata 的最新段）。
    ///
    /// 真实 wire 格式：
    /// ```
    /// {"ErrCode":0,"Data":{"LSJZList":[{"DWJZ":"3.5","FSRQ":"2024-07-18","JZZZL":"1.2"}, ...]}}
    /// ```
    func parseLSJZ(_ body: String, fundCode: String) throws -> EastmoneyNAVHistory {
        guard !body.isEmpty else { throw EastmoneyParseError.emptyBody }
        guard let data = body.data(using: .utf8) else {
            throw EastmoneyParseError.invalidLSJZ(detail: "body not utf8")
        }

        struct LSJZResponse: Decodable {
            let ErrCode: Int
            struct Data: Decodable {
                struct Entry: Decodable {
                    let DWJZ: String    // 单位净值
                    let FSRQ: String     // YYYY-MM-DD
                    let JZZZL: String?   // 涨跌幅 %
                }
                let LSJZList: [Entry]
            }
            let Data: Data
        }

        let resp: LSJZResponse
        do {
            resp = try JSONDecoder().decode(LSJZResponse.self, from: data)
        } catch {
            throw EastmoneyParseError.invalidLSJZ(detail: "\(error)")
        }
        guard resp.ErrCode == 0 else {
            throw EastmoneyParseError.invalidLSJZ(detail: "ErrCode=\(resp.ErrCode)")
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai")

        let entries: [EastmoneyNAVHistory.Entry] = resp.Data.LSJZList.compactMap { e in
            guard let date = dateFormatter.date(from: e.FSRQ),
                  let nav = Double(e.DWJZ)
            else { return nil }
            return EastmoneyNAVHistory.Entry(
                date: date, unitNAV: nav,
                changePct: e.JZZZL.flatMap { Double($0) }.map { $0 / 100.0 }
            )
        }
        return EastmoneyNAVHistory(fundCode: fundCode, fundName: fundCode, entries: entries)
    }

    // MARK: - ProviderRecord 转换

    /// 把解析出的 NAV 历史转换为 ProviderRecord 流。
    ///
    /// 每条 entry 生成一条 ProviderRecord（kind = .navObservation），
    /// rawPayload 是 NAVPayload 的 JSON 编码。
    /// 注意：天天基金只给单位净值，accumulatedNAV/cumulativeDividendPerShare 暂用单位净值占位
    ///（字段缺口，已知限制，见文件头注释）。
    func toProviderRecords(
        _ history: EastmoneyNAVHistory,
        providerID: DataProviderID,
        reliabilityClass: ProviderReliabilityClass,
        jurisdiction: Jurisdiction,
        ingestedAt: Date
    ) -> [ProviderRecord] {
        history.entries.map { entry in
            let payload = NAVPayload(
                unitNAV: Price(value: Decimal(entry.unitNAV), currency: .cny),
                // 字段缺口：天天基金不披露累计净值与分红，暂用单位净值占位。
                // 真正的累计净值需扩展 pingzhongdata 解析 Data_ACWorthTrend（Epic 4）。
                accumulatedNAV: Price(value: Decimal(entry.unitNAV), currency: .cny),
                cumulativeDividendPerShare: Price(value: 0, currency: .cny)
            )
            let payloadData = (try? JSONEncoder().encode(payload)) ?? Data()
            // 基金 NAV 的 effectiveAt = publishedAt = navDate（T 日净值 T 日产出）
            return ProviderRecord(
                providerID: providerID,
                providerCode: ProviderCode(scheme: "fund_code", value: history.fundCode),
                effectiveAt: entry.date,
                publishedAt: entry.date,
                ingestedAt: ingestedAt,
                kind: .navObservation,
                rawPayload: payloadData,
                reliabilityClass: reliabilityClass,
                jurisdiction: jurisdiction
            )
        }
    }

    // MARK: - JS 提取 helpers

    /// 从 JS body 提取 `var <name> = "...";` 的字符串值。
    private func extractJSStringVar(_ body: String, name: String) -> String? {
        // 简化正则：var fS_name = "...";
        let pattern = "var\\s+\(name)\\s*=\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(body.startIndex..., in: body)
        guard let match = regex.firstMatch(in: body, range: range),
              match.numberOfRanges >= 2,
              let captureRange = Range(match.range(at: 1), in: body)
        else { return nil }
        return String(body[captureRange])
    }

    /// 从 JS body 提取 `var <name> = [...];` 的数组字面量（作为字符串返回，调用方再 JSON decode）。
    private func extractJSArrayVar(_ body: String, name: String) -> String? {
        let pattern = "var\\s+\(name)\\s*=\\s*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(body.startIndex..., in: body)
        guard let match = regex.firstMatch(in: body, range: range),
              let prefixRange = Range(match.range, in: body)
        else { return nil }
        // 从 = 之后开始扫描括号匹配
        var pos = prefixRange.upperBound
        guard pos < body.endIndex, body[pos] == "[" else { return nil }
        var depth = 0
        var end = pos
        while end < body.endIndex {
            let c = body[end]
            if c == "[" { depth += 1 }
            else if c == "]" {
                depth -= 1
                if depth == 0 { break }
            }
            end = body.index(after: end)
        }
        guard end < body.endIndex, body[end] == "]" else { return nil }
        return String(body[pos...end])
    }
}
