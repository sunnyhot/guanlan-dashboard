import Foundation

// MARK: - EastmoneyResponseParser（真实 Provider 解析链，审查 P0 修复）
//
// 解析天天基金（eastmoney）真实 HTTP 响应 → ProviderRecord。
// 这不是 stub——解析真实的 wire 格式：
//   - pingzhongdata JS：`var Data_netWorthTrend = [{"x":<tsMs>,"y":<nav>,"equityReturn":<pct>}];`
//     `var Data_ACWorthTrend = [{"x":<tsMs>,"y":<accumulatedNAV>}];`
//   - lsjz JSON：`{"ErrCode":0,"Data":{"LSJZList":[{"DWJZ":"<nav>","FSRQ":"YYYY-MM-DD","JZZZL":"<pct>","LJJZ":"<accumulatedNAV>"}]}}`
//
// 现有 QiemanPlatformNativeClient 内部也是解析这两个格式（见
// QiemanPlatformNativeClient.swift fetchFundHistorySeries 私有方法 + 测试 inline mock）。
// 本解析器独立实现，不修改现有 client（rollout REPO-7：不修改现有 client），
// 让 Provider Adapter 层可独立测试。
//
// **字段覆盖**（当前真实覆盖范围，审查 P3 更新）：
// - 单位净值 unitNAV：Data_netWorthTrend.y / LSJZ.DWJZ —— 完整
// - 累计净值 accumulatedNAV：Data_ACWorthTrend.y / LSJZ.LJJZ —— 完整（字段级合并填补缺失）
// - 当日涨跌幅 changePct：Data_netWorthTrend.equityReturn / LSJZ.JZZZL —— 完整
// - **每份分红 cumulativeDividendPerShare：天天基金 pingzhongdata 不直接披露**，
//   留 nil（不伪造 0）；需独立数据源（Epic 4+）
// - 持仓 shares / marketValue：天天基金 f10 不披露，weightPct 仅 FundLookThroughClient 有（Epic 4）

/// 天天基金 pingzhongdata JS 响应解析结果（单位净值历史）。
struct EastmoneyNAVHistory: Sendable, Hashable {
    let fundCode: String
    let fundName: String
    /// 单位净值序列（按时间升序，date 已归一化到 Asia/Shanghai 交易日界）
    let entries: [Entry]
    /// 解析过程中因格式异常被丢弃的行数（审查 P2：让调用方能审计静默丢弃，
    /// 默认 0；大量丢弃提示 schema 漂移）
    let droppedMalformedCount: Int

    init(fundCode: String, fundName: String, entries: [Entry], droppedMalformedCount: Int = 0) {
        self.fundCode = fundCode
        self.fundName = fundName
        self.entries = entries
        self.droppedMalformedCount = droppedMalformedCount
    }

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

        /// 字段级合并：以 self 为基准，用 other 填补 self 的 nil 字段。
        /// 用于 pingzhongdata 与 LSJZ 同日条目合并（审查 P1：避免整条丢弃导致
        /// LSJZ 的 LJJZ 在 ping 缺 accumulatedNAV 时丢失）。
        func mergingFields(from other: EastmoneyNAVHistory.Entry) -> EastmoneyNAVHistory.Entry {
            EastmoneyNAVHistory.Entry(
                date: date,
                unitNAV: unitNAV,
                changePct: changePct ?? other.changePct,
                accumulatedNAV: accumulatedNAV ?? other.accumulatedNAV
            )
        }
    }
}

enum EastmoneyParseError: Error, Equatable, Sendable {
    /// pingzhongdata JS 里找不到 Data_netWorthTrend 变量
    case missingNetWorthTrend
    /// Data_netWorthTrend 数组存在但 JSON 解析失败（schema 漂移，审查 P1：不静默吞）
    case netWorthTrendDecodeFailed(detail: String)
    /// Data_ACWorthTrend 变量存在但 JSON 解析失败（审查 P2：区分 missing 与 malformed）
    case accumulatedTrendDecodeFailed(detail: String)
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

