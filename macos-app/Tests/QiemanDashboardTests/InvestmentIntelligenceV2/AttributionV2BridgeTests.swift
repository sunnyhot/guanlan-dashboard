import XCTest
@testable import QiemanDashboard

/// ATTR-5 桥接层测试：UserPortfolioAttributionProvider 把用户组合快照
/// 喂进 V2 归因 workflow 的端到端语义（不依赖 AppModel——桥接 computed
/// 只有一行，provider 覆盖全部转换逻辑）。
final class AttributionV2BridgeTests: XCTestCase {

    // MARK: - fixture

    private func row(
        code: String, assetType: PersonalAssetType, marketValue: Double?,
        changePct: Double?
    ) -> UserPortfolioValuationRow {
        UserPortfolioValuationRow(
            holding: UserPortfolioHolding(
                fundCode: code, assetType: assetType, units: 100,
                costPrice: 1, displayName: code
            ),
            fundName: code,
            currentPrice: nil, priceTime: nil, priceSource: nil,
            officialNav: nil, officialNavDate: nil,
            estimatePrice: nil, estimatePriceTime: nil,
            marketValue: marketValue, costValue: nil,
            profitAmount: nil, profitPct: nil,
            estimateChangePct: changePct
        )
    }

    private func snapshot(rows: [UserPortfolioValuationRow]) -> UserPortfolioSnapshot {
        UserPortfolioSnapshot(
            rows: rows,
            refreshedAt: "2024-07-20 15:00",
            totalMarketValue: rows.compactMap(\.marketValue).reduce(0, +),
            totalCostValue: nil, totalProfitAmount: nil, totalProfitPct: nil
        )
    }

    private func run(_ snapshot: UserPortfolioSnapshot) -> DailyAttributionWorkflow.RunOutcome {
        DailyAttributionWorkflow(provider: UserPortfolioAttributionProvider(snapshot: snapshot))
            .run(portfolioKey: "app:userPortfolio", on: Date(timeIntervalSince1970: 1_700_000_000), now: Date())
    }

    // MARK: - 供货语义

    func testProviderSuppliesWeightsAndReturns() throws {
        // A(基金,市值 600,+10%)+ B(股票,市值 400,−5%)
        let outcome = run(snapshot(rows: [
            row(code: "110022", assetType: .fund, marketValue: 600, changePct: 10),
            row(code: "600519", assetType: .stock, marketValue: 400, changePct: -5),
        ]))
        XCTAssertTrue(outcome.succeeded)

        let result = try XCTUnwrap(outcome.artifact).result
        XCTAssertEqual(result.coverage.value, 1)
        XCTAssertEqual(result.attributedReturn.value, Decimal(string: "0.04"), "0.6×0.1 + 0.4×(−0.05)")
        XCTAssertEqual(result.contributions.count, 2)
        XCTAssertEqual(result.contributions[0].subject, .fund(FundProductID(rawValue: "110022")))
        XCTAssertEqual(result.contributions[1].subject, .listing(ListingID(rawValue: "600519")))
    }

    func testRowsWithoutMarketValueExcluded() throws {
        // 无市值的行无法加权:不进 positions(不猜权重)
        let provider = UserPortfolioAttributionProvider(snapshot: snapshot(rows: [
            row(code: "A", assetType: .fund, marketValue: 600, changePct: 2),
            row(code: "B", assetType: .fund, marketValue: nil, changePct: 3),
        ]))
        let positions = try provider.positions(portfolioKey: "app:userPortfolio", on: Date())
        XCTAssertEqual(positions.map { $0.subject.stableKey }, ["fund|A"], "无市值行被排除")
    }

    func testUnknownChangePctEntersCoverageGap() throws {
        // 涨跌未公布的行:进 positions 但 periodReturn nil → coverage 缺口
        let outcome = run(snapshot(rows: [
            row(code: "A", assetType: .fund, marketValue: 600, changePct: 10),
            row(code: "B", assetType: .fund, marketValue: 400, changePct: nil),
        ]))
        let result = try XCTUnwrap(outcome.artifact).result
        XCTAssertEqual(result.coverage.value, Decimal(string: "0.6"))
        XCTAssertEqual(result.unattributedWeight.value, Decimal(string: "0.4"))
        XCTAssertEqual(result.contributions.count, 1)
        XCTAssertEqual(outcome.rendered?.grade, .partial, "60% 覆盖 → PARTIAL 措辞")
    }

    func testPortfolioReturnFeedsResidual() throws {
        // dailyChangeSummary.pct 来自行的加权(known rows):
        // A 市值 600 +10% → summary pct ≈ 10(单行全覆盖)
        let outcome = run(snapshot(rows: [
            row(code: "A", assetType: .fund, marketValue: 600, changePct: 10),
        ]))
        let result = try XCTUnwrap(outcome.artifact).result
        XCTAssertNotNil(result.residual, "组合实际收益可用 → residual 产出")
        XCTAssertEqual(result.residual?.value ?? 0, 0, accuracy: Decimal(string: "0.0000000001")!)
    }

    func testEmptySnapshotFailsJobNotCrash() {
        let outcome = run(snapshot(rows: []))
        XCTAssertEqual(outcome.job.state, .failed, "空组合 → job failed(不是崩溃)")
        XCTAssertNotNil(outcome.errorDetail)
    }

    // MARK: - residual 口径(审查 P1-8)

    func testResidualWithheldWhenCoverageIncomplete() throws {
        // 涨跌未全覆盖:B 行无 changePct → portfolioReturn 不提供 → residual nil
        let outcome = run(snapshot(rows: [
            row(code: "A", assetType: .fund, marketValue: 600, changePct: 10),
            row(code: "B", assetType: .fund, marketValue: 400, changePct: nil),
        ]))
        let result = try XCTUnwrap(outcome.artifact).result
        XCTAssertNil(result.residual, "涨跌覆盖不完整时 dailyChangeSummary 只是子集收益,不能当全组合 residual 基准")
        XCTAssertEqual(result.coverage.value, Decimal(string: "0.6"))

        // 估值缺失(无市值行)同样阻断
        let noValuation = run(snapshot(rows: [
            row(code: "A", assetType: .fund, marketValue: 600, changePct: 10),
            row(code: "B", assetType: .fund, marketValue: nil, changePct: 5),
        ]))
        XCTAssertNil(try XCTUnwrap(noValuation.artifact).result.residual)
    }

    func testResidualProvidedOnlyAtFullCoverage() throws {
        // 全覆盖(全部有市值 + 全部有涨跌)→ residual 产出
        let outcome = run(snapshot(rows: [
            row(code: "A", assetType: .fund, marketValue: 600, changePct: 10),
            row(code: "B", assetType: .fund, marketValue: 400, changePct: -5),
        ]))
        let result = try XCTUnwrap(outcome.artifact).result
        XCTAssertNotNil(result.residual, "全覆盖时 residual 正常产出")
    }

    // MARK: - 渲染端到端

    func testRenderedOutputForDisplay() throws {
        let outcome = run(snapshot(rows: [
            row(code: "110022", assetType: .fund, marketValue: 600, changePct: 10),
            row(code: "600519", assetType: .stock, marketValue: 400, changePct: -5),
        ]))
        let rendered = try XCTUnwrap(outcome.rendered)
        XCTAssertEqual(rendered.grade, .high)
        XCTAssertTrue(rendered.headline.contains("基金 110022"), "主要贡献是 A(+6%)")
        XCTAssertTrue(rendered.headline.contains("+6%"))
        XCTAssertEqual(rendered.contributionLines.count, 2)
        XCTAssertNotNil(rendered.caveat)
    }
}
