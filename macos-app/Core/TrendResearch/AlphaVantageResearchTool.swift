import CryptoKit
import Foundation

struct AlphaVantageResearchTool: TrendResearchTool {
    enum Mode: String, Decodable {
        case etfProfile
        case earningsCalendar
        case dailyAnalytics
    }

    private struct Params: Decodable {
        let mode: Mode
        let research_target: TrendResearchTarget
        let symbol: String
        let horizon: String?
    }

    private struct DailyPoint {
        let date: String
        let close: Double
        let volume: Double?
    }

    let client: any AlphaVantageClientProtocol
    let cache: AlphaVantageResponseCache

    let name = "alpha_vantage_research"
    let description = "查询 Alpha Vantage 的结构化市场数据补充：ETF_PROFILE（ETF 持仓与行业）、EARNINGS_CALENDAR（未来财报日历）或 TIME_SERIES_DAILY（日线并在本地计算收益、均线、波动率和回撤）。它是第三方供应商数据，不是官方一手证据；应在 SEC 等官方源之后、普通网页搜索之前使用。"
    let parameters: AgentJSONValue = [
        "type": "object",
        "properties": [
            "mode": [
                "type": "string",
                "enum": ["etfProfile", "earningsCalendar", "dailyAnalytics"]
            ],
            "research_target": [
                "type": "object",
                "properties": [
                    "kind": ["type": "string", "enum": ["asset"]],
                    "key": ["type": "string", "minLength": 1, "maxLength": 120],
                    "entityCodes": [
                        "type": "array",
                        "maxItems": 20,
                        "items": ["type": "string"]
                    ],
                    "sectorKeys": [
                        "type": "array",
                        "maxItems": 20,
                        "items": ["type": "string"]
                    ],
                    "assetClassKeys": [
                        "type": "array",
                        "maxItems": 10,
                        "items": ["type": "string"]
                    ]
                ],
                "required": ["kind", "key"],
                "additionalProperties": false
            ],
            "symbol": [
                "type": "string",
                "minLength": 1,
                "maxLength": 20,
                "description": "必须来自本次直接持仓或基金穿透结果；A 股代码会映射为 Alpha Vantage 的 .SHH/.SHZ 格式"
            ],
            "horizon": [
                "type": "string",
                "enum": ["3month", "6month", "12month"],
                "description": "仅 earningsCalendar 使用，默认 3month"
            ]
        ],
        "required": ["mode", "research_target", "symbol"],
        "additionalProperties": false
    ]

    func execute(
        argumentsJSON: String,
        context: TrendResearchToolContext
    ) async -> TrendResearchToolResult {
        guard context.alphaVantageSettings.isConfigured else {
            return failure(
                code: "alpha_vantage_not_configured",
                message: "未启用或未填写 Alpha Vantage API Key"
            )
        }
        let params: Params
        do {
            params = try JSONDecoder().decode(Params.self, from: Data(argumentsJSON.utf8))
        } catch {
            return failure(
                code: "invalid_arguments",
                message: "参数不是合法 JSON：\(error.localizedDescription)"
            )
        }
        guard params.research_target.kind == .asset else {
            return failure(
                code: "invalid_arguments",
                message: "Alpha Vantage 研究只接受 asset 目标"
            )
        }

        let symbol = Self.normalizedSymbol(params.symbol)
        guard context.snapshot.eligibleAlphaVantageSymbols.contains(symbol) else {
            return failure(
                code: "invalid_arguments",
                message: "\(symbol) 不在本次直接持仓或基金穿透出的可研究标的中"
            )
        }

        do {
            switch params.mode {
            case .etfProfile:
                return try await etfProfile(
                    symbol: symbol,
                    target: params.research_target,
                    context: context
                )
            case .earningsCalendar:
                let horizon = params.horizon ?? "3month"
                guard ["3month", "6month", "12month"].contains(horizon) else {
                    return failure(
                        code: "invalid_arguments",
                        message: "horizon 只能是 3month/6month/12month"
                    )
                }
                return try await earningsCalendar(
                    symbol: symbol,
                    horizon: horizon,
                    target: params.research_target,
                    context: context
                )
            case .dailyAnalytics:
                return try await dailyAnalytics(
                    symbol: symbol,
                    target: params.research_target,
                    context: context
                )
            }
        } catch {
            return failure(
                code: "alpha_vantage_request_failed",
                message: error.localizedDescription
            )
        }
    }

