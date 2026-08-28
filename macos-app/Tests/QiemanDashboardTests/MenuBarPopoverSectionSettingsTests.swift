import XCTest
@testable import QiemanDashboard

@MainActor
final class MenuBarPopoverSectionSettingsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: MenuBarPopoverSectionSettings.storageKey)
        UserDefaults.standard.removeObject(forKey: MenuBarPopoverSectionSettings.legacyTopSectionStorageKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: MenuBarPopoverSectionSettings.storageKey)
        UserDefaults.standard.removeObject(forKey: MenuBarPopoverSectionSettings.legacyTopSectionStorageKey)
        super.tearDown()
    }

    // MARK: - Settings Value

    func testDefaultSettingsShowAllSectionsWithDefaultQuoteSelections() {
        let settings = MenuBarPopoverSectionSettings.default

        XCTAssertEqual(
            settings.order,
            [.portfolio, .watchlist, .marketIndices, .goldForex]
        )
        XCTAssertEqual(settings.visibleSections, settings.order)
        XCTAssertEqual(settings.marketIndexKinds, [.sseComposite, .csi300, .chinext])
        XCTAssertEqual(settings.goldForexKinds, [.xauUSD, .usdCNY])
        XCTAssertFalse(settings.isHidden(.marketIndices))
        XCTAssertFalse(settings.isHidden(.goldForex))
    }

    func testCodableRoundTripPreservesOrderHiddenAndSelections() throws {
        let settings = MenuBarPopoverSectionSettings(
            order: [.goldForex, .marketIndices, .portfolio, .watchlist],
            hidden: [.portfolio],
            marketIndexKinds: [.hsi, .nasdaq],
            goldForexKinds: [.xauUSD, .usdCNH]
        )

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(MenuBarPopoverSectionSettings.self, from: data)

        XCTAssertEqual(decoded.order, settings.order)
        XCTAssertEqual(decoded.hidden, settings.hidden)
        XCTAssertEqual(decoded.marketIndexKinds, settings.marketIndexKinds)
        XCTAssertEqual(decoded.goldForexKinds, settings.goldForexKinds)
        XCTAssertEqual(decoded.visibleSections, [.goldForex, .marketIndices, .watchlist])
    }

    func testNormalizedAppendsMissingSectionsDedupesAndStabilizesQuoteKinds() {
        let settings = MenuBarPopoverSectionSettings(
            order: [.watchlist, .watchlist, .marketIndices],
            hidden: [.portfolio, .portfolio],
            marketIndexKinds: [.nasdaq, .sseComposite, .nasdaq],
            goldForexKinds: [.usdCNH, .xauUSD]
        )

        let normalized = settings.normalized()

        // 缺失的板块按 allCases 顺序补到末尾;重复项去掉。
        XCTAssertEqual(
            normalized.order,
            [.watchlist, .marketIndices, .portfolio, .goldForex]
        )
        XCTAssertEqual(normalized.hidden, [.portfolio])
        // 行情勾选按 allCases 顺序稳定排序,方便 UI 展示与请求复用。
        XCTAssertEqual(normalized.marketIndexKinds, [.sseComposite, .nasdaq])
        XCTAssertEqual(normalized.goldForexKinds, [.xauUSD, .usdCNH])
    }

    func testDecodingUnknownRawValuesDropsThemInsteadOfFailing() throws {
        let payload = """
        {"order":["goldForex","futureBlock","portfolio"],"hidden":["futureBlock"],
         "marketIndexKinds":["csi300","ghostIndex"],"goldForexKinds":["xauUSD","ghostMetal"]}
        """
        let decoded = try JSONDecoder().decode(
            MenuBarPopoverSectionSettings.self, from: Data(payload.utf8)
        )

        XCTAssertEqual(decoded.order, [.goldForex, .portfolio])
        XCTAssertEqual(decoded.hidden, [])
        XCTAssertEqual(decoded.marketIndexKinds, [.csi300])
        XCTAssertEqual(decoded.goldForexKinds, [.xauUSD])
    }

    func testLoadMigratesLegacyTopSectionPreferenceWhenNewKeyAbsent() {
        UserDefaults.standard.set(
            MenuBarPopoverSectionKind.watchlist.rawValue,
            forKey: MenuBarPopoverSectionSettings.legacyTopSectionStorageKey
        )

        let loaded = MenuBarPopoverSectionSettings.load()

        XCTAssertEqual(loaded.order.first, .watchlist)
        XCTAssertEqual(
            loaded.order,
            [.watchlist, .portfolio, .marketIndices, .goldForex]
        )
        // 迁移结果写回新 key,后续 load 直接走新路径。
        XCTAssertNotNil(UserDefaults.standard.data(forKey: MenuBarPopoverSectionSettings.storageKey))
    }

    func testLoadPrefersNewStorageOverLegacyKey() throws {
        let stored = MenuBarPopoverSectionSettings(
            order: [.marketIndices, .portfolio, .watchlist, .goldForex],
            hidden: [.watchlist]
        )
        stored.save()
        UserDefaults.standard.set(
            MenuBarPopoverSectionKind.portfolio.rawValue,
            forKey: MenuBarPopoverSectionSettings.legacyTopSectionStorageKey
        )

        let loaded = MenuBarPopoverSectionSettings.load()

        XCTAssertEqual(loaded.order.first, .marketIndices)
        XCTAssertEqual(loaded.visibleSections, [.marketIndices, .portfolio, .goldForex])
    }

    // MARK: - AppModel Integration

    func testSelectedMenuBarMarketIndexKindsUnionsTickerAndPopoverSelections() {
        let model = AppModel()
        let hsiTicker = MenuBarTickerKind.tickerKind(indexKind: .hsi, metric: .changePct)
        XCTAssertNotNil(hsiTicker)
        model.menuBarTickerSettings = MenuBarTickerSettings(
            isEnabled: true,
            maxVisibleItems: 2,
            selections: [.kind(hsiTicker!)]
        )
        model.menuBarPopoverSections = MenuBarPopoverSectionSettings(
            marketIndexKinds: [.nasdaq, .sseComposite, .hsi]
        )

        XCTAssertEqual(
            model.selectedMenuBarMarketIndexKinds,
            [.sseComposite, .hsi, .nasdaq]
        )
    }

    func testSelectedMenuBarMarketIndexKindsIgnoresTickerWhenDisabledAndHiddenPopoverBlock() {
        let model = AppModel()
        let hsiTicker = MenuBarTickerKind.tickerKind(indexKind: .hsi, metric: .changePct)
        model.menuBarTickerSettings = MenuBarTickerSettings(
            isEnabled: false,
            maxVisibleItems: 2,
            selections: [.kind(hsiTicker!)]
        )
        model.menuBarPopoverSections = MenuBarPopoverSectionSettings(
            hidden: [.marketIndices],
            marketIndexKinds: [.sseComposite]
        )

        // ticker 关闭且大盘块隐藏:两者都不驱动刷新。
        XCTAssertTrue(model.selectedMenuBarMarketIndexKinds.isEmpty)
    }

    func testSelectedMenuBarGoldForexKindsFollowSectionVisibility() {
        let model = AppModel()
        model.menuBarPopoverSections = MenuBarPopoverSectionSettings(
            goldForexKinds: [.xauUSD, .usdCNY]
        )
        XCTAssertEqual(model.selectedMenuBarGoldForexKinds, [.xauUSD, .usdCNY])

        model.menuBarPopoverSections = MenuBarPopoverSectionSettings(
            hidden: [.goldForex],
            goldForexKinds: [.xauUSD, .usdCNY]
        )
        XCTAssertTrue(model.selectedMenuBarGoldForexKinds.isEmpty)
    }

    func testMoveAndHideMutationsPersistThroughAppModel() {
        let model = AppModel()
        model.menuBarPopoverSections = MenuBarPopoverSectionSettings(
            order: [.portfolio, .watchlist, .marketIndices, .goldForex]
        )

        model.moveMenuBarPopoverSection(.goldForex, offset: -1)
        XCTAssertEqual(
            model.menuBarPopoverSections.order,
            [.portfolio, .watchlist, .goldForex, .marketIndices]
        )

        model.moveMenuBarPopoverSectionToTop(.marketIndices)
        XCTAssertEqual(
            model.menuBarPopoverSections.order,
            [.marketIndices, .portfolio, .watchlist, .goldForex]
        )

        model.setMenuBarPopoverSection(.portfolio, isHidden: true)
        XCTAssertTrue(model.menuBarPopoverSections.isHidden(.portfolio))
        XCTAssertFalse(
            model.menuBarPopoverSections.visibleSections.contains(.portfolio)
        )

        // 写方法落到 UserDefaults,重新 load 能还原。
        let reloaded = MenuBarPopoverSectionSettings.load()
        XCTAssertTrue(reloaded.isHidden(.portfolio))
        XCTAssertEqual(reloaded.order.first, .marketIndices)

        model.resetMenuBarPopoverSections()
        XCTAssertEqual(model.menuBarPopoverSections, .default)
    }

    // MARK: - Sina Quote Parsing

    func testParseGoldForexQuotesMapsHfSpotAndFxFields() {
        let client = QiemanPlatformNativeClient()
        let text = """
        var hq_str_hf_XAU="4609.36,4601.580,4609.36,4609.71,4613.31,4571.63,15:26:00,4601.58,4603.23,0,0,0,2026-08-28,伦敦金（现货黄金）";
        var hq_str_fx_susdcny="15:26:06,6.7197000000,6.7215000000,6.7249000000,121.0000000000,6.7108000000,6.7215000000,6.7094000000,6.7206000000,在岸人民币,-0.0639,-0.0043,0.0121,此行情由新浪财经计算得出,0.0000,0.0000,,2026-08-28";
        """

        let quotes = client.parseGoldForexQuotes(text: text)

        // hf_(伦敦金):最新 [0]、昨收 [7],涨跌额/率由两者推导。
        let gold = quotes[.xauUSD]
        XCTAssertNotNil(gold)
        XCTAssertEqual(gold?.price ?? 0, 4609.36, accuracy: 0.0001)
        XCTAssertEqual(gold?.previousClose ?? 0, 4601.58, accuracy: 0.0001)
        XCTAssertEqual(gold?.changeAmount ?? 0, 7.78, accuracy: 0.01)
        XCTAssertEqual(gold?.changePct ?? 0, 0.17, accuracy: 0.01)
        XCTAssertEqual(gold?.name, "伦敦金（现货黄金）")
        XCTAssertEqual(gold?.quotedAt, "2026-08-28 15:26:00")

        // fx_(在岸人民币):最新 [8]、昨收 [3],涨跌率 [10]、涨跌额 [11] 直接采用返回值。
        let cny = quotes[.usdCNY]
        XCTAssertNotNil(cny)
        XCTAssertEqual(cny?.price ?? 0, 6.7206, accuracy: 0.00005)
        XCTAssertEqual(cny?.previousClose ?? 0, 6.7249, accuracy: 0.00005)
        XCTAssertEqual(cny?.changePct ?? 0, -0.0639, accuracy: 0.0001)
        XCTAssertEqual(cny?.changeAmount ?? 0, -0.0043, accuracy: 0.0001)
        XCTAssertEqual(cny?.name, "在岸人民币")
        XCTAssertEqual(cny?.quotedAt, "2026-08-28 15:26:06")

        // 未出现在文本中的标的不产生条目。
        XCTAssertNil(quotes[.xagUSD])
        XCTAssertNil(quotes[.usdCNH])
    }

    func testParseGoldForexQuotesIgnoresMalformedLines() {
        let client = QiemanPlatformNativeClient()
        let text = """
        var hq_str_fx_susdcnh="15:26:33,6.721600,6.721700,6.718500,61,6.718500,6.722300,6.716200,6.721600,离岸人民币（香港）,0.050000,0.003100,0.0009079,,6.995700,6.715000,,2026-08-28";
        var hq_str_hf_XAG="";
        """

        let quotes = client.parseGoldForexQuotes(text: text)

        XCTAssertEqual(quotes.count, 1)
        let cnh = quotes[.usdCNH]
        XCTAssertNotNil(cnh)
        XCTAssertEqual(cnh?.price ?? 0, 6.7216, accuracy: 0.00005)
        XCTAssertEqual(cnh?.changePct ?? 0, 0.05, accuracy: 0.001)
        XCTAssertEqual(cnh?.name, "离岸人民币（香港）")
    }
}
