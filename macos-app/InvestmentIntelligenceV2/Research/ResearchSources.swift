import Foundation

// MARK: - Research 外部源配置 + 本地数据访问（RES-3）
//
// V2 工具的数据面分两类，配置与注入都在这里定义：
// - **外部源**（Tavily / SEC EDGAR / Alpha Vantage）：复用 Core/Clients 的
//   传输与缓存（FREE001 不重复造轮子），配置以 V2 值类型持有，桥接函数
//   转换为 Core settings——B.3 封装切断依赖，V2 之外不出现 Core 类型。
// - **本地 Canonical 取数**：ResearchDataAccess 只暴露白名单查询
//   （fund NAV / 日线序列），LLM 与 Workflow 无法拿到 Repository 全量引用
//   ——「LLM 通过工具访问外部世界，不直接读 Repository」（rollout RES-3
//   验收）。
//
// 所有查询的 KnowledgeContext 由工具内部按 economicKnowledge(now) 构造，
// 调用方（模型）不能选择 PIT 语境——研究永远用「当时已知」口径。

/// V2 Research 外部源配置（apiKey 只进桥接层，不进 trace / evidence / 日志）。
struct ResearchSourcesConfiguration: Sendable, Hashable, Codable {
    var tavilyAPIKey: String = ""
    var secContactEmail: String = ""
    var secEnabled: Bool = false
    var alphaVantageEnabled: Bool = false
    var alphaVantageAPIKey: String = ""
    var alphaVantageDailyRequestLimit: Int = AlphaVantageSettings.freeDailyRequestLimit

    static let empty = ResearchSourcesConfiguration()

    var isWebSearchConfigured: Bool {
        !tavilyAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isSECConfigured: Bool {
        officialSourceSettings.isSECConfigured
    }

    var isAlphaVantageConfigured: Bool {
        alphaVantageSettings.isConfigured
    }
}

/// 桥接层：V2 配置 → Core settings（唯一出现 Core 类型的地方）。
extension ResearchSourcesConfiguration {
    var tavilySettings: TavilySearchSettings {
        TavilySearchSettings(apiKey: tavilyAPIKey)
    }

    var officialSourceSettings: OfficialSourceSettings {
        OfficialSourceSettings(enabled: secEnabled, secContactEmail: secContactEmail)
    }

    var alphaVantageSettings: AlphaVantageSettings {
        AlphaVantageSettings(
            enabled: alphaVantageEnabled,
            apiKey: alphaVantageAPIKey,
            dailyRequestLimit: alphaVantageDailyRequestLimit
        )
    }
}

/// 本地 Canonical 取数的白名单（Research 工具的数据面；App 装配时由
/// Repository 适配实现，测试用 InMemory / fake）。
protocol ResearchDataAccess: Sendable {
    /// 基金份额类别的 NAV 序列（economicKnowledge(asOf) 口径）。
    func navObservations(shareClassID: FundShareClassID, asOf: Date) -> [NAVObservation]
    /// Listing 日线序列（economicKnowledge(asOf) 口径）。
    func dailyBars(listingID: ListingID, asOf: Date) -> [DailyBar]
}

/// Repository → ResearchDataAccess 适配（GRDB / InMemory 通用）。
struct RepositoryResearchDataAccess: ResearchDataAccess {
    private let nav: any NAVTimeSeriesRepository
    private let market: any MarketTimeSeriesRepository

    init(
        nav: any NAVTimeSeriesRepository,
        market: any MarketTimeSeriesRepository
    ) {
        self.nav = nav
        self.market = market
    }

    func navObservations(shareClassID: FundShareClassID, asOf: Date) -> [NAVObservation] {
        nav.navObservations(shareClassID: shareClassID, context: .economicKnowledge(asOf: asOf))
    }

    func dailyBars(listingID: ListingID, asOf: Date) -> [DailyBar] {
        market.dailyBars(listingID: listingID, context: .economicKnowledge(asOf: asOf))
    }
}