    private func etfProfile(
        symbol: String,
        target: TrendResearchTarget,
        context: TrendResearchToolContext
    ) async throws -> TrendResearchToolResult {
        let descriptor = AlphaVantageRequestDescriptor(
            function: .etfProfile,
            symbol: symbol,
            cacheTTL: 24 * 60 * 60
        )
        let outcome = try await cache.fetch(
            descriptor,
            settings: context.alphaVantageSettings,
            client: client
        )
        guard let root = try JSONSerialization.jsonObject(with: outcome.data) as? [String: Any] else {
            throw AlphaVantageClientError.invalidResponse("ETF_PROFILE 不是 JSON 对象")
        }
        let holdings = arrayOfObjects(root["holdings"])
            .prefix(20)
            .compactMap { row -> [String: Any]? in
                let code = string(row["symbol"])
                guard !code.isEmpty else { return nil }
                return [
                    "symbol": code,
                    "name": string(row["description"] ?? row["name"]),
                    "weight": number(row["weight"]) ?? 0
                ]
            }
        let sectors = arrayOfObjects(root["sectors"])
            .prefix(20)
            .compactMap { row -> [String: Any]? in
                let name = string(row["sector"] ?? row["name"])
                guard !name.isEmpty else { return nil }
                return [
                    "name": name,
                    "weight": number(row["weight"]) ?? 0
                ]
            }
        guard !holdings.isEmpty || !sectors.isEmpty else {
            throw AlphaVantageClientError.invalidResponse("ETF_PROFILE 没有持仓或行业数据")
        }
        let retrievedAt = ISO8601DateFormatter().string(from: Date())
        let evidenceID = "vendor:alphavantage:etf:\(symbol):\(contentHash(outcome.data))"
        let topHoldingText = holdings.prefix(5).map {
            "\($0["symbol"] ?? "") \(formatPercent($0["weight"]))"
        }.joined(separator: "、")
        let topSectorText = sectors.prefix(5).map {
            "\($0["name"] ?? "") \(formatPercent($0["weight"]))"
        }.joined(separator: "、")
        let evidence = TrendEvidence(
            id: evidenceID,
            sourceName: "Alpha Vantage ETF Profile",
            title: "\(symbol) ETF 结构化画像",
            url: "https://www.alphavantage.co/query?function=ETF_PROFILE&symbol=\(symbol)",
            publishedAt: nil,
            retrievedAt: retrievedAt,
            summary: [
                topHoldingText.isEmpty ? nil : "主要持仓：\(topHoldingText)",
                topSectorText.isEmpty ? nil : "主要行业：\(topSectorText)"
            ].compactMap { $0 }.joined(separator: "；"),
            metadata: TrendEvidenceMetadata(
                sourceKind: .licensedMarketData,
                sourceTier: .authoritative,
                publisherKey: "alphavantage.co",
                requestedTopicKeys: target.topicKeys,
                entityCodes: [symbol] + holdings.compactMap { $0["symbol"] as? String },
                entityNames: [target.key],
                sectorKeys: sectors.compactMap { $0["name"] as? String },
                metadataConfidence: .deterministic
            )
        )
        await context.evidenceLedger.record([evidence])
        return .content(
            TrendResearchToolEnvelope.success(
                [
                    "provider": "Alpha Vantage",
                    "mode": Mode.etfProfile.rawValue,
                    "symbol": symbol,
                    "fund_type": string(root["fund_type"]),
                    "net_assets": number(root["net_assets"]) ?? NSNull(),
                    "net_expense_ratio": number(root["net_expense_ratio"]) ?? NSNull(),
                    "portfolio_turnover": number(root["portfolio_turnover"]) ?? NSNull(),
                    "dividend_yield": number(root["dividend_yield"]) ?? NSNull(),
                    "holdings": Array(holdings),
                    "sectors": Array(sectors),
                    "asset_allocation": root["asset_allocation"] ?? [:],
                    "cache_hit": outcome.cacheHit,
                    "daily_requests_remaining": await cache.remainingBudget(
                        settings: context.alphaVantageSettings
                    ),
                    "evidence_id": evidenceID,
                    "evidence_boundary": "第三方供应商结构化数据，不是发行人、交易所或监管机构官方披露"
                ],
                evidenceIDs: [evidenceID]
            )
        )
    }

