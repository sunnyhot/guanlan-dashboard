import Foundation

struct SECOfficialResearchTool: TrendResearchTool {
    enum Mode: String, Decodable {
        case recentFilings
        case companyFacts
    }

    private struct Params: Decodable {
        let mode: Mode
        let research_target: TrendResearchTarget
        let ticker: String
        let forms: [String]?
        let days: Int?
        let max_results: Int?
    }

    private struct CompanyIdentity {
        let cik: Int
        let ticker: String
        let name: String
        let exchange: String?

        var paddedCIK: String {
            String(format: "%010d", cik)
        }
    }

    private struct FilingRow {
        let accessionNumber: String
        let filingDate: String
        let reportDate: String?
        let acceptanceDateTime: String?
        let form: String
        let items: String?
        let primaryDocument: String
        let primaryDocDescription: String?
        let isXBRL: Bool
        let isInlineXBRL: Bool
    }

    private struct FinancialMetric {
        let key: String
        let label: String
        let concept: String
        let value: Double
        let unit: String
        let start: String?
        let end: String
        let filed: String
        let form: String
        let frame: String?
    }

    private struct MetricSpec {
        let key: String
        let label: String
        let concepts: [String]
    }

    let client: any SECOfficialSourceClientProtocol
    let cache: SECOfficialSourceCache

