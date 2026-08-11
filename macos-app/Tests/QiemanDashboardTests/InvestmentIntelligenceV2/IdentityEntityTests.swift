import XCTest
@testable import QiemanDashboard

/// DOM-2 单元测试：五层 Identity 实体的字段齐全、A/C 类拆开、Codable round-trip。
///
/// M1 验收：所有 DOM 类型 Codable round-trip + Sendable 通过（rollout §4.0）。
final class IdentityEntityTests: XCTestCase {

    // MARK: - 基础枚举 round-trip

    func testExchange_codableRoundTrip() throws {
        for exchange in Exchange.allCases {
            let data = try JSONEncoder().encode(exchange)
            let decoded = try JSONDecoder().decode(Exchange.self, from: data)
            XCTAssertEqual(exchange, decoded)
        }
    }

    func testExchange_jurisdictionMapping() {
        XCTAssertEqual(Exchange.sse.jurisdiction, .chinaMainland)
        XCTAssertEqual(Exchange.szse.jurisdiction, .chinaMainland)
        XCTAssertEqual(Exchange.hkex.jurisdiction, .hongKong)
        XCTAssertEqual(Exchange.nyse.jurisdiction, .unitedStates)
        XCTAssertEqual(Exchange.nasdaq.jurisdiction, .unitedStates)
        XCTAssertEqual(Exchange.platform.jurisdiction, .platform)
    }

    func testAssetClass_allCases() {
        XCTAssertEqual(
            AssetClass.allCases,
            [.equity, .fixedIncome, .commodity, .cash, .alternative]
        )
    }

    // MARK: - LegalEntity

    func testLegalEntity_codableRoundTrip() throws {
        let entity = LegalEntity(
            id: LegalEntityID(rawValue: "ent_kweichow"),
            displayName: "贵州茅台股份有限公司",
            jurisdiction: .chinaMainland,
            kind: .listedCompany,
            regulatoryIDs: [RegulatoryID(scheme: "CSRC", value: "915200007143058563")]
        )
        let data = try JSONEncoder().encode(entity)
        let decoded = try JSONDecoder().decode(LegalEntity.self, from: data)
        XCTAssertEqual(entity, decoded)
        XCTAssertEqual(decoded.regulatoryIDs.count, 1)
        XCTAssertEqual(decoded.regulatoryIDs.first?.scheme, "CSRC")
    }

    // MARK: - Instrument

    func testInstrument_codableRoundTrip_withISIN() throws {
        let instrument = Instrument(
            id: InstrumentID(rawValue: "inst_600519"),
            issuerID: LegalEntityID(rawValue: "ent_kweichow"),
            kind: .stock,
            displayName: "贵州茅台",
            baseCurrency: .cny,
            assetClass: .equity,
            isin: "CNE0000009C6"
        )
        let data = try JSONEncoder().encode(instrument)
        let decoded = try JSONDecoder().decode(Instrument.self, from: data)
        XCTAssertEqual(instrument, decoded)
        XCTAssertEqual(decoded.isin, "CNE0000009C6")
    }

    func testInstrument_codableRoundTrip_nilISIN() throws {
        let instrument = Instrument(
            id: InstrumentID(rawValue: "inst_idx_000300"),
            issuerID: LegalEntityID(rawValue: "ent_csindex"),
            kind: .index,
            displayName: "沪深300指数",
            baseCurrency: .cny,
            assetClass: .equity,
            isin: nil
        )
        let data = try JSONEncoder().encode(instrument)
        let decoded = try JSONDecoder().decode(Instrument.self, from: data)
        XCTAssertEqual(instrument, decoded)
        XCTAssertNil(decoded.isin)
    }

    // MARK: - Listing（多挂牌共享同一 Instrument）

    func testListing_multipleShareSameInstrumentID() {
        let instrumentID = InstrumentID(rawValue: "inst_abc")
        let sseListing = Listing(
            id: ListingID(rawValue: "list_sse_600519"),
            instrumentID: instrumentID,
            exchange: .sse,
            symbol: "600519",
            tradingCurrency: .cny
        )
        let hkListing = Listing(
            id: ListingID(rawValue: "list_hkex_0568"),
            instrumentID: instrumentID,
            exchange: .hkex,
            symbol: "0568",
            tradingCurrency: .hkd
        )
        // 同一 InstrumentID 可被多个 Listing 共享
        XCTAssertEqual(sseListing.instrumentID, hkListing.instrumentID)
        // 不同 Listing 各自的代码、货币独立
        XCTAssertNotEqual(sseListing.symbol, hkListing.symbol)
        XCTAssertNotEqual(sseListing.tradingCurrency, hkListing.tradingCurrency)
    }