    private func earningsCalendar(
        symbol: String,
        horizon: String,
        target: TrendResearchTarget,
        context: TrendResearchToolContext
    ) async throws -> TrendResearchToolResult {
        let descriptor = AlphaVantageRequestDescriptor(
            function: .earningsCalendar,
            symbol: symbol,
            parameters: ["horizon": horizon, "datatype": "csv"],
            cacheTTL: 12 * 60 * 60
        )
        let outcome = try await cache.fetch(
            descriptor,
            settings: context.alphaVantageSettings,
            client: client
        )
        let rows = parseCSV(outcome.data).filter {
            Self.normalizedSymbol($0["symbol"] ?? "") == symbol
        }
        guard !rows.isEmpty else {
            throw AlphaVantageClientError.invalidResponse("财报日历没有返回 \(symbol) 的记录")
        }
        let retrievedAt = ISO8601DateFormatter().string(from: Date())
        let reportDates = rows.compactMap { $0["reportDate"] ?? $0["report_date"] }
        let evidenceID = "vendor:alphavantage:earnings:\(symbol):\(reportDates.first ?? contentHash(outcome.data))"
        let evidence = TrendEvidence(
            id: evidenceID,
            sourceName: "Alpha Vantage Earnings Calendar",
            title: "\(symbol) 财报日历",
            url: "https://www.alphavantage.co/query?function=EARNINGS_CALENDAR&symbol=\(symbol)&horizon=\(horizon)",
            publishedAt: nil,
            retrievedAt: retrievedAt,
            summary: "\(symbol) 在 \(horizon) 窗口内的预计财报日期：\(reportDates.joined(separator: "、"))。日期属于供应商日历，发布前可能调整。",
            metadata: TrendEvidenceMetadata(
                sourceKind: .licensedMarketData,
                sourceTier: .authoritative,
                publisherKey: "alphavantage.co",
                requestedTopicKeys: target.topicKeys,
                entityCodes: [symbol],
                entityNames: [target.key],
                metadataConfidence: .deterministic
            )
        )
        await context.evidenceLedger.record([evidence])
        return .content(
            TrendResearchToolEnvelope.success(
                [
                    "provider": "Alpha Vantage",
                    "mode": Mode.earningsCalendar.rawValue,
                    "symbol": symbol,
                    "horizon": horizon,
                    "events": rows,
                    "cache_hit": outcome.cacheHit,
                    "daily_requests_remaining": await cache.remainingBudget(
                        settings: context.alphaVantageSettings
                    ),
                    "evidence_id": evidenceID,
                    "evidence_boundary": "供应商预期日历，不是发行人正式公告；日期可能调整"
                ],
                evidenceIDs: [evidenceID]
            )
        )
    }

