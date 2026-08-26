import Foundation

// MARK: - V2 本地 Canonical 取数工具（RES-3：封装 Provider 取数为 Research Tool）
//
// LLM 访问本地数据的唯一通道：白名单查询（fund NAV / 日线序列），
// KnowledgeContext 固定 economicKnowledge(now)——模型不能选择 PIT 语境。
// 「不直接读 Repository」（rollout RES-3 验收）：工具只经 ResearchDataAccess
// 白名单，dataAccess 未注入时本工具返回不可用信封。

struct V2LocalDataTool: ResearchTool {
    let name = "get_local_data"
    let description = "查询本地 Canonical 数据：基金净值序列或标的日线序列（最近 N 条）。"
    let parameters: ModelJSONValue = [
        "type": "object",
        "properties": [
            "dataset": ["type": "string", "enum": ["fund_nav", "daily_bars"],
                        "description": "基金净值 / 标的日线。"],
            "subject_id": ["type": "string",
                           "description": "fund_nav 用 FundShareClassID；daily_bars 用 ListingID（含前缀，如 list_xxx）。"],
            "days": ["type": "integer", "description": "可选 1-500，默认 60（取最近 N 条）。"]
        ],
        "required": ["dataset", "subject_id"]
    ]

    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    private struct Params: Decodable {
        let dataset: String
        let subject_id: String
        let days: Int?
    }

    func execute(argumentsJSON: String, context: ResearchToolContext) async -> ResearchToolResult {
        guard let params = Self.decodeParams(Params.self, argumentsJSON),
              ["fund_nav", "daily_bars"].contains(params.dataset) else {
            return .content(Self.invalidArguments, isError: true)
        }
        let days = params.days ?? 60
        guard (1...500).contains(days) else {
            return .content(Self.invalidArguments, isError: true)
        }
        let subjectID = params.subject_id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subjectID.isEmpty else {
            return .content(Self.invalidArguments, isError: true)
        }
        guard let dataAccess = context.dataAccess else {
            return .errorEnvelope(code: "local_data_unavailable", message: "本次运行未接入本地数据。")
        }
        let asOf = now()

        switch params.dataset {
        case "fund_nav":
            return Self.seriesResult(
                dataset: "fund_nav", subjectID: subjectID, days: days,
                observations: dataAccess.navObservations(
                    shareClassID: FundShareClassID(rawValue: subjectID), asOf: asOf
                ),
                emptyMessage: "该 FundShareClass 无本地净值数据。",
                value: { ($0.temporalEnvelope.effectiveAt, Double(truncating: $0.unitNAV.value as NSDecimalNumber)) },
                valueLabel: "nav_per_unit", boundary: "本地 Canonical NAV（economicKnowledge 口径）"
            )
        default:
            return Self.seriesResult(
                dataset: "daily_bars", subjectID: subjectID, days: days,
                observations: dataAccess.dailyBars(listingID: ListingID(rawValue: subjectID), asOf: asOf),
                emptyMessage: "该 Listing 无本地日线数据。",
                value: { ($0.temporalEnvelope.effectiveAt, Double(truncating: $0.rawClose.value as NSDecimalNumber)) },
                valueLabel: "close", boundary: "本地 Canonical 日线（economicKnowledge 口径）"
            )
        }
    }

    /// 序列查询的统一组装：排序取尾 → rows → 内容寻址 evidence → 信封。
    /// （两个 dataset 的差异只在取数调用与 value 提取，结构完全同构。）
    private static func seriesResult<Obs>(
        dataset: String,
        subjectID: String,
        days: Int,
        observations: [Obs],
        emptyMessage: String,
        value: (Obs) -> (date: Date, value: Double),
        valueLabel: String,
        boundary: String
    ) -> ResearchToolResult {
        guard !observations.isEmpty else {
            return .errorEnvelope(code: "local_data_empty", message: emptyMessage)
        }
        let rows: [ModelJSONValue] = observations
            .map(value)
            .sorted { $0.date > $1.date }
            .prefix(days)
            .map { point in
                [
                    "date": .string(dayString(point.date)),
                    "value": .number(point.value)
                ]
            }
        // 内容寻址 digest 用规范 JSON 编码（字符串插值依赖 debugDescription，
        // 跨 Swift 版本可能漂移——审查 P3-6）
        let firstJSON = rows.first.flatMap { Self.stableJSON($0) } ?? "null"
        let lastJSON = rows.last.flatMap { Self.stableJSON($0) } ?? "null"
        let digest = StableDigest.digest(
            "\(dataset)|\(subjectID)|\(rows.count)|\(firstJSON)|\(lastJSON)"
        )
        let evidenceID = EvidenceID(rawValue: "local:\(dataset):\(digest.prefix(16))")
        let data: ModelJSONValue = [
            "dataset": .string(dataset),
            "subject_id": .string(subjectID),
            "series": .array(rows),
            "value_label": .string(valueLabel),
            "count": .number(Double(rows.count)),
            "evidence_boundary": .string(boundary)
        ]
        // 来源时间 = 序列最新观测的 effectiveAt（数据描述的最后事件时刻；
        // 抓取时刻只进 ingestedAt——Freshness 按来源时间判定）。
        let latestSourceDate = observations.map(value).map(\.date).max()
        return .content(
            ResearchToolEnvelope.success(data, evidenceIDs: [evidenceID]),
            evidenceIDs: [evidenceID],
            sourceDates: [evidenceID.rawValue: latestSourceDate].compactMapValues { $0 }
        )
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static func dayString(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// ModelJSONValue 的稳定 JSON 串（编码失败返回 nil，digest 退化为 null）。
    private static func stableJSON(_ value: ModelJSONValue) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Research Tool Registry（RES-3 装配）

/// V2 工具注册表：构造期静态装配（外部三件套 + 本地取数），按 name 执行。
/// 对照旧 TrendResearchToolRegistry 的装配模式，但工具协议 / Context /
/// evidence 语义全部是 V2 形态（rollout：不复用旧 Registry）。
struct ResearchToolRegistry: Sendable {
    let tools: [any ResearchTool]

    init(
        webSearchClient: (any TavilySearchClientProtocol)? = TavilySearchClient(),
        secClient: (any SECOfficialSourceClientProtocol)? = SECOfficialSourceClient(),
        secCache: SECOfficialSourceCache = .shared,
        alphaVantageClient: (any AlphaVantageClientProtocol)? = AlphaVantageClient(),
        alphaVantageCache: AlphaVantageResponseCache = .shared,
        localDataNow: @escaping @Sendable () -> Date = { Date() }
    ) {
        var assembled: [any ResearchTool] = []
        if let webSearchClient {
            assembled.append(V2WebSearchTool(client: webSearchClient))
        }
        if let secClient {
            assembled.append(V2SECOfficialTool(client: secClient, cache: secCache))
        }
        if let alphaVantageClient {
            assembled.append(V2AlphaVantageTool(client: alphaVantageClient, cache: alphaVantageCache))
        }
        assembled.append(V2LocalDataTool(now: localDataNow))
        self.tools = assembled
    }

    /// 发给模型的工具声明。
    var definitions: [ModelToolSpec] {
        tools.map { ModelToolSpec(name: $0.name, description: $0.description, parameters: $0.parameters) }
    }

    /// 按名执行（未知工具回错误信封，由 Harness 回灌）。
    func tool(named name: String) -> (any ResearchTool)? {
        tools.first { $0.name == name }
    }
}
