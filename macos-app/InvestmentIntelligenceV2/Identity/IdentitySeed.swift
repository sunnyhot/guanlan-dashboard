import Foundation

// MARK: - IdentitySeed（REPO-4b，初始 Identity 映射数据）
//
// rollout REPO-4b：手工 verified 基础集（当前未归档持仓）+ 映射数据 fixture。
//
// 非持仓标的的 identity 增量建立由 SYNC-8（Identity Sync）处理，本文件只管
// 「持仓内标的」的初始 verified 映射——这是 M2 验收场景 1/2 的物质基础。

/// 持仓内标的的初始 Identity 映射 seed。
///
/// 设计为「手动 verified」基础集（resolutionMethod = .manualVerified）。
/// 当前 portfolio seed 版本与覆盖范围记录在 rollout 文档中；fixture 只包含
/// 持仓内标的，真实生产数据由 IdentitySync（SYNC-8）从 Provider hints 增量扩展。
struct IdentitySeed: Sendable {
    /// 所有 verified ProviderIdentifier（跨 Provider → 同一 Canonical）。
    let providerIdentifiers: [ProviderIdentifier]
    /// 基础 Canonical 实体（Instrument/Listing/FundProduct/FundShareClass/LegalEntity）。
    let instruments: [Instrument]
    let listings: [Listing]
    let legalEntities: [LegalEntity]
    let fundProducts: [FundProduct]
    let fundShareClasses: [FundShareClass]

    init(
        providerIdentifiers: [ProviderIdentifier],
        instruments: [Instrument],
        listings: [Listing],
        legalEntities: [LegalEntity],
        fundProducts: [FundProduct],
        fundShareClasses: [FundShareClass]
    ) {
        self.providerIdentifiers = providerIdentifiers
        self.instruments = instruments
        self.listings = listings
        self.legalEntities = legalEntities
        self.fundProducts = fundProducts
        self.fundShareClasses = fundShareClasses
    }

    /// 从 fixture JSON 加载（与 RepositoryFixture 共用格式）。
    static func load(name: String, bundle: Bundle) throws -> IdentitySeed {
        guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "json")
        else {
            throw FixtureError.notFound(name: name)
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let fixture = try decoder.decode(RepositoryFixture.self, from: data)
        return IdentitySeed(
            providerIdentifiers: fixture.providerIdentifiers ?? [],
            instruments: fixture.instruments ?? [],
            listings: fixture.listings ?? [],
            legalEntities: fixture.legalEntities ?? [],
            fundProducts: fixture.fundProducts ?? [],
            fundShareClasses: fixture.fundShareClasses ?? []
        )
    }
}

// MARK: - InMemoryRepository 扩展：从 seed 加载 identity

extension InMemoryRepository {
    /// 加载 IdentitySeed 到本 repo（追加 identity + provider identifiers）。
    @discardableResult
    func loadIdentitySeed(_ seed: IdentitySeed) -> Self {
        seed.instruments.forEach { upsert($0) }
        seed.listings.forEach { upsert($0) }
        seed.legalEntities.forEach { upsert($0) }
        seed.fundProducts.forEach { upsert($0) }
        seed.fundShareClasses.forEach { upsert($0) }
        seed.providerIdentifiers.forEach { upsert($0) }
        return self
    }
}
