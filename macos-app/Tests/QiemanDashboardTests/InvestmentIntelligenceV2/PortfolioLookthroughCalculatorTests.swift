import XCTest
@testable import QiemanDashboard

/// EXP-1 单元测试：PortfolioLookthroughCalculator（V2 全新穿透计算）。
///
/// 等价旧实现（Core/FundLookThrough）的计算场景（旧抓取/缓存/重试场景
/// 属 Epic 4/6 Provider 层，不在本计算器范围）：
/// - 跨基金同标的合并 + 直接持股并入
/// - coverage 三级（fundData / disclosedSecurity / unknown）
/// - 资产大类聚合（AllocationSnapshot 通道）
/// - missing / stale 披露警告
/// 超越部分：上下界（最坏情况归因）、行业可选维度、Artifact conformance。
final class PortfolioLookthroughCalculatorTests: XCTestCase {

    // MARK: - 测试基建

    private let asOf = PortfolioLookthroughCalculatorTests.date(2024, 7, 20)
    private func producedAt() -> Date { Self.date(2024, 7, 20) }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.startOfDay(for: cal.date(from: DateComponents(year: y, month: m, day: d))!)
    }

    private func envelope(effective: Date) -> TemporalEnvelope {
        TemporalEnvelope(
            effectiveAt: effective, publishedAt: effective,
            availableAt: effective, ingestedAt: effective
        )
    }

    private func makeProv() -> AvailabilityProvenance {
        AvailabilityProvenance(policyID: "fund_disclosure", policyVersion: "v1", derivedAt: Self.date(2024, 1, 1))
    }

    /// 构造 FundHoldingSnapshot：positions 按 (listing, weight) 列表。
    private func holding(
        id: String, product: String, effective: Date,
        positions: [(String, String)], disclosedTotal: String? = nil,
        period: FundHoldingSnapshot.ReportPeriod = .q2
    ) -> FundHoldingSnapshot {
        let resolved: [(String, Decimal)] = positions.map {
            ($0.0, Decimal(string: $0.1) ?? Decimal.zero)
        }
        return FundHoldingSnapshot(
            id: ObservationID(rawValue: id),
            productID: FundProductID(rawValue: product),
            temporalEnvelope: envelope(effective: effective),
            availabilityProvenance: makeProv(),
            dataQuality: .from(.communityAggregated, providerID: .eastmoney),
            vintage: Vintage(announcementDate: effective, publisherVersion: 1),
            reportPeriod: period,
            positions: resolved.map {
                FundHoldingPosition(
                    listingID: ListingID(rawValue: $0.0),
                    weight: Ratio(value: $0.1), shares: nil, marketValue: nil,
                    isDisclosed: true
                )
            },
            disclosedWeightTotal: Ratio(value: disclosedTotal.map { Decimal(string: $0)! }
                ?? resolved.map(\.1).reduce(Decimal.zero, +))
        )
    }

    /// 构造 AllocationSnapshot。
    private func allocation(
        id: String, product: String, effective: Date,
        entries: [(AssetClass, String)]
    ) -> AllocationSnapshot {
        AllocationSnapshot(
            id: ObservationID(rawValue: id),
            productID: FundProductID(rawValue: product),
            temporalEnvelope: envelope(effective: effective),
            availabilityProvenance: makeProv(),
            dataQuality: .from(.communityAggregated, providerID: .eastmoney),
            vintage: Vintage(announcementDate: effective, publisherVersion: 1),
            reportPeriod: .q2,
            allocations: entries.map {
                AllocationSnapshot.AllocationEntry(
                    assetClass: $0.0, ratio: Ratio(value: Decimal(string: $0.1)!))
            }
        )
    }

    // MARK: - 核心场景（等价旧 testCalculatorMergesSameUnderlyingSecurityAcrossFunds）

    func testMergesSameUnderlyingAcrossFundsAndDirectHolding() {
        // 组合：基金 A 60% + 基金 B 30% + 直接持股 10%
        // A 披露 {300308: 20%, 600519: 80%}；B 披露 {300308: 10%}
        // 穿透：300308 = 60%×20% + 30%×10% = 15%；600519 = 48%；直接 L9 = 10%
        let calc = PortfolioLookthroughCalculator()
        let snap = calc.compute(
            positions: [
                .init(weight: Ratio(value: Decimal(string: "0.6")!), fundProductID: FundProductID(rawValue: "A")),
                .init(weight: Ratio(value: Decimal(string: "0.3")!), fundProductID: FundProductID(rawValue: "B")),
                .init(weight: Ratio(value: Decimal(string: "0.1")!), directListingID: ListingID(rawValue: "L9")),
            ],
            disclosures: [
                .init(
                    productID: FundProductID(rawValue: "A"),
                    holding: holding(id: "hA", product: "A", effective: Self.date(2024, 6, 30),
                                     positions: [("300308", "0.2"), ("600519", "0.8")]),
                    allocation: nil
                ),
                .init(
                    productID: FundProductID(rawValue: "B"),
                    holding: holding(id: "hB", product: "B", effective: Self.date(2024, 6, 30),
                                     positions: [("300308", "0.1")]),
                    allocation: nil
                ),
            ],
            asOf: asOf, producedAt: producedAt()
        )

        XCTAssertNotNil(snap)
        let positions = snap!.underlyingPositions
        XCTAssertEqual(positions.map(\.listingID.rawValue), ["600519", "300308", "L9"], "权重降序")
        XCTAssertEqual(positions[1].weight.value, Decimal(string: "0.15"))
        XCTAssertEqual(positions[0].weight.value, Decimal(string: "0.48"))
        XCTAssertEqual(positions[2].weight.value, Decimal(string: "0.1"))

        // 300308 的贡献者：A(0.12) > B(0.03)，均非直接持股
        let contributors = positions[1].contributors
        XCTAssertEqual(contributors.count, 2)
        XCTAssertEqual(contributors[0].fundProductID, FundProductID(rawValue: "A"))
        XCTAssertEqual(contributors[0].contribution.value, Decimal(string: "0.12"))
        XCTAssertEqual(contributors[1].contribution.value, Decimal(string: "0.03"))
        // L9 是直接持股（fundProductID nil）
        XCTAssertEqual(positions[2].contributors.first?.isDirectHolding, true)
        XCTAssertNil(positions[2].contributors.first?.fundProductID)
    }

    func testCoverageThreeLevels() {
        // 基金 A 50%（披露 80% 明细）+ 基金 B 30%（无披露）+ 直接持股 20%
        // fundDataCoverage = 50%；disclosedSecurity = 50%×80% + 20% = 60%；unknown = 40%
        let calc = PortfolioLookthroughCalculator()
        let snap = calc.compute(
            positions: [
                .init(weight: Ratio(value: Decimal(string: "0.5")!), fundProductID: FundProductID(rawValue: "A")),
                .init(weight: Ratio(value: Decimal(string: "0.3")!), fundProductID: FundProductID(rawValue: "B")),
                .init(weight: Ratio(value: Decimal(string: "0.2")!), directListingID: ListingID(rawValue: "L1")),
            ],
            disclosures: [
                .init(
                    productID: FundProductID(rawValue: "A"),
                    holding: holding(id: "hA", product: "A", effective: Self.date(2024, 6, 30),
                                     positions: [("X", "0.5"), ("Y", "0.3")], disclosedTotal: "0.8"),
                    allocation: nil
                ),
                .init(productID: FundProductID(rawValue: "B"), holding: nil, allocation: nil),
            ],
            asOf: asOf, producedAt: producedAt()
        )!

        XCTAssertEqual(snap.fundCount, 2)
        XCTAssertEqual(snap.coveredFundCount, 1)
        XCTAssertEqual(snap.fundDataCoverage.value, Decimal(string: "0.5"))
        XCTAssertEqual(snap.disclosedSecurityCoverage.value, Decimal(string: "0.6"))
        XCTAssertEqual(snap.unknownPortfolioWeight.value, Decimal(string: "0.4"))
        XCTAssertTrue(snap.metricsSumTolerance())
    }

    func testUpperBoundWorstCaseAttribution() {
        // unknown = 0.4（上例）：每标的 / 类别上界 = point + 0.4
        let calc = PortfolioLookthroughCalculator()
        let snap = calc.compute(
            positions: [
                .init(weight: Ratio(value: Decimal(string: "0.5")!), fundProductID: FundProductID(rawValue: "A")),
                .init(weight: Ratio(value: Decimal(string: "0.5")!), fundProductID: FundProductID(rawValue: "B")),
            ],
            disclosures: [
                .init(
                    productID: FundProductID(rawValue: "A"),
                    holding: holding(id: "hA", product: "A", effective: Self.date(2024, 6, 30),
                                     positions: [("X", "0.6")], disclosedTotal: "0.6"),
                    allocation: allocation(id: "alA", product: "A", effective: Self.date(2024, 6, 30),
                                           entries: [(.equity, "0.6")])
                ),
                .init(productID: FundProductID(rawValue: "B"), holding: nil, allocation: nil),
            ],
            asOf: asOf, producedAt: producedAt()
        )!

        // 证券维：X point = 0.3，unknown = 0.4×0.5+0.5 = 0.7？不对——
        // A 披露 60% → unknown_A = 0.5×0.4 = 0.2；B 无披露 → 0.5；
        // total unknown = 0.7？ disclosedSecurityCoverage = 0.5×0.6 = 0.3 → unknown = 0.7 ✓
        let x = snap.underlyingPositions.first { $0.listingID.rawValue == "X" }!
        XCTAssertEqual(x.weight.value, Decimal(string: "0.3"))
        XCTAssertEqual(x.lowerBound.value, Decimal(string: "0.3"))
        XCTAssertEqual(x.upperBound.value, Decimal(string: "1.0"), "最坏情况：全部 unknown 都可能是 X")

        // 资产大类维：equity confirmed = 0.5×0.6 = 0.3；
        // AC 维 unknown = B 整体 0.5 + A allocation 内部缺口 0.5×0.4 = 0.7
        let equity = snap.assetClassExposures.first { $0.assetClass == .equity }!
        XCTAssertEqual(equity.confirmedWeight.value, Decimal(string: "0.3"))
        XCTAssertEqual(equity.upperBoundWeight.value, Decimal(string: "1.0"))
    }

    // MARK: - 资产大类聚合（等价旧场景）

    func testAssetClassAggregation_fromAllocationsAndDirect() {
        // A(50%) allocation: equity 90% / cash 10%；B(30%) allocation: fixedIncome 100%；
        // 直接持股 20% equity
        let calc = PortfolioLookthroughCalculator()
        let snap = calc.compute(
            positions: [
                .init(weight: Ratio(value: Decimal(string: "0.5")!), fundProductID: FundProductID(rawValue: "A")),
                .init(weight: Ratio(value: Decimal(string: "0.3")!), fundProductID: FundProductID(rawValue: "B")),
                .init(weight: Ratio(value: Decimal(string: "0.2")!), directListingID: ListingID(rawValue: "L1"), directAssetClass: .equity),
            ],
            disclosures: [
                .init(productID: FundProductID(rawValue: "A"), holding: nil,
                      allocation: allocation(id: "alA", product: "A", effective: Self.date(2024, 6, 30),
                                             entries: [(.equity, "0.9"), (.cash, "0.1")])),
                .init(productID: FundProductID(rawValue: "B"), holding: nil,
                      allocation: allocation(id: "alB", product: "B", effective: Self.date(2024, 6, 30),
                                             entries: [(.fixedIncome, "1.0")])),
            ],
            asOf: asOf, producedAt: producedAt()
        )!

        let classes = snap.assetClassExposures
        XCTAssertEqual(classes.map(\.assetClass), [.equity, .fixedIncome, .cash], "confirmed 降序")
        XCTAssertEqual(classes[0].confirmedWeight.value, Decimal(string: "0.65"))  // 0.45 + 0.2
        XCTAssertEqual(classes[1].confirmedWeight.value, Decimal(string: "0.3"))
        XCTAssertEqual(classes[2].confirmedWeight.value, Decimal(string: "0.05"))
        // 全部 allocation 完整 + direct 有大类 → AC 维 unknown = 0 → 上界 = 点值
        XCTAssertTrue(classes.allSatisfy { $0.upperBoundWeight == $0.confirmedWeight })
    }

    // MARK: - missing / stale（等价旧 testCalculatorReportsMissingAndStaleDisclosure）

    func testMissingAndStaleDisclosureWarnings() {
        // A 披露 2023-12-31（距 2024-07-20 = 202 天 > 150 → stale）
        // B 无披露 → missing
        let calc = PortfolioLookthroughCalculator()
        let snap = calc.compute(
            positions: [
                .init(weight: Ratio(value: Decimal(string: "0.5")!), fundProductID: FundProductID(rawValue: "A")),
                .init(weight: Ratio(value: Decimal(string: "0.5")!), fundProductID: FundProductID(rawValue: "B")),
            ],
            disclosures: [
                .init(
                    productID: FundProductID(rawValue: "A"),
                    holding: holding(id: "hA", product: "A", effective: Self.date(2023, 12, 31),
                                     positions: [("X", "1.0")]),
                    allocation: nil
                ),
                .init(productID: FundProductID(rawValue: "B"), holding: nil, allocation: nil),
            ],
            asOf: asOf, producedAt: producedAt()
        )!

        let staleWarnings = snap.warnings.compactMap { w -> (String, Int, Int)? in
            if case let .staleDisclosure(productID, age, limit) = w { return (productID.rawValue, age, limit) }
            return nil
        }
        XCTAssertEqual(staleWarnings.count, 1)
        XCTAssertEqual(staleWarnings.first?.0, "A")
        XCTAssertEqual(staleWarnings.first?.1, 202)
        XCTAssertEqual(staleWarnings.first?.2, 150)

        let missing = snap.warnings.compactMap { w -> String? in
            if case let .missingDisclosure(productID, _) = w { return productID.rawValue }
            return nil
        }
        XCTAssertEqual(missing, ["B"])
        XCTAssertTrue(snap.warnings.contains(.disclosureDisclaimer))

        // stale 仍参与计算（fundDataCoverage 含 A）
        XCTAssertEqual(snap.fundDataCoverage.value, Decimal(string: "0.5"))
        XCTAssertEqual(snap.fundSummaries.first { $0.productID.rawValue == "A" }?.isStale, true)
    }

    // MARK: - 行业维度（可选输入）

    func testIndustryAggregation_optionalSectorInput() {
        let sectors: [ListingID: SectorClassification] = [
            ListingID(rawValue: "X"): .init(label: "制造业", classificationSystem: "申万"),
            ListingID(rawValue: "Y"): .init(label: "信息技术", classificationSystem: "申万"),
        ]
        let calc = PortfolioLookthroughCalculator(parameters: .init(sectorClassifications: sectors))
        let snap = calc.compute(
            positions: [
                .init(weight: Ratio(value: Decimal(string: "1.0")!), fundProductID: FundProductID(rawValue: "A")),
            ],
            disclosures: [
                .init(
                    productID: FundProductID(rawValue: "A"),
                    holding: holding(id: "hA", product: "A", effective: Self.date(2024, 6, 30),
                                     positions: [("X", "0.4"), ("Y", "0.3"), ("Z", "0.3")]),
                    allocation: nil
                ),
            ],
            asOf: asOf, producedAt: producedAt()
        )!

        let industries = snap.industryExposures
        XCTAssertEqual(industries.map(\.label), ["制造业", "信息技术"])
        XCTAssertEqual(industries[0].confirmedWeight.value, Decimal(string: "0.4"))
        XCTAssertEqual(industries[0].classificationSystem, "申万")
        // Z 无分类 + 披露缺口 0 → 行业维 unknown = 0.3 → 上界 = 0.7
        XCTAssertEqual(industries[0].upperBoundWeight.value, Decimal(string: "0.7"))
    }

    func testIndustryEmptyWhenNoSectorInput() {
        let calc = PortfolioLookthroughCalculator()
        let snap = calc.compute(
            positions: [.init(weight: Ratio(value: 1), fundProductID: FundProductID(rawValue: "A"))],
            disclosures: [
                .init(productID: FundProductID(rawValue: "A"),
                      holding: holding(id: "hA", product: "A", effective: Self.date(2024, 6, 30),
                                       positions: [("X", "1.0")]),
                      allocation: nil),
            ],
            asOf: asOf, producedAt: producedAt()
        )!
        XCTAssertTrue(snap.industryExposures.isEmpty)
    }

    // MARK: - Artifact / 确定性 / Codable

    func testArtifactConformanceAndDependencies() {
        let inputs = makeTwoFundInputs()
        let snap = PortfolioLookthroughCalculator().compute(
            positions: inputs.positions, disclosures: inputs.disclosures,
            asOf: asOf, producedAt: producedAt()
        )!
        XCTAssertEqual(snap.validityPolicy, .untilDependencyChanges)
        XCTAssertEqual(snap.calculatorVersion, "v1")
        // dependencies 与参与 observation 一一对应（holding + allocation）
        XCTAssertEqual(snap.dependencies.map(\.referenceID).sorted(), ["hA", "hB"])
        XCTAssertTrue(snap.dependencies.allSatisfy { $0.kind == .observation })
    }

    func testDeterministicIdAndRecomputation() {
        let inputs = makeTwoFundInputs()
        let a = PortfolioLookthroughCalculator().compute(
            positions: inputs.positions, disclosures: inputs.disclosures,
            asOf: asOf, producedAt: producedAt()
        )!
        let b = PortfolioLookthroughCalculator().compute(
            positions: inputs.positions, disclosures: inputs.disclosures,
            asOf: asOf, producedAt: producedAt()
        )!
        XCTAssertEqual(a, b, "同输入同输出（重算幂等）")
        XCTAssertEqual(a.id, b.id)

        // asOf 变化 → id 变化（历史快照不互相覆盖）
        let c = PortfolioLookthroughCalculator().compute(
            positions: inputs.positions, disclosures: inputs.disclosures,
            asOf: asOf.addingTimeInterval(86400), producedAt: producedAt()
        )!
        XCTAssertNotEqual(a.id, c.id)
    }

    func testCodableRoundTrip() throws {
        let inputs = makeTwoFundInputs()
        let snap = PortfolioLookthroughCalculator().compute(
            positions: inputs.positions, disclosures: inputs.disclosures,
            asOf: asOf, producedAt: producedAt()
        )!
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(LookthroughSnapshot.self, from: data)
        XCTAssertEqual(decoded, snap)
    }

    func testEmptyOrZeroWeightPortfolioReturnsNil() {
        let calc = PortfolioLookthroughCalculator()
        XCTAssertNil(calc.compute(positions: [], disclosures: [], asOf: asOf, producedAt: producedAt()))
        XCTAssertNil(calc.compute(
            positions: [.init(weight: Ratio(value: 0), fundProductID: FundProductID(rawValue: "A"))],
            disclosures: [], asOf: asOf, producedAt: producedAt()
        ))
    }

    func testWeightNormalization() {
        // 输入权重不必和为 1：50/30（和 80）按比例归一
        let calc = PortfolioLookthroughCalculator()
        let snap = calc.compute(
            positions: [
                .init(weight: Ratio(value: Decimal(string: "50")!), fundProductID: FundProductID(rawValue: "A")),
                .init(weight: Ratio(value: Decimal(string: "30")!), fundProductID: FundProductID(rawValue: "B")),
            ],
            disclosures: [
                .init(productID: FundProductID(rawValue: "A"),
                      holding: holding(id: "hA", product: "A", effective: Self.date(2024, 6, 30),
                                       positions: [("X", "1.0")]),
                      allocation: nil),
                .init(productID: FundProductID(rawValue: "B"),
                      holding: holding(id: "hB", product: "B", effective: Self.date(2024, 6, 30),
                                       positions: [("X", "1.0")]),
                      allocation: nil),
            ],
            asOf: asOf, producedAt: producedAt()
        )!
        // X = 0.625 + 0.375 = 1.0（满仓单一标的）
        XCTAssertEqual(snap.underlyingPositions.first?.weight.value, 1)
        XCTAssertEqual(snap.underlyingPositions.first?.contributors.count, 2)
    }

    // MARK: - helpers

    private struct TwoFundInputs {
        let positions: [LookthroughPositionInput]
        let disclosures: [FundDisclosureInput]
    }

    private func makeTwoFundInputs() -> TwoFundInputs {
        TwoFundInputs(
            positions: [
                .init(weight: Ratio(value: Decimal(string: "0.6")!), fundProductID: FundProductID(rawValue: "A")),
                .init(weight: Ratio(value: Decimal(string: "0.4")!), fundProductID: FundProductID(rawValue: "B")),
            ],
            disclosures: [
                .init(
                    productID: FundProductID(rawValue: "A"),
                    holding: holding(id: "hA", product: "A", effective: Self.date(2024, 6, 30),
                                     positions: [("300308", "0.2")]),
                    allocation: nil
                ),
                .init(
                    productID: FundProductID(rawValue: "B"),
                    holding: holding(id: "hB", product: "B", effective: Self.date(2024, 6, 30),
                                     positions: [("300308", "0.5")]),
                    allocation: nil
                ),
            ]
        )
    }
}

// MARK: - 测试用一致性断言 helper

private extension LookthroughSnapshot {
    /// disclosedSecurityCoverage + unknownPortfolioWeight ≈ 1 的守门断言
    /// （直接持股全披露时成立；返回值恒 true，失败靠 XCTAssert 抛出）。
    func metricsSumTolerance() -> Bool {
        let sum = disclosedSecurityCoverage.value + unknownPortfolioWeight.value
        XCTAssertTrue(abs(sum - 1) < Decimal(string: "0.000000000001")!, "coverage 与 unknown 互补")
        return true
    }
}