    func testListing_codableRoundTrip() throws {
        let listing = Listing(
            id: ListingID(rawValue: "list_aapl"),
            instrumentID: InstrumentID(rawValue: "inst_aapl"),
            exchange: .nasdaq,
            symbol: "AAPL",
            tradingCurrency: .usd
        )
        let data = try JSONEncoder().encode(listing)
        let decoded = try JSONDecoder().decode(Listing.self, from: data)
        XCTAssertEqual(listing, decoded)
    }

    // MARK: - FundProduct / FundShareClass（A/C 类拆开）

    func testFundShareClass_ACShareClassesSeparateInstrument() {
        let productID = FundProductID(rawValue: "prod_110022")
        // 同一产品的 A 类、C 类是两个独立 Instrument（业务计算锚定 Instrument）
        let aInstrument = InstrumentID(rawValue: "inst_110022_A")
        let cInstrument = InstrumentID(rawValue: "inst_110022_C")

        let aClass = FundShareClass(
            id: FundShareClassID(rawValue: "sc_110022_A"),
            productID: productID,
            instrumentID: aInstrument,
            shareClassCode: "A",
            displayName: "易方达消费行业股票 A",
            feeStructure: FundShareClass.FeeStructure(
                frontEndLoad: 0.015,
                backEndLoad: nil,
                annualSalesFee: nil,
                managementFee: 0.015,
                custodyFee: 0.0025
            ),
            // 监管中立标识（ISIN）。Provider 原始代码（天天基金 110022、且慢
            // prodCode）走 ProviderIdentifier，不进 Canonical（ADR-DATA001 防火墙 1）
            regulatoryIDs: [RegulatoryID(scheme: "ISIN", value: "CN0000110022")]
        )
        let cClass = FundShareClass(
            id: FundShareClassID(rawValue: "sc_110022_C"),
            productID: productID,
            instrumentID: cInstrument,
            shareClassCode: "C",
            displayName: "易方达消费行业股票 C",
            feeStructure: FundShareClass.FeeStructure(
                frontEndLoad: nil,
                backEndLoad: nil,
                annualSalesFee: 0.005,
                managementFee: 0.015,
                custodyFee: 0.0025
            ),
            regulatoryIDs: [RegulatoryID(scheme: "ISIN", value: "CN0000110023")]
        )
        // 同一产品
        XCTAssertEqual(aClass.productID, cClass.productID)
        // 不同份额 / Instrument / 费率
        XCTAssertNotEqual(aClass.id, cClass.id)
        XCTAssertNotEqual(aClass.instrumentID, cClass.instrumentID)
        XCTAssertNotEqual(aClass.shareClassCode, cClass.shareClassCode)
        // A 类有前端费，C 类无前端但有销售服务费
        XCTAssertNotNil(aClass.feeStructure.frontEndLoad)
        XCTAssertNil(aClass.feeStructure.annualSalesFee)
        XCTAssertNil(cClass.feeStructure.frontEndLoad)
        XCTAssertNotNil(cClass.feeStructure.annualSalesFee)
    }

    func testFundProduct_codableRoundTrip() throws {
        let product = FundProduct(
            id: FundProductID(rawValue: "prod_110022"),
            instrumentID: InstrumentID(rawValue: "inst_110022"),
            fundType: .openEnd,
            displayName: "易方达消费行业股票",
            regulatoryIDs: [RegulatoryID(scheme: "CSRC_FUND_CODE", value: "110022")]
        )
        let data = try JSONEncoder().encode(product)
        let decoded = try JSONDecoder().decode(FundProduct.self, from: data)
        XCTAssertEqual(product, decoded)
        XCTAssertEqual(decoded.regulatoryIDs.first?.value, "110022")
    }

