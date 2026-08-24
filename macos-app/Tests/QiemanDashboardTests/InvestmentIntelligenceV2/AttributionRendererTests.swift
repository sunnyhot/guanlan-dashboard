import XCTest
@testable import QiemanDashboard

/// ATTR-3 单元测试：AttributionRenderer 的 coverage 分级措辞 +
/// LLM Narrative 补充层契约（只补叙述不改数字）。
final class AttributionRendererTests: XCTestCase {

    private func r(_ s: String) -> Ratio { Ratio(value: Decimal(string: s)!) }
    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    private func artifact(
        knownWeights: [(String, String, String)], // (key, weight, ret)
        unknownWeights: [(String, String)],        // (key, weight)
        portfolioReturn: String?
    ) -> DailyAttribution {
        var positions: [AttributionPositionInput] = knownWeights.map { key, w, ret in
            .init(subject: .fund(FundProductID(rawValue: key)), weight: r(w),
                  periodReturn: r(ret), sourceObservationID: ObservationID(rawValue: "obs_\(key)"))
        }
        positions.append(contentsOf: unknownWeights.map { key, w in
            .init(subject: .fund(FundProductID(rawValue: key)), weight: r(w), periodReturn: nil)
        })
        let result = AttributionEngine().compute(
            positions: positions, portfolioReturn: portfolioReturn.map { r($0) }
        )!
        return DailyAttribution(attributionDate: day, portfolioKey: "p1", result: result, producedAt: day)
    }

    // MARK: - coverage 分级边界(V2.2 §27)

    func testGradeBoundaries() {
        XCTAssertEqual(AttributionCoverageGrade.grade(coverage: Decimal(string: "1.0")!), .high)
        XCTAssertEqual(AttributionCoverageGrade.grade(coverage: Decimal(string: "0.8")!), .high, "0.8 属 high(≥80%)")
        XCTAssertEqual(AttributionCoverageGrade.grade(coverage: Decimal(string: "0.7999")!), .partial)
        XCTAssertEqual(AttributionCoverageGrade.grade(coverage: Decimal(string: "0.5")!), .partial, "0.5 属 partial(≥50%)")
        XCTAssertEqual(AttributionCoverageGrade.grade(coverage: Decimal(string: "0.4999")!), .low)
        XCTAssertEqual(AttributionCoverageGrade.grade(coverage: Decimal(string: "0")!), .low)
    }

    func testWordingEscalatesAsCoverageDrops() {
        let high = AttributionRenderer().render(artifact(
            knownWeights: [("A", "0.8", "0.01")], unknownWeights: [], portfolioReturn: nil
        ))
        XCTAssertEqual(high.grade, .high)
        XCTAssertTrue(high.caveat.contains("可直接引用"))

        let partial = AttributionRenderer().render(artifact(
            knownWeights: [("A", "0.5", "0.01")], unknownWeights: [("B", "0.5")], portfolioReturn: nil
        ))
        XCTAssertEqual(partial.grade, .partial)
        XCTAssertTrue(partial.caveat.contains("部分持仓当日数据缺失"))

        let low = AttributionRenderer().render(artifact(
            knownWeights: [("A", "0.3", "0.01")], unknownWeights: [("B", "0.7")], portfolioReturn: nil
        ))
        XCTAssertEqual(low.grade, .low)
        XCTAssertTrue(low.caveat.contains("不宜据此对整体收益下结论"), "低覆盖措辞必须弱化")
    }

    // MARK: - 渲染内容

    func testRenderNumbersComeFromArtifact() {
        // A 60% +10%,B 40% −5% → attributed = +0.04%
        let artifact = artifact(
            knownWeights: [("A", "0.6", "0.1"), ("B", "0.4", "-0.05")],
            unknownWeights: [], portfolioReturn: nil
        )
        let rendered = AttributionRenderer().render(artifact)
        XCTAssertTrue(rendered.headline.contains("+4%"))
        XCTAssertTrue(rendered.headline.contains("基金 A +6%"), "主要贡献在前")
        XCTAssertEqual(rendered.contributionLines.count, 2)
        XCTAssertTrue(rendered.contributionLines[1].contains("基金 B"))
        XCTAssertNil(rendered.residualNote)
        XCTAssertNil(rendered.narrative)
    }

    func testResidualNoteWhenPortfolioReturnProvided() {
        let artifact = artifact(
            knownWeights: [("A", "0.6", "0.1")], unknownWeights: [("B", "0.4")],
            portfolioReturn: "0.08"
        )
        let rendered = AttributionRenderer().render(artifact)
        // residual = 0.08 − 0.06 = +0.02
        XCTAssertEqual(rendered.residualNote, "组合实际收益与已归因部分之差 +2%（含未覆盖持仓的隐含贡献与估值口径差异）")
    }

    func testDeterministicNarrative() {
        // A 50% +2% + B 50% −2% → attributed = 0;portfolioReturn +1% → residual +1%
        let artifact = artifact(
            knownWeights: [("A", "0.5", "0.02"), ("B", "0.5", "-0.02")],
            unknownWeights: [], portfolioReturn: "0.01"
        )
        let text = AttributionRenderer().deterministicNarrative(artifact)
        XCTAssertTrue(text.contains("基金 A +1%"), "正贡献在前")
        XCTAssertTrue(text.contains("差 +1%"), "residual 0.01 − 0 = +1%")
        XCTAssertTrue(text.contains("可直接引用"), "coverage=100% → high 措辞")
    }

    // MARK: - LLM Narrative 契约(只补叙述不改数字)

    func testLLMNarrativeIsAppendOnlyAndNumbersUntouched() async {
        let artifact = artifact(
            knownWeights: [("A", "0.6", "0.1")], unknownWeights: [("B", "0.4")],
            portfolioReturn: nil
        )
        let summary = AttributionNarrativeSummary.summary(of: artifact)

        // 摘要是冻结快照:数字与 artifact 一致,LLM 只能看到这些
        XCTAssertEqual(summary.attributedReturn, Decimal(string: "0.06"))
        XCTAssertEqual(summary.coverage, Decimal(string: "0.6"))
        XCTAssertEqual(summary.topContributions.first?.subjectKey, "fund|A")
        XCTAssertEqual(summary.topContributions.first?.contribution, Decimal(string: "0.06"))

        // mock LLM:返回叙述(哪怕是「今天涨疯了 +99%」这样的胡话)
        struct MockLLM: AttributionNarrativeProvider {
            func narrative(for summary: AttributionNarrativeSummary) async -> String? {
                "市场情绪火热(叙述文本,可能胡说:组合其实 +99%)"
            }
        }
        let renderer = AttributionRenderer()
        let base = renderer.render(artifact)
        let narrative = await MockLLM().narrative(for: summary)
        let withLLM = base.withNarrative(narrative)

        // 数字字段与 base 完全一致:narrative 只能整体附加,接触不到数字
        XCTAssertEqual(withLLM.grade, base.grade)
        XCTAssertEqual(withLLM.headline, base.headline)
        XCTAssertEqual(withLLM.contributionLines, base.contributionLines)
        XCTAssertEqual(withLLM.caveat, base.caveat)
        XCTAssertNotNil(withLLM.narrative)
        XCTAssertNil(base.narrative, "确定性渲染本体不带 LLM 文本")

        // 摘要 Codable(LLM 输入通道可序列化)
        let data = try! JSONEncoder().encode(summary)
        let decoded = try! JSONDecoder().decode(AttributionNarrativeSummary.self, from: data)
        XCTAssertEqual(decoded, summary)
    }
}
