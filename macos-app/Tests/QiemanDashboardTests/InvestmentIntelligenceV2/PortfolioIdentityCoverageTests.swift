import XCTest
@testable import QiemanDashboard

/// REPO-4b coverage gate for the current, unarchived portfolio universe.
///
/// The list intentionally contains only the non-sensitive identity dimensions
/// needed by Identity: provider, scheme, code, asset type, market and expected
/// canonical entity kind. It is not a copy of the application data file.
final class PortfolioIdentityCoverageTests: XCTestCase {

    private struct WeekdayCalendar: TradingCalendar {
        func isTradingDay(_ date: Date, jurisdiction: Jurisdiction) -> Bool {
            let weekday = Calendar(identifier: .gregorian).component(.weekday, from: date)
            return (2...6).contains(weekday)
        }

        func tradingDay(after date: Date, offset: Int, jurisdiction: Jurisdiction) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            var current = date
            var remaining = max(offset, 0)
            var safety = 0
            while remaining > 0 && safety < 14 {
                current = calendar.date(byAdding: .day, value: 1, to: current)!
                if isTradingDay(current, jurisdiction: jurisdiction) {
                    remaining -= 1
                }
                safety += 1
            }
            return current
        }

        func tradingDayStart(_ date: Date, jurisdiction: Jurisdiction) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            return calendar.startOfDay(for: date)
        }
    }

    private enum ExpectedCanonicalKind: String, Hashable {
        case listing = "LISTING"
        case fundProduct = "FUND_PRODUCT"
        case fundShareClass = "FUND_SHARE_CLASS"
    }

    private struct PortfolioKey: Hashable {
        let provider: String
        let scheme: String
        let code: String
        let assetType: String
        let market: String
        let canonicalKind: ExpectedCanonicalKind

        init(
            code: String,
            assetType: String,
            market: String,
            scheme: String,
            canonicalKind: ExpectedCanonicalKind
        ) {
            self.provider = DataProviderID.eastmoney.rawValue
            self.scheme = scheme
            self.code = code
            self.assetType = assetType
            self.market = market
            self.canonicalKind = canonicalKind
        }

        var identifierKey: String {
            "\(provider)::\(scheme)::\(code)"
        }
    }

    private static let currentUnarchivedPortfolio: [PortfolioKey] = [
        PortfolioKey(code: "600019", assetType: "stock", market: "SSE", scheme: "stock_symbol", canonicalKind: .listing),
        PortfolioKey(code: "163402", assetType: "fund", market: "OFF_EXCHANGE", scheme: "fund_code", canonicalKind: .fundProduct),
        PortfolioKey(code: "600585", assetType: "stock", market: "SSE", scheme: "stock_symbol", canonicalKind: .listing),
        PortfolioKey(code: "600048", assetType: "stock", market: "SSE", scheme: "stock_symbol", canonicalKind: .listing),
        PortfolioKey(code: "512000", assetType: "fund", market: "SSE", scheme: "stock_symbol", canonicalKind: .listing),
        PortfolioKey(code: "512690", assetType: "fund", market: "SSE", scheme: "stock_symbol", canonicalKind: .listing),
        PortfolioKey(code: "512880", assetType: "fund", market: "SSE", scheme: "stock_symbol", canonicalKind: .listing),
        PortfolioKey(code: "159857", assetType: "fund", market: "SZSE", scheme: "stock_symbol", canonicalKind: .listing),
        PortfolioKey(code: "004746", assetType: "fund", market: "OFF_EXCHANGE", scheme: "fund_code", canonicalKind: .fundShareClass),
        PortfolioKey(code: "012414", assetType: "fund", market: "OFF_EXCHANGE", scheme: "fund_code", canonicalKind: .fundShareClass),
        PortfolioKey(code: "017437", assetType: "fund", market: "OFF_EXCHANGE", scheme: "fund_code", canonicalKind: .fundShareClass),
        PortfolioKey(code: "001801", assetType: "fund", market: "OFF_EXCHANGE", scheme: "fund_code", canonicalKind: .fundShareClass),
        PortfolioKey(code: "165516", assetType: "fund", market: "OFF_EXCHANGE", scheme: "fund_code", canonicalKind: .fundShareClass)
    ]

    private func loadSeed() throws -> (IdentitySeed, InMemoryRepository, IdentityResolver) {
        let seed = try IdentitySeed.load(
            name: "v2-identity-portfolio",
            bundle: Bundle.module
        )
        let repository = InMemoryRepository(calendarBackend: WeekdayCalendar())
        repository.loadIdentitySeed(seed)
        return (seed, repository, IdentityResolver.from(repository.allProviderIdentifiers()))
    }

    func testSeedContainsExactlyTheCurrentUnarchivedUniverse() throws {
        let (seed, _, _) = try loadSeed()
        XCTAssertEqual(seed.providerIdentifiers.count, Self.currentUnarchivedPortfolio.count)

        let actualKeys = Set(seed.providerIdentifiers.map {
            IdentityResolver.key($0.providerID, scheme: $0.identifierScheme, value: $0.identifierValue)
        })
        let expectedKeys = Set(Self.currentUnarchivedPortfolio.map(\.identifierKey))
        XCTAssertEqual(actualKeys, expectedKeys)
        XCTAssertTrue(seed.providerIdentifiers.allSatisfy { $0.resolutionMethod == .manualVerified })
    }

    func testEveryPortfolioKeyIsAnExactManualResolvedReference() throws {
        let (_, repository, resolver) = try loadSeed()

        for entry in Self.currentUnarchivedPortfolio {
            let resolution = resolver.resolve(
                providerID: .eastmoney,
                scheme: entry.scheme,
                value: entry.code
            )

            guard case .resolved(let canonical, let method) = resolution else {
                XCTFail("portfolio identity did not resolve exactly for \(entry.identifierKey): \(resolution)")
                continue
            }
            XCTAssertEqual(method, .manualVerified)

            switch (entry.canonicalKind, canonical) {
            case (.listing, .listing(let listingID)):
                guard let listing = repository.listing(listingID) else {
                    XCTFail("listing reference is dangling for \(entry.identifierKey)")
                    continue
                }
                XCTAssertEqual(listing.symbol, entry.code)
                XCTAssertEqual(listing.exchange.rawValue, entry.market)
                guard let instrument = repository.instrument(listing.instrumentID) else {
                    XCTFail("listing instrument reference is dangling for \(entry.identifierKey)")
                    continue
                }
                let expectedKind: InstrumentKind = entry.assetType == "stock" ? .stock : .exchangeTradedFund
                XCTAssertEqual(instrument.kind, expectedKind)
                XCTAssertNotNil(repository.legalEntity(instrument.issuerID))

            case (.fundProduct, .fundProduct(let productID)):
                guard let product = repository.fundProduct(productID) else {
                    XCTFail("fund product reference is dangling for \(entry.identifierKey)")
                    continue
                }
                guard let instrument = repository.instrument(product.instrumentID) else {
                    XCTFail("fund product instrument reference is dangling for \(entry.identifierKey)")
                    continue
                }
                XCTAssertEqual(instrument.kind, .fund)
                XCTAssertNotNil(repository.legalEntity(instrument.issuerID))

            case (.fundShareClass, .fundShareClass(let shareClassID)):
                guard let shareClass = repository.fundShareClass(shareClassID) else {
                    XCTFail("fund share class reference is dangling for \(entry.identifierKey)")
                    continue
                }
                guard let product = repository.fundProduct(shareClass.productID) else {
                    XCTFail("fund share class product reference is dangling for \(entry.identifierKey)")
                    continue
                }
                guard let productInstrument = repository.instrument(product.instrumentID) else {
                    XCTFail("fund product instrument reference is dangling for \(entry.identifierKey)")
                    continue
                }
                guard let instrument = repository.instrument(shareClass.instrumentID) else {
                    XCTFail("fund share class instrument reference is dangling for \(entry.identifierKey)")
                    continue
                }
                XCTAssertEqual(productInstrument.kind, .fund)
                XCTAssertNotNil(repository.legalEntity(productInstrument.issuerID))
                XCTAssertEqual(instrument.kind, .fund)
                XCTAssertNotNil(repository.legalEntity(instrument.issuerID))

            default:
                XCTFail("canonical type mismatch for \(entry.identifierKey): \(canonical)")
            }
        }
    }

    func testPortfolioCoverageRejectsCandidatesAndLeavesNonHoldingsUnresolved() throws {
        let (seed, _, resolver) = try loadSeed()

        for identifier in seed.providerIdentifiers {
            switch resolver.resolve(
                providerID: identifier.providerID,
                scheme: identifier.identifierScheme,
                value: identifier.identifierValue
            ) {
            case .resolved(_, let method):
                XCTAssertEqual(method, .manualVerified)
            case .candidates:
                XCTFail("portfolio seed must not contain a fuzzy candidate")
            case .unresolved:
                XCTFail("portfolio seed must not contain an unresolved identifier")
            }
        }

        XCTAssertEqual(
            resolver.resolve(providerID: .eastmoney, scheme: "fund_code", value: "999999"),
            .unresolved,
            "non-portfolio identifiers remain for Identity Sync"
        )
    }
}
