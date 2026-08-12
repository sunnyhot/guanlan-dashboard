import XCTest
@testable import QiemanDashboard

/// REPO-1 单元测试：Repository 协议族的契约定义。
///
/// 协议本身的行为测试在 REPO-2（InMemoryRepository）里做。这里主要验证：
/// - 八个子协议存在且方法签名强制 KnowledgeContext（编译期契约）
/// - Repository 聚合协议正确组合所有子协议
/// - 出参类型都是 Canonical（无 Provider 原始代码泄漏）
final class RepositoryContractTests: XCTestCase {

    // MARK: - 子协议存在性（编译期检查：这些协议类型可被引用）

    func testRepositorySubProtocols_exist() {
        // 七个子协议都存在（Fundamental 域推迟到 REPO-1b，审查 P2 2026-08-12）。
        // 用元类型断言验证协议可被引用。
        let protos: [Any] = [
            InstrumentRepository.self,
            MarketTimeSeriesRepository.self,
            NAVTimeSeriesRepository.self,
            FundHoldingRepository.self,
            MacroRepository.self,
            CorporateActionRepository.self,
            CalendarRepository.self,
            Repository.self,   // 聚合协议（七域）
        ]
        XCTAssertEqual(protos.count, 8)
        // 每个元素都是非空（协议类型引用成功）
        protos.forEach { XCTAssertNotNil($0) }
    }

    // MARK: - KnowledgeContext 强制入参契约
    //
    // 这是一个编译期契约：以下 mock 实现必须带 KnowledgeContext 才能满足协议。
    // 如果协议签名改掉（去掉 context 参数），这段代码会编译失败——
    // 正是我们要的「强制」效果。

    /// 最小 mock，验证「协议方法签名强制 KnowledgeContext」。
    /// 若未来有人改协议去掉 context 参数，这里的实现会不再符合协议（编译失败）。
    private struct KnowledgeContextEnforcingMock: MarketTimeSeriesRepository {
        func dailyBars(listingID: ListingID, context: KnowledgeContext) -> [DailyBar] {
            // 协议强制 context 入参，不能省略
            _ = context
            return []
        }
        func dailyBar(listingID: ListingID, on day: Date, context: KnowledgeContext) -> DailyBar? {
            _ = context; _ = day
            return nil
        }
    }

    func testMarketTimeSeriesRepo_requiresKnowledgeContext() {
        let mock = KnowledgeContextEnforcingMock()
        // 能调用就证明 context 是强制入参（编译期契约）
        let result = mock.dailyBars(
            listingID: ListingID(rawValue: "list_x"),
            context: .economicKnowledge(asOf: Date())
        )
        XCTAssertEqual(result.count, 0)
    }

    // MARK: - 出参类型是 Canonical（无 Provider 原始代码）
    //
    // 检查协议返回类型都是 Canonical 类型（Instrument/Listing/DailyBar/...），
    // 不含 Provider 原始代码类型（如 String 代码）。这是编译期保证——
    // 协议方法签名决定了出参类型。

    private struct CanonicalOutputMock: InstrumentRepository {
        func instrument(_ id: InstrumentID) -> Instrument? { nil }
        func listing(_ id: ListingID) -> Listing? { nil }
        func listings(forInstrument id: InstrumentID) -> [Listing] { [] }
        func legalEntity(_ id: LegalEntityID) -> LegalEntity? { nil }
        func fundProduct(_ id: FundProductID) -> FundProduct? { nil }
        func fundShareClass(_ id: FundShareClassID) -> FundShareClass? { nil }
        func resolve(providerID: DataProviderID, scheme: String, value: String) -> CanonicalRef? { nil }
        func relationships(for instrument: InstrumentID) -> [InstrumentRelationship] { [] }
    }

    func testInstrumentRepo_returnsCanonicalTypes() {
        let mock = CanonicalOutputMock()
        // 所有返回值都是 Canonical 类型（Instrument/Listing/...）
        // 不存在 Provider 原始代码（String symbol）作为返回类型
        XCTAssertNil(mock.instrument(InstrumentID(rawValue: "inst_x")))
        XCTAssertNil(mock.listing(ListingID(rawValue: "list_x")))
        XCTAssertEqual(mock.listings(forInstrument: InstrumentID(rawValue: "inst_x")).count, 0)
        XCTAssertNil(mock.legalEntity(LegalEntityID(rawValue: "ent_x")))
        XCTAssertNil(mock.fundProduct(FundProductID(rawValue: "prod_x")))
        XCTAssertNil(mock.fundShareClass(FundShareClassID(rawValue: "sc_x")))
        XCTAssertNil(mock.resolve(providerID: .qieman, scheme: "prodCode", value: "X"))
        XCTAssertEqual(mock.relationships(for: InstrumentID(rawValue: "inst_x")).count, 0)
    }

    // MARK: - resolve 是 IdentityResolver 的便捷入口

    func testResolve_returnsCanonicalRef_notRawString() {
        // resolve 返回 CanonicalRef（带类型），不是裸 String 代码
        // 这是防火墙 1 的运行时入口：Provider 代码 → Canonical
        let mock = CanonicalOutputMock()
        let ref = mock.resolve(providerID: .eastmoney, scheme: "fund_code", value: "110022")
        XCTAssertNil(ref)   // mock 未配置映射
        // 真实 InMemoryRepository 会返回 .fundShareClass(...) 等
    }
}