    private func dailyAnalytics(
        symbol: String,
        target: TrendResearchTarget,
        context: TrendResearchToolContext
    ) async throws -> TrendResearchToolResult {
        let descriptor = AlphaVantageRequestDescriptor(
            function: .timeSeriesDaily,
            symbol: symbol,
            parameters: ["outputsize": "compact", "datatype": "json"],
            cacheTTL: 6 * 60 * 60
        )
        let outcome = try await cache.fetch(
            descriptor,
            settings: context.alphaVantageSettings,
            client: client
        )
        guard let root = try JSONSerialization.jsonObject(with: outcome.data) as? [String: Any],
              let series = root["Time Series (Daily)"] as? [String: Any] else {
            throw AlphaVantageClientError.invalidResponse("缺少 Time Series (Daily)")
        }
        let points = series.compactMap { date, raw -> DailyPoint? in
            guard let row = raw as? [String: Any],
                  let close = number(row["4. close"]) else { return nil }
            return DailyPoint(
                date: date,
                close: close,
                volume: number(row["5. volume"])
            )
        }.sorted { $0.date > $1.date }
        guard let latest = points.first, points.count >= 2 else {
            throw AlphaVantageClientError.invalidResponse("日线数据不足")
        }

        let closes = points.map(\.close)
        let dailyReturns = zip(closes, closes.dropFirst()).compactMap { newer, older -> Double? in
            guard older != 0 else { return nil }
            return newer / older - 1
        }
        let analytics: [String: Any] = [
            "latest_date": latest.date,
            "latest_close": latest.close,
            "return_5d_pct": percentReturn(closes, days: 5) ?? NSNull(),
            "return_20d_pct": percentReturn(closes, days: 20) ?? NSNull(),
            "return_60d_pct": percentReturn(closes, days: 60) ?? NSNull(),
            "sma_20": average(Array(closes.prefix(20))) ?? NSNull(),
            "sma_60": average(Array(closes.prefix(60))) ?? NSNull(),
            "distance_to_sma_20_pct": distanceToAverage(closes, days: 20) ?? NSNull(),
            "distance_to_sma_60_pct": distanceToAverage(closes, days: 60) ?? NSNull(),
            "annualized_volatility_pct": standardDeviation(dailyReturns) * sqrt(252) * 100,
            "max_drawdown_pct": maxDrawdown(Array(closes.reversed())) * 100,
            "average_volume_20d": average(points.prefix(20).compactMap(\.volume)) ?? NSNull(),
            "observations": points.count
        ]
        let retrievedAt = ISO8601DateFormatter().string(from: Date())
        let evidenceID = "vendor:alphavantage:daily:\(symbol):\(latest.date)"
        let evidence = TrendEvidence(
            id: evidenceID,
            sourceName: "Alpha Vantage Daily",
            title: "\(symbol) 日线统计（截至 \(latest.date)）",
            url: "https://www.alphavantage.co/query?function=TIME_SERIES_DAILY&symbol=\(symbol)",
            publishedAt: latest.date,
            retrievedAt: retrievedAt,
            summary: "\(symbol) 收盘 \(compactNumber(latest.close))；5/20/60 日收益分别为 \(formatOptional(percentReturn(closes, days: 5)))、\(formatOptional(percentReturn(closes, days: 20)))、\(formatOptional(percentReturn(closes, days: 60)))；年化历史波动率 \(String(format: "%.2f%%", standardDeviation(dailyReturns) * sqrt(252) * 100))。指标均由 App 基于供应商日线本地计算。",
            metadata: TrendEvidenceMetadata(
                sourceKind: .licensedMarketData,
                sourceTier: .authoritative,
                publisherKey: "alphavantage.co",
                requestedTopicKeys: target.topicKeys,
                entityCodes: [symbol],
                entityNames: [target.key],
                quoteType: .previousClose,
                freshnessStatus: .previousSessionClose,
                metadataConfidence: .ruleDerived
            )
        )
        await context.evidenceLedger.record([evidence])
        return .content(
            TrendResearchToolEnvelope.success(
                [
                    "provider": "Alpha Vantage",
                    "mode": Mode.dailyAnalytics.rawValue,
                    "symbol": symbol,
                    "analytics": analytics,
                    "cache_hit": outcome.cacheHit,
                    "daily_requests_remaining": await cache.remainingBudget(
                        settings: context.alphaVantageSettings
                    ),
                    "evidence_id": evidenceID,
                    "evidence_boundary": "第三方日线；指标由 App 本地计算，不代表实时行情或未来表现"
                ],
                evidenceIDs: [evidenceID]
            )
        )
    }