    let name = "official_sec_research"
    let description = "直接查询美国 SEC EDGAR 官方公开数据。recentFilings 返回与组合内美股或基金底层美股相关的近期 8-K/10-Q/10-K/6-K/20-F/Form 4 等申报；companyFacts 返回 SEC XBRL 财务事实。官方申报只证明披露事实，不自动代表利好或利空。"
    let parameters: AgentJSONValue = [
        "type": "object",
        "properties": [
            "mode": [
                "type": "string",
                "enum": ["recentFilings", "companyFacts"]
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
            "ticker": [
                "type": "string",
                "minLength": 1,
                "maxLength": 12,
                "description": "必须是当前直接持仓或基金穿透结果中的美股代码"
            ],
            "forms": [
                "type": "array",
                "maxItems": 8,
                "items": [
                    "type": "string",
                    "enum": ["8-K", "10-Q", "10-K", "6-K", "20-F", "40-F", "4", "13D", "13G"]
                ],
                "description": "recentFilings 过滤表单；默认查询重大事件、定期报告和内部人申报"
            ],
            "days": [
                "type": "integer",
                "minimum": 1,
                "maximum": 730,
                "description": "recentFilings 回看天数，默认 120"
            ],
            "max_results": [
                "type": "integer",
                "minimum": 1,
                "maximum": 20,
                "description": "最大返回条数，默认 10"
            ]
        ],
        "required": ["mode", "research_target", "ticker"],
        "additionalProperties": false
    ]

    func execute(
        argumentsJSON: String,
        context: TrendResearchToolContext
    ) async -> TrendResearchToolResult {
        guard context.officialSourceSettings.isSECConfigured else {
            return failure(
                code: "official_sec_not_configured",
                message: SECOfficialSourceClientError.missingContact.localizedDescription
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
            return failure(code: "invalid_arguments", message: "SEC 官方源只接受 asset 研究目标")
        }

        let ticker = normalizedTicker(params.ticker)
        guard eligibleTickers(in: context.snapshot).contains(ticker) else {
            return failure(
                code: "invalid_arguments",
                message: "\(ticker) 不在本次直接持仓或基金穿透出的美股标的中"
            )
        }
        let maxResults = params.max_results ?? 10
        guard (1...20).contains(maxResults) else {
            return failure(code: "invalid_arguments", message: "max_results 必须在 1...20 之间")
        }

        do {
            let identity = try await resolveCompany(
                ticker: ticker,
                settings: context.officialSourceSettings
            )
            switch params.mode {
            case .recentFilings:
                return try await recentFilingsResult(
                    identity: identity,
                    params: params,
                    maxResults: maxResults,
                    context: context
                )
            case .companyFacts:
                return try await companyFactsResult(
                    identity: identity,
                    target: params.research_target,
                    context: context
                )
            }
        } catch is CancellationError {
            return failure(code: "official_sec_cancelled", message: "SEC EDGAR 查询已取消")
        } catch {
            return failure(code: "official_sec_failed", message: error.localizedDescription)
        }
    }

    private func recentFilingsResult(
        identity: CompanyIdentity,
        params: Params,
        maxResults: Int,
        context: TrendResearchToolContext
    ) async throws -> TrendResearchToolResult {
        let url = URL(
            string: "https://data.sec.gov/submissions/CIK\(identity.paddedCIK).json"
        )!
        let outcome = try await cache.fetch(
            SECRequestDescriptor(url: url, cacheTTL: 15 * 60),
            settings: context.officialSourceSettings,
            client: client
        )
        let rows = try parseRecentFilings(outcome.data)
        let allowedForms = Set(
            params.forms
                ?? ["8-K", "10-Q", "10-K", "6-K", "20-F", "40-F", "4"]
        )
        let cutoff = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -(params.days ?? 120),
            to: Date()
        ) ?? .distantPast
        let dateFormatter = Self.dayFormatter
        let selected = rows.filter {
            allowedForms.contains($0.form)
                && (dateFormatter.date(from: $0.filingDate) ?? .distantPast) >= cutoff
        }
        .prefix(maxResults)

        let retrievedAt = ISO8601DateFormatter().string(from: Date())
        let evidence = selected.map { row in
            let filingURL = filingURL(identity: identity, row: row)
            let details = [
                row.items.map { "项目 \($0)" },
                row.primaryDocDescription
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "；")
            let detailText = details.isEmpty ? "未提供结构化项目摘要" : details
            return TrendEvidence(
                id: "official:sec:filing:\(row.accessionNumber.lowercased())",
                sourceName: "U.S. SEC EDGAR",
                title: "\(identity.ticker) \(row.form) 官方申报",
                url: filingURL,
                publishedAt: row.acceptanceDateTime ?? row.filingDate,
                retrievedAt: retrievedAt,
                summary: "\(identity.name) 于 \(row.filingDate) 提交 \(row.form)，报告期 \(row.reportDate ?? "未注明")；\(detailText)。申报存在本身不代表利好或利空，方向判断需要结合正文、行情和独立事件证据。",
                metadata: TrendEvidenceMetadata(
                    sourceKind: .officialFiling,
                    sourceTier: .primary,
                    publisherKey: "sec.gov",
                    requestedTopicKeys: params.research_target.topicKeys,
                    entityCodes: [identity.ticker],
                    entityNames: [identity.name, params.research_target.key],
                    metadataConfidence: .deterministic
                )
            )
        }
        await context.evidenceLedger.record(evidence)

        let payload = zip(selected, evidence).map { row, item -> [String: Any] in
            [
                "evidence_id": item.id,
                "ticker": identity.ticker,
                "company": identity.name,
                "form": row.form,
                "filing_date": row.filingDate,
                "report_date": row.reportDate ?? NSNull(),
                "accepted_at": row.acceptanceDateTime ?? NSNull(),
                "items": row.items ?? NSNull(),
                "description": row.primaryDocDescription ?? NSNull(),
                "url": item.url ?? NSNull(),
                "is_xbrl": row.isXBRL,
                "is_inline_xbrl": row.isInlineXBRL,
                "interpretation_boundary": "官方申报事实；不得仅凭表单类型推断利好或利空"
            ]
        }
        let warnings = evidence.isEmpty
            ? ["SEC 查询成功，但所选时间和表单范围没有匹配申报。不得扩大解释为公司没有其它风险事件。"]
            : []
        return .content(
            TrendResearchToolEnvelope.success(
                [
                    "provider": "U.S. SEC EDGAR",
                    "mode": Mode.recentFilings.rawValue,
                    "ticker": identity.ticker,
                    "company": identity.name,
                    "cik": identity.paddedCIK,
                    "results": payload,
                    "count": payload.count,
                    "cache_hit": outcome.cacheHit
                ],
                warnings: warnings,
                evidenceIDs: evidence.map(\.id)
            )
        )
    }

    private func companyFactsResult(
        identity: CompanyIdentity,
        target: TrendResearchTarget,
        context: TrendResearchToolContext
    ) async throws -> TrendResearchToolResult {
        let url = URL(
            string: "https://data.sec.gov/api/xbrl/companyfacts/CIK\(identity.paddedCIK).json"
        )!
        let outcome = try await cache.fetch(
            SECRequestDescriptor(url: url, cacheTTL: 6 * 60 * 60),
            settings: context.officialSourceSettings,
            client: client
        )
        let metrics = try parseCompanyFacts(outcome.data)
        guard !metrics.isEmpty else {
            return .content(
                TrendResearchToolEnvelope.success(
                    [
                        "provider": "U.S. SEC EDGAR",
                        "mode": Mode.companyFacts.rawValue,
                        "ticker": identity.ticker,
                        "company": identity.name,
                        "results": [],
                        "count": 0,
                        "cache_hit": outcome.cacheHit
                    ],
                    warnings: ["SEC Company Facts 没有取得可比较的标准 US-GAAP 指标。不得据此认定公司没有相关财务数据。"]
                )
            )
        }

        let latestFiled = metrics.map(\.filed).max() ?? ""
        let evidenceID = "official:sec:facts:\(identity.paddedCIK):\(latestFiled)"
        let summaryItems = metrics.map {
            "\($0.label)=\(compactNumber($0.value)) \($0.unit)，截至 \($0.end)，\($0.form)"
        }
        let evidence = TrendEvidence(
            id: evidenceID,
            sourceName: "U.S. SEC XBRL Company Facts",
            title: "\(identity.ticker) 最新标准财务事实",
            url: url.absoluteString,
            publishedAt: latestFiled,
            retrievedAt: ISO8601DateFormatter().string(from: Date()),
            summary: "\(identity.name)：\(summaryItems.joined(separator: "；"))。不同指标可能对应季度、年度或时点口径，必须结合 form、start/end 和单位解释。",
            metadata: TrendEvidenceMetadata(
                sourceKind: .officialFinancial,
                sourceTier: .primary,
                publisherKey: "sec.gov",
                requestedTopicKeys: target.topicKeys,
                entityCodes: [identity.ticker],
                entityNames: [identity.name, target.key],
                metadataConfidence: .deterministic
            )
        )
        await context.evidenceLedger.record([evidence])

        let payload = metrics.map { metric -> [String: Any] in
            [
                "key": metric.key,
                "label": metric.label,
                "concept": metric.concept,
                "value": metric.value,
                "unit": metric.unit,
                "start": metric.start ?? NSNull(),
                "end": metric.end,
                "filed": metric.filed,
                "form": metric.form,
                "frame": metric.frame ?? NSNull()
            ]
        }
        return .content(
            TrendResearchToolEnvelope.success(
                [
                    "provider": "U.S. SEC EDGAR",
                    "mode": Mode.companyFacts.rawValue,
                    "ticker": identity.ticker,
                    "company": identity.name,
                    "cik": identity.paddedCIK,
                    "evidence_id": evidenceID,
                    "results": payload,
                    "count": payload.count,
                    "cache_hit": outcome.cacheHit,
                    "interpretation_boundary": "官方 XBRL 事实；不同 form 和期间口径不可直接混比"
                ],
                evidenceIDs: [evidenceID]
            )
        )
    }

    private func resolveCompany(
        ticker: String,
        settings: OfficialSourceSettings
    ) async throws -> CompanyIdentity {
        let url = URL(string: "https://www.sec.gov/files/company_tickers_exchange.json")!
        let outcome = try await cache.fetch(
            SECRequestDescriptor(url: url, cacheTTL: 24 * 60 * 60),
            settings: settings,
            client: client
        )
        guard let root = try JSONSerialization.jsonObject(with: outcome.data) as? [String: Any],
              let fields = root["fields"] as? [String],
              let rows = root["data"] as? [[Any]],
              let cikIndex = fields.firstIndex(of: "cik"),
              let nameIndex = fields.firstIndex(of: "name"),
              let tickerIndex = fields.firstIndex(of: "ticker") else {
            throw SECOfficialSourceClientError.invalidResponse("公司代码目录结构不完整")
        }
        let exchangeIndex = fields.firstIndex(of: "exchange")
        guard let row = rows.first(where: {
            guard $0.indices.contains(tickerIndex) else { return false }
            return normalizedTicker(string($0[tickerIndex])) == ticker
        }),
        row.indices.contains(cikIndex),
        row.indices.contains(nameIndex),
        let cik = integer(row[cikIndex]) else {
            throw SECOfficialSourceClientError.invalidResponse("SEC 公司目录未找到代码 \(ticker)")
        }
        return CompanyIdentity(
            cik: cik,
            ticker: ticker,
            name: string(row[nameIndex]),
            exchange: exchangeIndex.flatMap {
                row.indices.contains($0) ? string(row[$0]).nilIfEmpty : nil
            }
        )
    }

    private func parseRecentFilings(_ data: Data) throws -> [FilingRow] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let filings = root["filings"] as? [String: Any],
              let recent = filings["recent"] as? [String: Any],
              let accessions = recent["accessionNumber"] as? [Any] else {
            throw SECOfficialSourceClientError.invalidResponse("Submissions recent 结构不完整")
        }

        return accessions.indices.compactMap { index in
            let accession = value("accessionNumber", index: index, in: recent)
            let filingDate = value("filingDate", index: index, in: recent)
            let form = value("form", index: index, in: recent)
            let primaryDocument = value("primaryDocument", index: index, in: recent)
            guard !accession.isEmpty,
                  !filingDate.isEmpty,
                  !form.isEmpty,
                  !primaryDocument.isEmpty else {
                return nil
            }
            return FilingRow(
                accessionNumber: accession,
                filingDate: filingDate,
                reportDate: value("reportDate", index: index, in: recent).nilIfEmpty,
                acceptanceDateTime: value(
                    "acceptanceDateTime",
                    index: index,
                    in: recent
                ).nilIfEmpty,
                form: form,
                items: value("items", index: index, in: recent).nilIfEmpty,
                primaryDocument: primaryDocument,
                primaryDocDescription: value(
                    "primaryDocDescription",
                    index: index,
                    in: recent
                ).nilIfEmpty,
                isXBRL: value("isXBRL", index: index, in: recent) == "1",
                isInlineXBRL: value("isInlineXBRL", index: index, in: recent) == "1"
            )
        }
    }

