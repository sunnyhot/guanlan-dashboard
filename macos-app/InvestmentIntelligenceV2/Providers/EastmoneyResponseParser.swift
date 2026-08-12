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
    /// 单位净值序列（按时间升序，date 已归一化到 Asia/Shanghai 交易日界）
    let entries: [Entry]

    struct Entry: Sendable, Hashable {
        /// 净值日期（**归一化到 Asia/Shanghai 00:00**，审查 P1：避免 pingzhongdata
        /// 的盘中时刻与 LSJZ 的零点解析错位导致去重失败）
        let date: Date
        /// 单位净值
        let unitNAV: Double
        /// 当日涨跌幅（小数，如 0.012 表示 1.2%）
        let changePct: Double?
        /// 累计净值（Data_ACWorthTrend / LJJZ 提供；缺失为 nil，不伪造）
        let accumulatedNAV: Double?
    }
}

enum EastmoneyParseError: Error, Equatable, Sendable {
    /// pingzhongdata JS 里找不到 Data_netWorthTrend 变量
    case missingNetWorthTrend
    /// Data_netWorthTrend 数组存在但 JSON 解析失败（schema 漂移，审查 P1：不静默吞）
    case netWorthTrendDecodeFailed(detail: String)
    /// lsjz JSON 结构异常
    case invalidLSJZ(detail: String)
    /// 响应体为空
    case emptyBody
}

/// 天天基金真实响应解析器。
struct EastmoneyResponseParser: Sendable {

    /// Asia/Shanghai 日历（用于日期归一化）。
    private static var shanghaiCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }

    /// 把任意时刻归一化到 Asia/Shanghai 当日 00:00（交易日界）。
    static func normalizeToTradingDay(_ date: Date) -> Date {
        shanghaiCalendar.startOfDay(for: date)
    }

    /// 解析 pingzhongdata JS 响应（基金净值历史 + 累计净值）。
    ///
    /// 真实 wire 格式（来自现有测试 QiemanPlatformFundQuoteFallbackTests 的 inline mock）：
    /// ```
    /// var fS_name = "易方达消费行业股票";
    /// var Data_netWorthTrend = [{"x":1719820800000,"y":3.5,"equityReturn":0.012}, ...];
    /// var Data_ACWorthTrend = [{"x":1719820800000,"y":4.2}, ...];
    /// ```
    func parsePingzhongdata(_ body: String, fundCode: String) throws -> EastmoneyNAVHistory {
        guard !body.isEmpty else { throw EastmoneyParseError.emptyBody }

        let fundName = extractJSStringVar(body, name: "fS_name") ?? fundCode

        // Data_netWorthTrend（单位净值历史，必填）
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
        // 审查 P1：schema 漂移不能静默吞为「零条数据」，应抛错
        let rawEntries: [RawEntry]
        do {
            rawEntries = try JSONDecoder().decode([RawEntry].self, from: trendData)
        } catch {
            throw EastmoneyParseError.netWorthTrendDecodeFailed(detail: "\(error)")
        }

        // Data_ACWorthTrend（累计净值历史，可选——缺失时 accumulatedNAV 为 nil）
        var accumulatedByDay: [Date: Double] = [:]
        if let acJSON = extractJSArrayVar(body, name: "Data_ACWorthTrend"),
           let acData = acJSON.data(using: .utf8) {
            struct RawAC: Decodable { let x: Double; let y: Double }
            if let acEntries = try? JSONDecoder().decode([RawAC].self, from: acData) {
                for ac in acEntries {
                    let day = Self.normalizeToTradingDay(Date(timeIntervalSince1970: ac.x / 1000.0))
                    accumulatedByDay[day] = ac.y
                }
            }
        }

        let entries: [EastmoneyNAVHistory.Entry] = rawEntries.map { raw in
            let day = Self.normalizeToTradingDay(Date(timeIntervalSince1970: raw.x / 1000.0))
            return EastmoneyNAVHistory.Entry(
                date: day,
                unitNAV: raw.y,
                changePct: raw.equityReturn,
                accumulatedNAV: accumulatedByDay[day]   // 同交易日匹配，缺失为 nil
            )
        }
        return EastmoneyNAVHistory(
            fundCode: fundCode, fundName: fundName, entries: entries
        )
    }

    /// 解析 lsjz JSON 响应（近期官方净值，用于补充 pingzhongdata 的最新段）。
    ///
    /// 真实 wire 格式（含 LJJZ 累计净值）：
    /// ```
    /// {"ErrCode":0,"Data":{"LSJZList":[{"DWJZ":"3.5","FSRQ":"2024-07-18","JZZZL":"1.2","LJJZ":"4.2"}, ...]}}
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
                    let LJJZ: String?    // 累计净值（审查 P1：解析真实值，不伪造）
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
            guard let parsedDate = dateFormatter.date(from: e.FSRQ),
                  let nav = Double(e.DWJZ)
            else { return nil }
            // 归一化到 Asia/Shanghai 交易日界（审查 P1：与 pingzhongdata 统一）
            let day = Self.normalizeToTradingDay(parsedDate)
            return EastmoneyNAVHistory.Entry(
                date: day,
                unitNAV: nav,
                changePct: e.JZZZL.flatMap { Double($0) }.map { $0 / 100.0 },
                accumulatedNAV: e.LJJZ.flatMap(Double.init)   // 真实累计净值，缺失为 nil
            )
        }
        return EastmoneyNAVHistory(fundCode: fundCode, fundName: fundCode, entries: entries)
    }

    // MARK: - ProviderRecord 转换

    /// 把解析出的 NAV 历史转换为 ProviderRecord 流。
    ///
    /// 每条 entry 生成一条 ProviderRecord（kind = .navObservation），
    /// rawPayload 是 NAVPayload 的 JSON 编码。
    /// accumulatedNAV 来自 Data_ACWorthTrend / LJJZ（真实值，缺失为 nil）；
    /// cumulativeDividendPerShare 天天基金不直接披露，留 nil（审查 P1：不伪造默认值）。
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
                accumulatedNAV: entry.accumulatedNAV.map { Price(value: Decimal($0), currency: .cny) },
                cumulativeDividendPerShare: nil   // 天天基金不直接披露，留缺口（业务层按 nil 处理）
            )
            let payloadData = (try? JSONEncoder().encode(payload)) ?? Data()
            // entry.date 已归一化到 Asia/Shanghai 交易日界，effectiveAt = publishedAt = navDate
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
        let pos = prefixRange.upperBound
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