        // Data_netWorthTrend（单位净值历史，必填）。审查 P2：用 typed 提取，
        // 声明缺失或值非数组都视为错误（必填字段不能合法缺失）
        let trendExtraction = extractJSArrayVarTyped(body, name: "Data_netWorthTrend")
        let trendJSON: String
        switch trendExtraction {
        case .extracted(let s): trendJSON = s
        case .notDeclared: throw EastmoneyParseError.missingNetWorthTrend
        case .declaredButMalformed(let reason):
            throw EastmoneyParseError.netWorthTrendDecodeFailed(
                detail: "Data_netWorthTrend declared but malformed: \(reason)"
            )
        }
        guard let trendData = trendJSON.data(using: .utf8) else {
            throw EastmoneyParseError.netWorthTrendDecodeFailed(detail: "not utf8")
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

        // Data_ACWorthTrend（累计净值历史）。审查 P2：用 typed 提取区分三种情况：
        // - .notDeclared：变量未声明 → 合法缺口，accumulatedNAV 留 nil
        // - .declaredButMalformed：变量声明存在但值非数组（null / 截断）→ schema 漂移，抛错
        // - .extracted：成功 → 解析；解析失败也抛错
        var accumulatedByDay: [Date: Double] = [:]
        switch extractJSArrayVarTyped(body, name: "Data_ACWorthTrend") {
        case .notDeclared:
            break   // 合法缺口
        case .declaredButMalformed(let reason):
            throw EastmoneyParseError.accumulatedTrendDecodeFailed(
                detail: "Data_ACWorthTrend declared but malformed: \(reason)"
            )
        case .extracted(let acJSON):
            guard let acData = acJSON.data(using: .utf8) else {
                throw EastmoneyParseError.accumulatedTrendDecodeFailed(detail: "not utf8")
            }
            struct RawAC: Decodable { let x: Double; let y: Double }
            let acEntries: [RawAC]
            do {
                acEntries = try JSONDecoder().decode([RawAC].self, from: acData)
            } catch {
                throw EastmoneyParseError.accumulatedTrendDecodeFailed(detail: "\(error)")
            }
            for ac in acEntries {
                let day = Self.normalizeToTradingDay(Date(timeIntervalSince1970: ac.x / 1000.0))
                accumulatedByDay[day] = ac.y
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

        // 审查 P2：compactMap 会静默删除格式异常的行，改为显式计数。
        // 个别行异常可能是边缘数据（保留 + 计入 droppedMalformedCount）；
        // 全部行都异常视为整体 schema 失败（抛错）。
        var entries: [EastmoneyNAVHistory.Entry] = []
        var dropped = 0
        for e in resp.Data.LSJZList {
            guard let parsedDate = dateFormatter.date(from: e.FSRQ),
                  let nav = Double(e.DWJZ)
            else {
                dropped += 1
                continue
            }
            let day = Self.normalizeToTradingDay(parsedDate)
            entries.append(EastmoneyNAVHistory.Entry(
                date: day,
                unitNAV: nav,
                changePct: e.JZZZL.flatMap { Double($0) }.map { $0 / 100.0 },
                accumulatedNAV: e.LJJZ.flatMap(Double.init)
            ))
        }
        if !resp.Data.LSJZList.isEmpty && entries.isEmpty {
            throw EastmoneyParseError.invalidLSJZ(detail: "all \(resp.Data.LSJZList.count) LSJZList entries malformed")
        }
        return EastmoneyNAVHistory(
            fundCode: fundCode, fundName: fundCode,
            entries: entries, droppedMalformedCount: dropped
        )
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

    /// 从 JS body 提取 `var <name> = [...];` 的数组字面量的结果（三态）。
    /// 审查 P2：区分「变量声明不存在」（合法缺口）与「声明存在但值非数组 / 截断」
    /// （schema 漂移，应抛错），不能都返回 nil 让调用方当成合法缺失。
    enum JSArrayExtraction: Equatable {
        /// 变量未声明（合法缺口）
        case notDeclared
        /// 变量声明存在但值不是合法数组字面量（null / 截断 / 非数组）
        case declaredButMalformed(reason: String)
        /// 成功提取的数组字面量字符串
        case extracted(String)
    }

    private func extractJSArrayVarTyped(_ body: String, name: String) -> JSArrayExtraction {
        let pattern = "var\\s+\(name)\\s*=\\s*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return .notDeclared
        }
        let range = NSRange(body.startIndex..., in: body)
        guard let match = regex.firstMatch(in: body, range: range),
              let prefixRange = Range(match.range, in: body)
        else {
            return .notDeclared
        }
        let pos = prefixRange.upperBound
        // 跳过声明后的空白
        let firstNonWhitespace = body[pos...].first { !$0.isWhitespace }
        guard let firstChar = firstNonWhitespace else {
            return .declaredButMalformed(reason: "empty value after =")
        }
        if firstChar != "[" {
            // 声明存在但值不是数组（如 null、字符串、数字）→ schema 漂移
            let preview = String(body[pos...].prefix(20))
            return .declaredButMalformed(reason: "value is not an array literal: \(preview)")
        }
        // 从 [ 开始扫描括号匹配
        guard let startPos = body[pos...].firstIndex(of: "[") else {
            return .declaredButMalformed(reason: "no opening bracket")
        }
        var depth = 0
        var end = startPos
        while end < body.endIndex {
            let c = body[end]
            if c == "[" { depth += 1 }
            else if c == "]" {
                depth -= 1
                if depth == 0 { break }
            }
            end = body.index(after: end)
        }
        guard end < body.endIndex, body[end] == "]" else {
            return .declaredButMalformed(reason: "array literal not closed")
        }
        return .extracted(String(body[startPos...end]))
    }

    /// 旧接口保留兼容（Data_netWorthTrend 用，那里 nil 仍表示「变量不存在」，
    /// 因为必填项缺失已经走 missingNetWorthTrend 错误）。
    private func extractJSArrayVar(_ body: String, name: String) -> String? {
        switch extractJSArrayVarTyped(body, name: name) {
        case .extracted(let s): return s
        case .notDeclared, .declaredButMalformed: return nil
        }
    }
}