    private func parseCompanyFacts(_ data: Data) throws -> [FinancialMetric] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let facts = root["facts"] as? [String: Any],
              let usGAAP = facts["us-gaap"] as? [String: Any] else {
            throw SECOfficialSourceClientError.invalidResponse("Company Facts 缺少 us-gaap")
        }

        let specs = [
            MetricSpec(
                key: "revenue",
                label: "营业收入",
                concepts: [
                    "RevenueFromContractWithCustomerExcludingAssessedTax",
                    "Revenues",
                    "SalesRevenueNet"
                ]
            ),
            MetricSpec(
                key: "netIncome",
                label: "净利润",
                concepts: ["NetIncomeLoss", "ProfitLoss"]
            ),
            MetricSpec(
                key: "assets",
                label: "总资产",
                concepts: ["Assets"]
            ),
            MetricSpec(
                key: "liabilities",
                label: "总负债",
                concepts: ["Liabilities"]
            ),
            MetricSpec(
                key: "operatingCashFlow",
                label: "经营现金流",
                concepts: ["NetCashProvidedByUsedInOperatingActivities"]
            )
        ]
        return specs.compactMap { spec in
            latestMetric(spec: spec, facts: usGAAP)
        }
    }

    private func latestMetric(
        spec: MetricSpec,
        facts: [String: Any]
    ) -> FinancialMetric? {
        for concept in spec.concepts {
            guard let fact = facts[concept] as? [String: Any],
                  let units = fact["units"] as? [String: Any] else {
                continue
            }
            let candidates = units.flatMap { unit, raw -> [FinancialMetric] in
                guard let rows = raw as? [[String: Any]] else { return [] }
                return rows.compactMap { row in
                    guard let value = number(row["val"]),
                          let end = string(row["end"]).nilIfEmpty,
                          let filed = string(row["filed"]).nilIfEmpty,
                          let form = string(row["form"]).nilIfEmpty,
                          ["10-Q", "10-K", "20-F", "40-F"].contains(form) else {
                        return nil
                    }
                    return FinancialMetric(
                        key: spec.key,
                        label: spec.label,
                        concept: concept,
                        value: value,
                        unit: unit,
                        start: string(row["start"]).nilIfEmpty,
                        end: end,
                        filed: filed,
                        form: form,
                        frame: string(row["frame"]).nilIfEmpty
                    )
                }
            }
            if let latest = candidates.max(by: {
                ($0.filed, $0.end) < ($1.filed, $1.end)
            }) {
                return latest
            }
        }
        return nil
    }

    private func filingURL(
        identity: CompanyIdentity,
        row: FilingRow
    ) -> String {
        let accession = row.accessionNumber.replacingOccurrences(of: "-", with: "")
        return "https://www.sec.gov/Archives/edgar/data/\(identity.cik)/\(accession)/\(row.primaryDocument)"
    }

    private func eligibleTickers(in snapshot: TrendResearchSnapshot) -> Set<String> {
        let direct = snapshot.assets.compactMap(\.code)
        let underlying = snapshot.lookThrough?.topPositions
            .filter { $0.kind == .stock }
            .map(\.code)
            ?? []
        return Set((direct + underlying).compactMap { raw in
            let value = normalizedTicker(raw)
            guard isLikelySECTicker(value) else { return nil }
            return value
        })
    }

    private func normalizedTicker(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: ".", with: "-")
    }

    private func isLikelySECTicker(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return !value.isEmpty
            && value.count <= 12
            && value.unicodeScalars.allSatisfy { allowed.contains($0) }
            && value.unicodeScalars.contains {
                CharacterSet.letters.contains($0)
            }
    }

    private func value(
        _ key: String,
        index: Int,
        in object: [String: Any]
    ) -> String {
        guard let values = object[key] as? [Any],
              values.indices.contains(index) else {
            return ""
        }
        return string(values[index])
    }

    private func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private func compactNumber(_ value: Double) -> String {
        if abs(value) >= 1_000_000_000 {
            return String(format: "%.2fB", value / 1_000_000_000)
        }
        if abs(value) >= 1_000_000 {
            return String(format: "%.2fM", value / 1_000_000)
        }
        return String(format: "%.2f", value)
    }

    private func failure(code: String, message: String) -> TrendResearchToolResult {
        .content(
            TrendResearchToolEnvelope.error(code: code, message: message),
            isError: true
        )
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

extension TrendResearchSnapshot {
    var eligibleSECResearchTickers: [String] {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"
        )
        let direct = assets.compactMap(\.code)
        let underlying = lookThrough?.topPositions
            .filter { $0.kind == .stock }
            .map(\.code)
            ?? []
        return Array(
            Set((direct + underlying).compactMap { raw -> String? in
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased()
                    .replacingOccurrences(of: ".", with: "-")
                guard !value.isEmpty,
                      value.count <= 12,
                      value.unicodeScalars.allSatisfy({ allowed.contains($0) }),
                      value.unicodeScalars.contains(where: {
                          CharacterSet.letters.contains($0)
                      }) else {
                    return nil
                }
                return value
            })
        ).sorted()
    }
}

