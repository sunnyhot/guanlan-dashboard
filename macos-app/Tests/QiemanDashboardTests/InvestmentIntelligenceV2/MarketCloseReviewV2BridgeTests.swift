import XCTest
@testable import QiemanDashboard

// MARK: - 收盘复盘 App 桥装配测试（审计 A1）
//
// 纯函数面：明日关注组装（决策事项 > 目标偏差 > 盘中结论）与市场摘要
// 组装（指数行情 + 发现候选）。

final class MarketCloseReviewV2BridgeTests: XCTestCase {

    func testAssembleTomorrowWatchOrdering() {
        let decisionCase = DecisionCase(
            caseKey: "concentrationRisk|directHolding|000001",
            kind: .concentrationRisk,
            dimension: .directHolding,
            subjectName: "基金A",
            subjectCode: "000001",
            lifecycle: .monitoring,
            decisionState: .watch,
            metricValue: 40,
            metricLabel: "40.0%",
            metricDescription: "第一大持仓占比",
            title: "单一持仓集中：基金A",
            detail: "",
            createdAt: Date())
        let rows = AssetClass.allCases.map { assetClass in
            InvestmentIntelligenceDashboardSnapshot.AllocationSummary.Row(
                assetClass: assetClass,
                currentWeight: assetClass == .equity ? Decimal(string: "0.62")! : nil,
                targetWeight: assetClass == .equity ? Decimal(string: "0.40")! : Decimal.zero,
                deviation: assetClass == .equity ? Decimal(string: "0.22")! : nil)
        }
        let watch = AppModel.assembleTomorrowWatch(
            decisionCases: [decisionCase],
            allocationRows: rows,
            intraday: nil)
        XCTAssertEqual(watch.count, 2)
        XCTAssertTrue(watch[0].contains("基金A"), "决策事项优先")
        XCTAssertTrue(watch[1].contains("股票"), "大偏差次之")
    }

    func testAssembleTomorrowWatchCapsAtThree() {
        let cases = (0..<4).map { index in
            DecisionCase(
                caseKey: "k\(index)",
                kind: .drawdownExpansion,
                dimension: .directHolding,
                subjectName: "标的\(index)",
                subjectCode: "C\(index)",
                lifecycle: .monitoring,
                decisionState: .prepare,
                metricValue: 20,
                metricLabel: "20.0%",
                metricDescription: "回撤",
                title: "回撤扩大：标的\(index)",
                detail: "",
                createdAt: Date())
        }
        let watch = AppModel.assembleTomorrowWatch(
            decisionCases: cases, allocationRows: [], intraday: nil)
        XCTAssertEqual(watch.count, 2, "决策事项取前 2（无偏差/盘中时总数 ≤3）")
    }

    func testAssembleTomorrowWatchIntradayConclusion() {
        let intraday = InvestmentIntelligenceDashboardSnapshot.IntradaySummary(
            decision: .executeRebalance,
            holdReasons: [],
            moves: [],
            validity: .current,
            producedAt: Date(),
            artifactID: "itd_x",
            targetID: nil)
        let watch = AppModel.assembleTomorrowWatch(
            decisionCases: [], allocationRows: [], intraday: intraday)
        XCTAssertEqual(watch.count, 1)
        XCTAssertTrue(watch[0].contains("再平衡"))
    }

    func testAssembleMarketDigest() {
        var quotes: [MarketIndexKind: MarketIndexQuote] = [:]
        quotes[.csi300] = MarketIndexQuote(
            kind: .csi300, name: "沪深300", price: 4000,
            previousClose: 3952, changeAmount: 48, changePct: 1.21,
            quotedAt: "2026-08-27 15:00", sourceLabel: "测试")
        let digest = AppModel.assembleMarketDigest(
            indexQuotes: quotes, candidates: [])
        XCTAssertEqual(digest.count, 1)
        XCTAssertEqual(digest[0].kind, "index")
        XCTAssertEqual(digest[0].changePct ?? 0, 1.21, accuracy: 0.001)
    }
}
