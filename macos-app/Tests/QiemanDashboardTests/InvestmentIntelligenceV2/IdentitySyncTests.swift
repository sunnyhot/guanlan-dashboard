import XCTest
@testable import QiemanDashboard

/// SYNC-8 单元测试：IdentitySync 建立算法——4 条正式路径各有测试 +
/// 创建模式 + fuzzy 候选 + Verification + 冲突不覆盖 + 幂等。
final class IdentitySyncTests: XCTestCase {

    private var repository: GRDBRepository!
    private var sync: IdentitySync!

    override func setUpWithError() throws {
        repository = GRDBRepository(
            database: try CanonicalDatabase(),
            calendarBackend: HolidayTableTradingCalendar.bundled
        )
        try seedMaster()
        sync = IdentitySync(repository: repository, now: { Self.fixedNow })
    }

    private static let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func cst(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: - 路径 1：providerAuthoritative（官方 cross-ref 继承）

    func testPath1_providerAuthoritativeInheritsCrossRef() throws {
        // 新代码 600519_ALIAS 尚未登记；Provider 声明其官方等价是已登记的
        // 600519（同标的另一展示码的形态）——继承其 canonical
        let hint = IdentityHint(
            providerID: .eastmoney,
            code: ProviderCode(scheme: "stock_symbol", value: "600519_ALIAS"),
            authoritativeCrossRefs: [ProviderCode(scheme: "stock_symbol", value: "600519")]
        )
        let outcomes = try sync.establish(hints: [hint])
        guard case let .established(method, canonical, created) = outcomes["eastmoney|stock_symbol|600519_ALIAS"] else {
            return XCTFail("期望 established，实际 \(String(describing: outcomes))")
        }
        XCTAssertEqual(method, .providerAuthoritative)
        XCTAssertEqual(canonical, .listing(ListingID(rawValue: "lst_600519")))
        XCTAssertFalse(created)
        XCTAssertEqual(
            repository.resolve(providerID: .eastmoney, scheme: "stock_symbol", value: "600519_ALIAS"),
            .listing(ListingID(rawValue: "lst_600519")),
            "登记后 lookup 可解析"
        )
    }

    // MARK: - 路径 2：exchangeSymbolExact

    func testPath2_exchangeSymbolExactMatchesExistingListing() throws {
        // 新 Provider 的同一交易所代码：stooq 也用 600519（假设性——语义正确即可）
        let hint = IdentityHint(
            providerID: .stooq,
            code: ProviderCode(scheme: "stock_symbol", value: "600519"),
            exchange: .sse
        )
        let outcomes = try sync.establish(hints: [hint])
        guard case let .established(method, canonical, created) = outcomes["stooq|stock_symbol|600519"] else {
            return XCTFail("期望 established")
        }
        XCTAssertEqual(method, .exchangeSymbolExact)
        XCTAssertEqual(canonical, .listing(ListingID(rawValue: "lst_600519")))
        XCTAssertFalse(created)
    }

    func testPath2_requiresExchangeToMatch() throws {
        // 无 exchange 证据：不能凭 symbol 猜（可能撞不同交易所的同名代码）
        let hint = IdentityHint(
            providerID: .stooq,
            code: ProviderCode(scheme: "stock_symbol", value: "600519")
        )
        let outcomes = try sync.establish(hints: [hint])
        XCTAssertEqual(outcomes["stooq|stock_symbol|600519"], .unresolved)
        // 有 exchange 但不匹配：不误映射到 SSE 的 600519——交易所代码
        // 各自权威，深市 600519 是另一个标的（创建模式建新 listing）
        let mismatch = IdentityHint(
            providerID: .stooq,
            code: ProviderCode(scheme: "stock_symbol", value: "600519"),
            exchange: .szse
        )
        let outcomes2 = try sync.establish(hints: [mismatch])
        guard case let .established(_, canonical2, _) = outcomes2["stooq|stock_symbol|600519"] else {
            return XCTFail("期望 established（新实体）")
        }
        XCTAssertNotEqual(canonical2, .listing(ListingID(rawValue: "lst_600519")),
                          "深市同码不得映射到沪市 listing")
    }

    // MARK: - 路径 3：ISIN / CIK

    func testPath3a_isinMatchesInstrument() throws {
        // 已有 Instrument 带 ISIN（US0378331005 = AAPL），新 Provider 代码带同 ISIN
        let hint = IdentityHint(
            providerID: .alphaVantage,
            code: ProviderCode(scheme: "stock_symbol", value: "AAPL"),
            isin: "US0378331005"
        )
        let outcomes = try sync.establish(hints: [hint])
        guard case let .established(method, canonical, _) = outcomes["alpha-vantage|stock_symbol|AAPL"] else {
            return XCTFail("期望 established，实际 \(String(describing: outcomes))")
        }
        XCTAssertEqual(method, .isinOrCik)
        // 唯一挂牌 → 映射到 Listing 层
        XCTAssertEqual(canonical, .listing(ListingID(rawValue: "lst_aapl")))
    }

    func testPath3b_cikMatchesLegalEntity() throws {
        // SEC CIK 匹配 LegalEntity.regulatoryIDs（SEC 事实的 canonical 目标）
        let hint = IdentityHint(
            providerID: .sec,
            code: ProviderCode(scheme: "sec_cik", value: "320193"),
            cik: "320193"
        )
        let outcomes = try sync.establish(hints: [hint])
        guard case let .established(method, canonical, _) = outcomes["sec|sec_cik|320193"] else {
            return XCTFail("期望 established")
        }
        XCTAssertEqual(method, .isinOrCik)
        XCTAssertEqual(canonical, .legalEntity(LegalEntityID(rawValue: "le_a")))
        // CIK 补零归一：输入 "0000320193" 同样命中
        let padded = IdentityHint(
            providerID: .sec,
            code: ProviderCode(scheme: "sec_cik", value: "0000320193"),
            cik: "0000320193"
        )
        let outcomes2 = try sync.establish(hints: [padded])
        guard case .established(_, let canonical2, _) = outcomes2["sec|sec_cik|0000320193"] else {
            return XCTFail("补零形态应同样建立")
        }
        XCTAssertEqual(canonical2, .legalEntity(LegalEntityID(rawValue: "le_a")))
    }

    // MARK: - 路径 4：manualVerified

    func testPath4_manualVerifiedRegistration() throws {
        // 悬空目标会被仓库拒收（GRDB-7 的 polymorphic 校验）——先建实体
        try repository.upsert(Instrument(
            id: InstrumentID(rawValue: "inst_161725"), issuerID: LegalEntityID(rawValue: "le_x"),
            kind: .fund, displayName: "招商中证白酒指数", baseCurrency: .cny, assetClass: .equity
        ))
        try repository.upsert(FundProduct(
            id: FundProductID(rawValue: "fp_161725"),
            instrumentID: InstrumentID(rawValue: "inst_161725"),
            fundType: .openEnd, displayName: "招商中证白酒指数（产品）"
        ))
        let ok = try sync.registerManualVerified(
            providerID: .eastmoney, scheme: "fund_product_code", value: "161725",
            canonical: .fundProduct(FundProductID(rawValue: "fp_161725"))
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(
            repository.resolve(providerID: .eastmoney, scheme: "fund_product_code", value: "161725"),
            .fundProduct(FundProductID(rawValue: "fp_161725"))
        )
    }

    // MARK: - 创建模式（新标的进 Instrument Master）

    func testCreationMode_buildsDeterministicEntityChain() throws {
        // 全新美股：exchange + symbol 权威证据 → LegalEntity + Instrument + Listing
        let hint = IdentityHint(
            providerID: .stooq,
            code: ProviderCode(scheme: "stock_symbol", value: "MSFT"),
            exchange: .nasdaq,
            displayName: "Microsoft Corporation",
            instrumentKind: .stock,
            jurisdiction: .unitedStates
        )
        let outcomes = try sync.establish(hints: [hint])
        guard case let .established(method, canonical, created) = outcomes["stooq|stock_symbol|MSFT"] else {
            return XCTFail("期望 established（创建模式），实际 \(String(describing: outcomes))")
        }
        XCTAssertEqual(method, .exchangeSymbolExact)
        XCTAssertTrue(created)

        // 新标的确实进了 Instrument Master：FK 链完整可查
        guard case .listing(let listingID) = canonical else { return XCTFail("挂牌级目标") }
        let listing = try XCTUnwrap(repository.listing(listingID))
        XCTAssertEqual(listing.exchange, .nasdaq)
        XCTAssertEqual(listing.symbol, "MSFT")
        let instrument = try XCTUnwrap(repository.instrument(listing.instrumentID))
        XCTAssertEqual(instrument.kind, .stock)
        XCTAssertEqual(instrument.displayName, "Microsoft Corporation")
        XCTAssertNotNil(repository.legalEntity(instrument.issuerID), "FK 链：发行人存在")

        // 幂等：重跑同一 hint → alreadyRegistered（确定性 ID，实体不翻倍）
        let rerun = try sync.establish(hints: [hint])
        guard case let .alreadyRegistered(method2, canonical2) = rerun["stooq|stock_symbol|MSFT"] else {
            return XCTFail("期望 alreadyRegistered，实际 \(String(describing: rerun))")
        }
        XCTAssertEqual(method2, .exchangeSymbolExact)
        XCTAssertEqual(canonical2, canonical)
        XCTAssertEqual(repository.allListings().filter { $0.symbol == "MSFT" }.count, 1)
        XCTAssertEqual(
            repository.resolve(providerID: .stooq, scheme: "stock_symbol", value: "MSFT"),
            canonical
        )
    }

    func testCreationMode_fundKindRefuses() throws {
        // 基金类不自动创建（份额结构不能猜）→ 无其他证据时 fuzzy/unresolved
        let hint = IdentityHint(
            providerID: .eastmoney,
            code: ProviderCode(scheme: "fund_code", value: "161725"),
            displayName: "招商中证白酒指数",
            instrumentKind: .fund
        )
        let outcomes = try sync.establish(hints: [hint])
        if case .established = outcomes["eastmoney|fund_code|161725"] {
            XCTFail("基金类不得自动创建实体")
        }
    }

    func testCreationMode_isinOnlyCreatesInstrument() throws {
        // ISIN（无 exchange）：创建 Instrument（无挂牌层），isinOrCik 登记
        let hint = IdentityHint(
            providerID: .eastmoney,
            code: ProviderCode(scheme: "fund_index", value: "CSI300"),
            isin: "XX000CSP300",
            displayName: "沪深300",
            instrumentKind: .index,
            assetClass: .equity,
            jurisdiction: .chinaMainland
        )
        let outcomes = try sync.establish(hints: [hint])
        guard case let .established(method, canonical, created) = outcomes["eastmoney|fund_index|CSI300"] else {
            return XCTFail("期望 established")
        }
        XCTAssertEqual(method, .isinOrCik)
        XCTAssertTrue(created)
        guard case .instrument(let instrumentID) = canonical else { return XCTFail("工具级目标") }
        XCTAssertEqual(repository.instrument(instrumentID)?.isin, "XX000CSP300")
    }

    // MARK: - fuzzy（只产 candidate + Verification）

    func testFuzzyProducesCandidatesOnlyUntilVerified() throws {
        // 名称高度相似但无权威证据：只产 candidate，lookup 仍不可解析
        let hint = IdentityHint(
            providerID: .eastmoney,
            code: ProviderCode(scheme: "stock_symbol", value: "600519X"),
            displayName: "贵州茅台股份有限公司"
        )
        let outcomes = try sync.establish(hints: [hint])
        guard case let .fuzzyCandidates(candidates) = outcomes["eastmoney|stock_symbol|600519X"] else {
            return XCTFail("期望 fuzzyCandidates，实际 \(String(describing: outcomes))")
        }
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates[0].confidence >= 0.5)

        // 防火墙 1：fuzzy 登记行不可被 lookup 当权威解析
        XCTAssertNil(repository.resolve(
            providerID: .eastmoney, scheme: "stock_symbol", value: "600519X"
        ))

        // Verification accept → manualVerified → 可解析
        let best = candidates[0]
        let accepted = try sync.verify(
            providerID: .eastmoney, scheme: "stock_symbol", value: "600519X",
            canonical: best.canonical, decision: .accept
        )
        XCTAssertTrue(accepted)
        XCTAssertEqual(
            repository.resolve(providerID: .eastmoney, scheme: "stock_symbol", value: "600519X"),
            best.canonical
        )

        // reject 路径：另一 fuzzy 代码拒绝后保持不可解析
        let other = IdentityHint(
            providerID: .eastmoney,
            code: ProviderCode(scheme: "stock_symbol", value: "600519Y"),
            displayName: "贵州茅台股份有限公司"
        )
        _ = try sync.establish(hints: [other])
        let rejected = try sync.verify(
            providerID: .eastmoney, scheme: "stock_symbol", value: "600519Y",
            canonical: best.canonical, decision: .reject
        )
        XCTAssertFalse(rejected)
        XCTAssertNil(repository.resolve(
            providerID: .eastmoney, scheme: "stock_symbol", value: "600519Y"
        ))
    }

    func testBigramDiceSimilarity() {
        // 确定性相似度：完全相等 1.0；高相似高分；无关 0 分
        XCTAssertEqual(IdentitySync.bigramDice("贵州茅台", "贵州茅台"), 1.0)
        XCTAssertGreaterThan(
            IdentitySync.bigramDice("贵州茅台酒股份", "贵州茅台股份"),
            IdentitySync.bigramDice("贵州茅台", "宁德时代")
        )
        XCTAssertEqual(IdentitySync.bigramDice("abc", "xyz"), 0.0)
        // 短串退化到归一化全等比较
        XCTAssertEqual(IdentitySync.bigramDice("A", "a"), 1.0)
        XCTAssertEqual(IdentitySync.bigramDice("A", "b"), 0.0)
    }

    // MARK: - 冲突与幂等

    func testConflictDoesNotOverwriteExistingMapping() throws {
        // 已有权威映射指向 lst_600519；新提案（同 ISIN 但指向别的工具）冲突
        try repository.upsert(Instrument(
            id: InstrumentID(rawValue: "inst_decoy"), issuerID: LegalEntityID(rawValue: "le_x"),
            kind: .stock, displayName: "Decoy", baseCurrency: .cny, assetClass: .equity,
            isin: "CNDUPPLICATE"
        ))
        let hint = IdentityHint(
            providerID: .eastmoney,
            code: ProviderCode(scheme: "stock_symbol", value: "600519"),
            isin: "CNDUPPLICATE",
            displayName: "Decoy"
        )
        // 600519 已登记 → 提案指向 decoy → conflict，保留既有
        let outcomes = try sync.establish(hints: [hint])
        guard case let .conflict(existing, attempted) = outcomes["eastmoney|stock_symbol|600519"] else {
            return XCTFail("期望 conflict，实际 \(String(describing: outcomes))")
        }
        XCTAssertEqual(existing, .listing(ListingID(rawValue: "lst_600519")))
        XCTAssertEqual(attempted, .instrument(InstrumentID(rawValue: "inst_decoy")))
        XCTAssertEqual(
            repository.resolve(providerID: .eastmoney, scheme: "stock_symbol", value: "600519"),
            .listing(ListingID(rawValue: "lst_600519")),
            "冲突不覆盖既有映射"
        )
    }

    func testUnresolvedWhenNoEvidence() throws {
        let hint = IdentityHint(
            providerID: .eastmoney,
            code: ProviderCode(scheme: "stock_symbol", value: "999999")
        )
        let outcomes = try sync.establish(hints: [hint])
        XCTAssertEqual(outcomes["eastmoney|stock_symbol|999999"], .unresolved)
    }

    // MARK: - P1 修复回归

    func testSameNameDifferentSymbolsDoNotMerge() throws {
        // 两个同名不同码的证券：创建模式必须产出彼此独立的实体链
        let outcomes = try sync.establish(hints: [
            IdentityHint(
                providerID: .stooq,
                code: ProviderCode(scheme: "stock_symbol", value: "MSFT"),
                exchange: .nasdaq,
                displayName: "同名公司",
                instrumentKind: .stock,
                jurisdiction: .unitedStates
            ),
            IdentityHint(
                providerID: .stooq,
                code: ProviderCode(scheme: "stock_symbol", value: "FAKE"),
                exchange: .nasdaq,
                displayName: "同名公司",
                instrumentKind: .stock,
                jurisdiction: .unitedStates
            ),
        ])
        var canonicals: [CanonicalRef] = []
        for key in ["stooq|stock_symbol|MSFT", "stooq|stock_symbol|FAKE"] {
            guard case let .established(_, canonical, _) = outcomes[key] else {
                return XCTFail("期望 established：\(key)")
            }
            canonicals.append(canonical)
        }
        XCTAssertNotEqual(canonicals[0], canonicals[1], "同名不同码不得合并")

        // 深入实体层：listing / instrument / entity 三层都各自独立
        guard case let .listing(l1) = canonicals[0], case let .listing(l2) = canonicals[1] else {
            return XCTFail("挂牌级目标")
        }
        let listing1 = try XCTUnwrap(repository.listing(l1))
        let listing2 = try XCTUnwrap(repository.listing(l2))
        XCTAssertNotEqual(listing1.instrumentID, listing2.instrumentID)
        let inst1 = try XCTUnwrap(repository.instrument(listing1.instrumentID))
        let inst2 = try XCTUnwrap(repository.instrument(listing2.instrumentID))
        XCTAssertNotEqual(inst1.issuerID, inst2.issuerID, "占位发行人也按标的独立派生")
        // 名称只是属性：两者显示名相同但 ID 不同
        XCTAssertEqual(inst1.displayName, inst2.displayName)
    }

    func testStaleVerificationCannotOverwriteAuthoritativeMapping() throws {
        // 1) fuzzy 候选生成（登记到 canonical A）
        let hint = IdentityHint(
            providerID: .eastmoney,
            code: ProviderCode(scheme: "stock_symbol", value: "600519X"),
            displayName: "贵州茅台股份有限公司"
        )
        let outcomes = try sync.establish(hints: [hint])
        guard case let .fuzzyCandidates(candidates) = outcomes["eastmoney|stock_symbol|600519X"],
              let best = candidates.first else {
            return XCTFail("期望 fuzzyCandidates")
        }

        // 2) 期间另一轮建立了权威映射（指向已存在的 AAPL listing，≠ fuzzy 候选 A）
        let authoritativeRef = CanonicalRef.listing(ListingID(rawValue: "lst_aapl"))
        XCTAssertNotEqual(authoritativeRef, best.canonical)
        try repository.upsert(ProviderIdentifier(
            providerID: .eastmoney, identifierScheme: "stock_symbol",
            identifierValue: "600519X",
            canonical: authoritativeRef,
            resolutionMethod: .exchangeSymbolExact, resolvedAt: Self.fixedNow
        ))

        // 3) 过期的 fuzzy accept（仍指向 A）不得覆盖权威映射
        let accepted = try sync.verify(
            providerID: .eastmoney, scheme: "stock_symbol", value: "600519X",
            canonical: best.canonical, decision: .accept
        )
        XCTAssertFalse(accepted, "过期 Verification 必须被拒收")
        XCTAssertEqual(
            repository.resolve(providerID: .eastmoney, scheme: "stock_symbol", value: "600519X"),
            authoritativeRef,
            "既有权威映射不动"
        )

        // 4) 与既有权威一致的 verify 视为幂等成功
        let idempotent = try sync.verify(
            providerID: .eastmoney, scheme: "stock_symbol", value: "600519X",
            canonical: authoritativeRef, decision: .accept
        )
        XCTAssertTrue(idempotent)
        XCTAssertEqual(
            repository.resolve(providerID: .eastmoney, scheme: "stock_symbol", value: "600519X"),
            authoritativeRef
        )
    }

    // MARK: - 测试基础设施

    private func seedMaster() throws {
        try repository.upsert(LegalEntity(
            id: LegalEntityID(rawValue: "le_x"), displayName: "某基金管理有限公司",
            jurisdiction: .chinaMainland, kind: .fundManager
        ))
        try repository.upsert(Instrument(
            id: InstrumentID(rawValue: "inst_600519"), issuerID: LegalEntityID(rawValue: "le_x"),
            kind: .stock, displayName: "贵州茅台", baseCurrency: .cny, assetClass: .equity
        ))
        try repository.upsert(Listing(
            id: ListingID(rawValue: "lst_600519"), instrumentID: InstrumentID(rawValue: "inst_600519"),
            exchange: .sse, symbol: "600519", tradingCurrency: .cny
        ))
        try repository.upsert(ProviderIdentifier(
            providerID: .eastmoney, identifierScheme: "stock_symbol",
            identifierValue: "600519", canonical: .listing(ListingID(rawValue: "lst_600519")),
            resolutionMethod: .manualVerified, resolvedAt: cst(2026, 1, 1)
        ))

        try repository.upsert(LegalEntity(
            id: LegalEntityID(rawValue: "le_a"), displayName: "Apple Inc.",
            jurisdiction: .unitedStates, kind: .listedCompany,
            regulatoryIDs: [RegulatoryID(scheme: "CIK", value: "0000320193")]
        ))
        try repository.upsert(Instrument(
            id: InstrumentID(rawValue: "inst_aapl"), issuerID: LegalEntityID(rawValue: "le_a"),
            kind: .stock, displayName: "Apple Inc.", baseCurrency: .usd, assetClass: .equity,
            isin: "US0378331005"
        ))
        try repository.upsert(Listing(
            id: ListingID(rawValue: "lst_aapl"), instrumentID: InstrumentID(rawValue: "inst_aapl"),
            exchange: .nasdaq, symbol: "AAPL", tradingCurrency: .usd
        ))
        try repository.upsert(ProviderIdentifier(
            providerID: .stooq, identifierScheme: "stock_symbol",
            identifierValue: "AAPL", canonical: .listing(ListingID(rawValue: "lst_aapl")),
            resolutionMethod: .exchangeSymbolExact, resolvedAt: cst(2026, 1, 1)
        ))
    }
}