    func testFundShareClass_codableRoundTrip() throws {
        let shareClass = FundShareClass(
            id: FundShareClassID(rawValue: "sc_110022_A"),
            productID: FundProductID(rawValue: "prod_110022"),
            instrumentID: InstrumentID(rawValue: "inst_110022_A"),
            shareClassCode: "A",
            displayName: "易方达消费行业股票 A",
            feeStructure: FundShareClass.FeeStructure(
                frontEndLoad: 0.015,
                backEndLoad: nil,
                annualSalesFee: nil,
                managementFee: 0.015,
                custodyFee: 0.0025
            ),
            regulatoryIDs: [
                RegulatoryID(scheme: "ISIN", value: "CN0000110022"),
                RegulatoryID(scheme: "CSRC_FUND_CODE", value: "110022"),
            ]
        )
        let data = try JSONEncoder().encode(shareClass)
        let decoded = try JSONDecoder().decode(FundShareClass.self, from: data)
        XCTAssertEqual(shareClass, decoded)
        XCTAssertEqual(decoded.regulatoryIDs.count, 2)
    }

    // MARK: - ADR-DATA001 防火墙 1：Provider 代码不泄漏到 Canonical

    func testCanonicalEntities_doNotCarryProviderCodes() {
        // FundProduct / FundShareClass 不含 primaryCode / officialCodes 字段。
        // Provider 原始代码（天天基金 6 位码、且慢 prodCode）只能通过
        // ProviderIdentifier 表达（见 ProviderIdentifierTests）。
        let product = FundProduct(
            id: FundProductID(rawValue: "prod_x"),
            instrumentID: InstrumentID(rawValue: "inst_x"),
            fundType: .openEnd,
            displayName: "X"
        )
        let shareClass = FundShareClass(
            id: FundShareClassID(rawValue: "sc_x"),
            productID: product.id,
            instrumentID: product.instrumentID,
            shareClassCode: "A",
            displayName: "X A",
            feeStructure: FundShareClass.FeeStructure(
                frontEndLoad: nil, backEndLoad: nil,
                annualSalesFee: nil, managementFee: nil, custodyFee: nil
            )
        )
        // Mirror 检查：字段名里不应出现 "primaryCode" / "officialCodes"
        let productFieldNames = Mirror(reflecting: product).children.compactMap(\.label)
        XCTAssertFalse(productFieldNames.contains("primaryCode"),
                       "FundProduct 不应携带 primaryCode（违反 ADR-DATA001 防火墙 1）")
        XCTAssertFalse(productFieldNames.contains("officialCodes"))

        let shareClassFieldNames = Mirror(reflecting: shareClass).children.compactMap(\.label)
        XCTAssertFalse(shareClassFieldNames.contains("officialCodes"),
                       "FundShareClass 不应携带 officialCodes（违反 ADR-DATA001 防火墙 1）")
        XCTAssertFalse(shareClassFieldNames.contains("primaryCode"))
    }

    // MARK: - Sendable across actor

    private actor IdentityReceiver {
        func receiveInstrument(_ i: Instrument) -> Instrument { i }
        func receiveListing(_ l: Listing) -> Listing { l }
        func receiveShareClass(_ s: FundShareClass) -> FundShareClass { s }
    }

    func testIdentityTypes_sendableAcrossActor() async {
        let receiver = IdentityReceiver()
        let instrument = Instrument(
            id: InstrumentID(rawValue: "inst_x"),
            issuerID: LegalEntityID(rawValue: "ent_x"),
            kind: .stock,
            displayName: "X",
            baseCurrency: .cny,
            assetClass: .equity
        )
        let listing = Listing(
            id: ListingID(rawValue: "list_x"),
            instrumentID: instrument.id,
            exchange: .sse,
            symbol: "X",
            tradingCurrency: .cny
        )
        let shareClass = FundShareClass(
            id: FundShareClassID(rawValue: "sc_x"),
            productID: FundProductID(rawValue: "prod_x"),
            instrumentID: instrument.id,
            shareClassCode: "A",
            displayName: "X A",
            feeStructure: FundShareClass.FeeStructure(
                frontEndLoad: nil, backEndLoad: nil,
                annualSalesFee: nil, managementFee: nil, custodyFee: nil
            )
        )
        _ = await receiver.receiveInstrument(instrument)
        _ = await receiver.receiveListing(listing)
        _ = await receiver.receiveShareClass(shareClass)
    }
}