    fileprivate static func normalizedSymbol(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard value.count == 6, value.allSatisfy(\.isNumber) else {
            return value
        }
        if ["5", "6", "9"].contains(String(value.prefix(1))) {
            return "\(value).SHH"
        }
        if ["0", "1", "2", "3"].contains(String(value.prefix(1))) {
            return "\(value).SHZ"
        }
        return value
    }

    private func parseCSV(_ data: Data) -> [[String: String]] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let headerLine = lines.first else { return [] }
        let headers = csvFields(headerLine).map {
            $0.trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines.union(
                    CharacterSet(charactersIn: "\u{FEFF}")
                )
            )
        }
        return lines.dropFirst().compactMap { line in
            let fields = csvFields(line)
            guard fields.count == headers.count else { return nil }
            return Dictionary(uniqueKeysWithValues: zip(headers, fields))
        }
    }

    private func csvFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                let next = line.index(after: index)
                if quoted, next < line.endIndex, line[next] == "\"" {
                    current.append("\"")
                    index = next
                } else {
                    quoted.toggle()
                }
            } else if character == ",", !quoted {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index = line.index(after: index)
        }
        fields.append(current)
        return fields
    }

    private func arrayOfObjects(_ value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }

    private func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String {
            return Double(
                value
                    .replacingOccurrences(of: "%", with: "")
                    .replacingOccurrences(of: ",", with: "")
            )
        }
        return nil
    }

    private func percentReturn(_ closes: [Double], days: Int) -> Double? {
        guard closes.indices.contains(days), closes[days] != 0 else { return nil }
        return (closes[0] / closes[days] - 1) * 100
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func distanceToAverage(_ closes: [Double], days: Int) -> Double? {
        guard let latest = closes.first,
              let average = average(Array(closes.prefix(days))),
              average != 0,
              closes.count >= days else { return nil }
        return (latest / average - 1) * 100
    }

    private func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) }
            / Double(values.count - 1)
        return sqrt(variance)
    }

    private func maxDrawdown(_ chronologicalCloses: [Double]) -> Double {
        guard var peak = chronologicalCloses.first, peak > 0 else { return 0 }
        var worst = 0.0
        for close in chronologicalCloses {
            peak = max(peak, close)
            worst = min(worst, close / peak - 1)
        }
        return worst
    }

    private func contentHash(_ data: Data) -> String {
        SHA256.hash(data: data)
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func formatPercent(_ value: Any?) -> String {
        guard let value = number(value) else { return "—" }
        return String(format: "%.2f%%", abs(value) <= 1 ? value * 100 : value)
    }

    private func formatOptional(_ value: Double?) -> String {
        value.map { String(format: "%.2f%%", $0) } ?? "—"
    }

    private func compactNumber(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private func failure(code: String, message: String) -> TrendResearchToolResult {
        .content(
            TrendResearchToolEnvelope.error(code: code, message: message),
            isError: true
        )
    }
}

extension TrendResearchSnapshot {
    var eligibleAlphaVantageSymbols: [String] {
        let direct = assets.compactMap { asset -> String? in
            guard let code = asset.code else { return nil }
            let hasLetters = code.unicodeScalars.contains {
                CharacterSet.letters.contains($0)
            }
            guard asset.assetType == PersonalAssetType.stock.displayName || hasLetters else {
                return nil
            }
            return code
        }
        let underlying = lookThrough?.topPositions
            .filter { $0.kind == .stock }
            .map(\.code)
            ?? []
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"
        )
        return Array(
            Set((direct + underlying).compactMap { raw -> String? in
                let symbol = AlphaVantageResearchTool.normalizedSymbol(raw)
                guard !symbol.isEmpty,
                      symbol.count <= 20,
                      symbol.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                    return nil
                }
                let base = symbol.split(separator: ".").first.map(String.init) ?? symbol
                guard base.unicodeScalars.contains(where: {
                    CharacterSet.letters.contains($0)
                }) || base.count == 6 else {
                    return nil
                }
                return symbol
            })
        ).sorted()
    }
}
