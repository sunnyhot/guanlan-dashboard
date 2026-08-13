import XCTest
@testable import QiemanDashboard

/// REPO-3 + REPO-4 单元测试：JSON Fixture loader + IdentityResolver。
///
/// 重点验证：
/// - REPO-3：fixture 加载到 InMemoryRepository，identity + observations 可查
/// - REPO-4：4 正式路径 resolve、fuzzy 只产 candidate、verification 升级
final class FixtureAndIdentityResolverTests: XCTestCase {

    private struct WeekdayCalendar: TradingCalendar {
        func isTradingDay(_ date: Date, jurisdiction: Jurisdiction) -> Bool {
            let w = Calendar(identifier: .gregorian).component(.weekday, from: date)
            return w >= 2 && w <= 6
        }
        func tradingDay(after date: Date, offset: Int, jurisdiction: Jurisdiction) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            var current = date; var remaining = max(offset, 0); var safety = 0
            while remaining > 0 && safety < 14 {
                current = cal.date(byAdding: .day, value: 1, to: current)!
                if isTradingDay(current, jurisdiction: jurisdiction) { remaining -= 1 }
                safety += 1
            }
            return current
        }
        func tradingDayStart(_ date: Date, jurisdiction: Jurisdiction) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            return cal.startOfDay(for: date)
        }
    }

    // MARK: - REPO-3：Fixture loader

    func testFixtureLoader_loadsIdentityFromJSON() throws {
        // 从 Tests bundle 加载 identity-cross-provider.json
        let repo = try InMemoryRepository.loadFromTestsBundle(
            name: "v2-identity-cross-provider",
            calendarBackend: WeekdayCalendar(),
            bundle: Bundle.module
        )
        // 验证 Instrument / Listing / LegalEntity / FundProduct / FundShareClass 都加载了
        XCTAssertNotNil(repo.instrument(InstrumentID(rawValue: "inst_600519")))
        XCTAssertNotNil(repo.instrument(InstrumentID(rawValue: "inst_110022")))
        XCTAssertNotNil(repo.listing(ListingID(rawValue: "list_sh600519")))
        XCTAssertNotNil(repo.legalEntity(LegalEntityID(rawValue: "ent_efund")))
        XCTAssertNotNil(repo.fundProduct(FundProductID(rawValue: "prod_110022")))
        XCTAssertNotNil(repo.fundShareClass(FundShareClassID(rawValue: "sc_110022_A")))
    }

    func testFixtureLoader_loadsProviderIdentifiers() throws {
        let repo = try InMemoryRepository.loadFromTestsBundle(
            name: "v2-identity-cross-provider",
            calendarBackend: WeekdayCalendar(),
            bundle: Bundle.module
        )
        // 基金映射到 FundShareClass（基金 NAV 数据源唯一为天天基金，无跨 Provider 场景；
        // 原 qieman/prodCode 映射随 REPO-6 移除）
        let eastmoney = repo.resolve(providerID: .eastmoney, scheme: "fund_code", value: "110022")
        XCTAssertEqual(eastmoney, .fundShareClass(FundShareClassID(rawValue: "sc_110022_A")))
        // 跨 Provider 映射到同一 Listing（股票：天天基金 + Stooq）
        let emStock = repo.resolve(providerID: .eastmoney, scheme: "stock_symbol", value: "600519")
        let stooq = repo.resolve(providerID: .stooq, scheme: "stock_symbol", value: "600519.SS")
        XCTAssertEqual(emStock, .listing(ListingID(rawValue: "list_sh600519")))
        XCTAssertEqual(stooq, .listing(ListingID(rawValue: "list_sh600519")))
    }

    // MARK: - REPO-4：IdentityResolver 四路径 + fuzzy + verification

    func testIdentityResolver_resolvedViaManualVerified() throws {
        let repo = try InMemoryRepository.loadFromTestsBundle(
            name: "v2-identity-cross-provider",
            calendarBackend: WeekdayCalendar(),
            bundle: Bundle.module
        )
        let resolver = IdentityResolver.from(repo.allProviderIdentifiers())

        let result = resolver.resolve(providerID: .eastmoney, scheme: "fund_code", value: "110022")
        if case .resolved(let ref, let method) = result {
            XCTAssertEqual(ref, .fundShareClass(FundShareClassID(rawValue: "sc_110022_A")))
            XCTAssertEqual(method, .manualVerified)
        } else {
            XCTFail("expected .resolved, got \(result)")
        }
    }

    func testIdentityResolver_resolvedViaExchangeSymbolExact() throws {
        let repo = try InMemoryRepository.loadFromTestsBundle(
            name: "v2-identity-cross-provider",
            calendarBackend: WeekdayCalendar(),
            bundle: Bundle.module
        )
        let resolver = IdentityResolver.from(repo.allProviderIdentifiers())

        let result = resolver.resolve(providerID: .stooq, scheme: "stock_symbol", value: "600519.SS")
        if case .resolved(_, let method) = result {
            XCTAssertEqual(method, .exchangeSymbolExact)
        } else {
            XCTFail("expected .resolved, got \(result)")
        }
    }

    func testIdentityResolver_unresolvedForUnknownCode() throws {
        let repo = try InMemoryRepository.loadFromTestsBundle(
            name: "v2-identity-cross-provider",
            calendarBackend: WeekdayCalendar(),
            bundle: Bundle.module
        )
        let resolver = IdentityResolver.from(repo.allProviderIdentifiers())

        let result = resolver.resolve(providerID: .eastmoney, scheme: "fund_code", value: "999999")
        XCTAssertEqual(result, .unresolved)
    }

    func testIdentityResolver_fuzzyReturnsCandidatesNotResolved() {
        // fuzzy candidate 登记后，resolve 返回 .candidates 而非 .resolved
        // （ADR-DATA001 §Decision 3：fuzzy 不直接写 canonical）
        let fuzzyPID = ProviderIdentifier(
            providerID: .akshare,
            identifierScheme: "name_match",
            identifierValue: "茅台",
            canonical: .listing(ListingID(rawValue: "list_sh600519")),
            resolutionMethod: .fuzzyCandidate,
            resolvedAt: Date()
        )
        let resolver = IdentityResolver.from([fuzzyPID])

        let result = resolver.resolve(providerID: .akshare, scheme: "name_match", value: "茅台")
        if case .candidates(let candidates) = result {
            XCTAssertEqual(candidates.count, 1)
            XCTAssertEqual(candidates.first?.candidate, .listing(ListingID(rawValue: "list_sh600519")))
            XCTAssertLessThan(candidates.first!.confidence, 1.0)   // fuzzy 置信度 < 1
        } else {
            XCTFail("expected .candidates for fuzzy, got \(result)")
        }
    }

    func testVerification_acceptUpgradesToManualVerified() {
        // fuzzy candidate 经 Verification.accept 升级为 manualVerified 映射
        let candidate = IdentityCandidate(
            providerID: .akshare,
            identifierScheme: "name_match",
            identifierValue: "茅台",
            candidate: .listing(ListingID(rawValue: "list_sh600519")),
            confidence: 0.92,
            rationale: "名称相似度 0.92"
        )
        let upgraded = IdentityResolver.applyVerification(to: candidate, decision: .accept)
        XCTAssertEqual(upgraded?.resolutionMethod, .manualVerified)
        XCTAssertEqual(upgraded?.canonical, .listing(ListingID(rawValue: "list_sh600519")))
    }

    func testVerification_rejectProducesNil() {
        // reject 不写入 canonical master
        let candidate = IdentityCandidate(
            providerID: .akshare,
            identifierScheme: "name_match",
            identifierValue: "茅台啤酒",   // 不同的东西
            candidate: .listing(ListingID(rawValue: "list_sh600519")),
            confidence: 0.5,
            rationale: "名称含「茅台」但实际是啤酒公司"
        )
        let upgraded = IdentityResolver.applyVerification(to: candidate, decision: .reject)
        XCTAssertNil(upgraded)   // reject → 不写入
    }

    func testVerification_inconclusiveProducesNil() {
        let candidate = IdentityCandidate(
            providerID: .akshare,
            identifierScheme: "name_match",
            identifierValue: "茅台",
            candidate: .listing(ListingID(rawValue: "list_sh600519")),
            confidence: 0.5,
            rationale: "数据不足"
        )
        let upgraded = IdentityResolver.applyVerification(to: candidate, decision: .inconclusive)
        XCTAssertNil(upgraded)   // inconclusive → 不写入
    }

    // MARK: - 跨 Provider 同一 Canonical（股票场景；基金跨 Provider 已随 REPO-6 移除）

    func testM2Scenario2_twoProvidersSameListing() throws {
        let repo = try InMemoryRepository.loadFromTestsBundle(
            name: "v2-identity-cross-provider",
            calendarBackend: WeekdayCalendar(),
            bundle: Bundle.module
        )
        let resolver = IdentityResolver.from(repo.allProviderIdentifiers())

        // 同一股票在 eastmoney 和 stooq symbol 不同
        let em = resolver.resolve(providerID: .eastmoney, scheme: "stock_symbol", value: "600519")
        let sq = resolver.resolve(providerID: .stooq, scheme: "stock_symbol", value: "600519.SS")

        guard case .resolved(let emRef, _) = em, case .resolved(let sqRef, _) = sq else {
            XCTFail("both should resolve"); return
        }
        XCTAssertEqual(emRef, sqRef)
        XCTAssertEqual(emRef, .listing(ListingID(rawValue: "list_sh600519")))
    }
}
