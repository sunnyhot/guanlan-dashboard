import Foundation
import XCTest
@testable import QiemanDashboard

final class PlatformHoldingAllocationTests: XCTestCase {
    func testAllocationGroupsHoldingsByLargeAssetClassAndUsesCurrentUnits() throws {
        let holdings = try JSONDecoder().decode(
            [HoldingItemPayload].self,
            from: Data(
                """
                [
                  {"assetKey":"equity-a","largeClass":"权益","currentUnits":3},
                  {"assetKey":"equity-b","largeClass":"权益","currentUnits":1},
                  {"assetKey":"bond-a","largeClass":"债券","currentUnits":6}
                ]
                """.utf8
            )
        )

        let allocations = PlatformHoldingAllocationBuilder.make(holdings: holdings)

        XCTAssertEqual(allocations.map(\.label), ["债券", "权益"])
        XCTAssertEqual(allocations.map(\.assetCount), [1, 2])
        XCTAssertEqual(allocations.map(\.value), [6, 4])
        XCTAssertEqual(allocations[0].ratio, 0.6, accuracy: 0.0001)
        XCTAssertEqual(allocations[1].ratio, 0.4, accuracy: 0.0001)
    }

    func testAllocationExcludesEmptyPositions() throws {
        let holdings = try JSONDecoder().decode(
            [HoldingItemPayload].self,
            from: Data(
                """
                [
                  {"assetKey":"commodity","largeClass":"商品","currentUnits":5},
                  {"assetKey":"cash","largeClass":"现金","currentUnits":0},
                  {"assetKey":"empty","largeClass":"其他"}
                ]
                """.utf8
            )
        )

        let allocations = PlatformHoldingAllocationBuilder.make(holdings: holdings)

        XCTAssertEqual(allocations.map(\.label), ["商品"])
        XCTAssertEqual(allocations.map(\.value), [5])
    }

    func testAssetTypeAllocationCombinesRegionalEquitiesAndBonds() throws {
        let holdings = try JSONDecoder().decode(
            [HoldingItemPayload].self,
            from: Data(
                """
                [
                  {"assetKey":"a-share","largeClass":"A股","currentUnits":30},
                  {"assetKey":"overseas-equity","largeClass":"海外新兴市场股票","currentUnits":20},
                  {"assetKey":"domestic-bond","largeClass":"境内债券","currentUnits":12},
                  {"assetKey":"overseas-bond","largeClass":"海外债券","currentUnits":8},
                  {"assetKey":"gold","largeClass":"黄金商品","currentUnits":5}
                ]
                """.utf8
            )
        )

        let allocations = PlatformHoldingAllocationBuilder.make(
            holdings: holdings,
            dimension: .assetType
        )

        XCTAssertEqual(allocations.map(\.label), ["股票", "债券", "商品"])
        XCTAssertEqual(allocations.map(\.assetCount), [2, 2, 1])
        XCTAssertEqual(allocations.map(\.value), [50, 20, 5])
        XCTAssertEqual(allocations[0].ratio, 2.0 / 3.0, accuracy: 0.0001)
    }
}
