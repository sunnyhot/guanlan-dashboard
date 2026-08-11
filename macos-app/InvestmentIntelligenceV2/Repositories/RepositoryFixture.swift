import Foundation

// MARK: - RepositoryFixture（REPO-3，JSON Fixture loader）
//
// 加载真实样本 JSON 到 InMemoryRepository，用于：
// - M2 验收（5 场景需要真实形态的数据）
// - Factor / Risk / Attribution 单测注入固定数据
// - Provider staging 的离线回放（不调真实 Provider）
//
// Fixture 文件放 Tests/QiemanDashboardTests/Fixtures/V2/*.json，
// 由 SPM `.copy("Fixtures")` resource 自动打包（见 Package.swift）。

/// 一个完整的 Repository fixture：identity + observations。
struct RepositoryFixture: Codable {
    let instruments: [Instrument]?
    let listings: [Listing]?
    let legalEntities: [LegalEntity]?
    let fundProducts: [FundProduct]?
    let fundShareClasses: [FundShareClass]?
    let providerIdentifiers: [ProviderIdentifier]?
    let relationships: [RelationshipEntry]?
    let dailyBars: [DailyBar]?
    let navObservations: [NAVObservation]?
    let holdingSnapshots: [FundHoldingSnapshot]?
    let macroObservations: [MacroObservation]?
    let corporateActions: [CorporateAction]?

    /// InstrumentRelationship 的 Codable 包装。
    /// 因 InstrumentRelationship 是 enum with associated values，直接放进数组
    /// Codable 会带 "tracksIndex"/"shareClassOf" 等 case key。这里用显式 entry
    /// 让 fixture JSON 更可读。
    enum RelationshipEntry: Codable {
        case tracksIndex(InstrumentRelationship.TracksIndex)
        case shareClassOf(InstrumentRelationship.ShareClassOf)
        case issuedBy(InstrumentRelationship.IssuedBy)
        case adrUnderlying(InstrumentRelationship.ADRUnderlying)

        var asRelationship: InstrumentRelationship {
            switch self {
            case .tracksIndex(let r): return .tracksIndex(r)
            case .shareClassOf(let r): return .shareClassOf(r)
            case .issuedBy(let r): return .issuedBy(r)
            case .adrUnderlying(let r): return .adrUnderlying(r)
            }
        }
    }
}

// MARK: - InMemoryRepository 扩展：从 fixture 加载

extension InMemoryRepository {
    /// 从 RepositoryFixture 加载所有实体到本 repo（追加，不清空已有数据）。
    @discardableResult
    func load(_ fixture: RepositoryFixture) -> Self {
        fixture.instruments?.forEach { upsert($0) }
        fixture.listings?.forEach { upsert($0) }
        fixture.legalEntities?.forEach { upsert($0) }
        fixture.fundProducts?.forEach { upsert($0) }
        fixture.fundShareClasses?.forEach { upsert($0) }
        fixture.providerIdentifiers?.forEach { upsert($0) }
        fixture.relationships?.forEach { add($0.asRelationship) }
        fixture.dailyBars?.forEach { upsert($0) }
        fixture.navObservations?.forEach { upsert($0) }
        fixture.holdingSnapshots?.forEach { upsert($0) }
        fixture.macroObservations?.forEach { upsert($0) }
        fixture.corporateActions?.forEach { upsert($0) }
        return self
    }

    /// 从 JSON Data 加载 fixture。
    convenience init(fixtureData: Data, calendarBackend: TradingCalendar) throws {
        self.init(calendarBackend: calendarBackend)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let fixture = try decoder.decode(RepositoryFixture.self, from: fixtureData)
        load(fixture)
    }

    /// 从 Tests bundle 的 Fixtures/V2/<name>.json 加载（测试用便捷入口）。
    /// 调用方应传入测试类（XCTestCase 子类）以正确定位 test bundle。
    /// 从 Tests bundle 的 Fixtures/<name>.json 加载（测试用便捷入口）。
    /// 调用方传 `Bundle.module`（SPM test target 的 resource bundle）。
    static func loadFromTestsBundle(
        name: String,
        calendarBackend: TradingCalendar,
        bundle: Bundle
    ) throws -> InMemoryRepository {
        // SPM `.copy("Fixtures")` 把 Fixtures 目录原样复制为子目录
        guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "json")
        else {
            throw FixtureError.notFound(name: name)
        }
        let data = try Data(contentsOf: url)
        return try InMemoryRepository(fixtureData: data, calendarBackend: calendarBackend)
    }
}

enum FixtureError: Error, Equatable {
    case notFound(name: String)
}
