import XCTest
@testable import QiemanDashboard

/// DEC-7 单元测试：CriterionEvaluator——deterministic + provenance + 审计轨迹。
final class CriterionEvaluatorTests: XCTestCase {

    private func d(_ s: String) -> Decimal { Decimal(string: s)! }

    private func ref(_ id: String, _ weight: String, kind: CriterionDefinition.InputReference.Kind = .factorMetric)
        -> CriterionDefinition.InputReference
    {
        CriterionDefinition.InputReference(kind: kind, referenceID: id, weight: d(weight))
    }

    // MARK: - weightedSum golden

    func testWeightedSumGolden() {
        let definition = CriterionDefinition(
            id: "portfolio-momentum", version: "v1", evaluatorKind: .weightedSum,
            inputReferences: [ref("f1", "0.3"), ref("f2", "0.7")],
            unit: .ratio
        )
        let score = CriterionEvaluator().evaluate(
            definition: definition,
            inputs: [CriterionInput(referenceID: "f1", value: d("0.5")),
                     CriterionInput(referenceID: "f2", value: d("0.2"))]
        )
        // 0.3×0.5 + 0.7×0.2 = 0.15 + 0.14 = 0.29
        XCTAssertEqual(score.value, d("0.29"))
        XCTAssertTrue(score.missingInputs.isEmpty)
        // 审计轨迹可复述计算
        XCTAssertTrue(score.computation.contains("0.3×0.5"))
        XCTAssertTrue(score.computation.contains("0.7×0.2"))
        XCTAssertTrue(score.computation.contains("0.29"))
    }

    func testMissingInputYieldsUnknownNotGuess() {
        let definition = CriterionDefinition(
            id: "c1", version: "v1", evaluatorKind: .weightedSum,
            inputReferences: [ref("f1", "0.5"), ref("f2", "0.5")],
            unit: .ratio
        )
        let score = CriterionEvaluator().evaluate(
            definition: definition,
            inputs: [CriterionInput(referenceID: "f1", value: d("0.1")),   // f2 缺失
                     CriterionInput(referenceID: "other", value: d("9"))]  // 无关输入
        )
        XCTAssertNil(score.value, "任一输入缺失 → unknown,不以 0 或均值代替")
        XCTAssertEqual(score.missingInputs, ["f2"])
        XCTAssertTrue(score.computation.contains("f2"))
    }

    // MARK: - absoluteDeviation

    func testAbsoluteDeviationGolden() {
        let definition = CriterionDefinition(
            id: "target-deviation", version: "v1", evaluatorKind: .absoluteDeviation,
            inputReferences: [ref("current", "0"), ref("target", "0")],
            unit: .ratio
        )
        let score = CriterionEvaluator().evaluate(
            definition: definition,
            inputs: [CriterionInput(referenceID: "current", value: d("0.72")),
                     CriterionInput(referenceID: "target", value: d("0.60"))]
        )
        XCTAssertEqual(score.value, d("0.12"))
        XCTAssertTrue(score.computation.contains("|0.72 − 0.6"))
    }

    func testAbsoluteDeviationRequiresExactlyTwoRefs() {
        let definition = CriterionDefinition(
            id: "bad", version: "v1", evaluatorKind: .absoluteDeviation,
            inputReferences: [ref("a", "0"), ref("b", "0"), ref("c", "0")],
            unit: .ratio
        )
        let score = CriterionEvaluator().evaluate(
            definition: definition,
            inputs: [CriterionInput(referenceID: "a", value: d("1"))]
        )
        XCTAssertNil(score.value)
        XCTAssertEqual(score.missingInputs, ["a", "b", "c"], "定义非法 → 全部标缺(fail-closed)")
    }

    // MARK: - D002 纪律

    func testInputsAreCardinalOnly_noOrdinalSurface() {
        // CriterionInput 的字段类型是 Decimal?(cardinal)——不存在
        // SignalDirection / ordinal 通道;signal 影响必须先经 SignalPolicy
        // 转换为 cardinal(signalCardinal 引用 kind 只是标注来源)
        let labels = Mirror(reflecting: CriterionInput(referenceID: "x", value: d("1"))).children.compactMap(\.label)
        XCTAssertEqual(Set(labels), ["referenceID", "value"])

        // CriterionScore 同样无 ordinal 字段
        let score = CriterionScore(
            definition: CriterionDefinition(id: "c", version: "v1", evaluatorKind: .weightedSum,
                                            inputReferences: [ref("x", "1")], unit: .ratio),
            value: d("1"), missingInputs: [], computation: "1×1 = 1"
        )
        let scoreLabels = Mirror(reflecting: score).children.compactMap(\.label)
        XCTAssertEqual(Set(scoreLabels), ["definition", "value", "missingInputs", "computation"])
    }

    func testSignalCardinalChannelIsExplicitlyLabeled() {
        // signal 影响的唯一合法路径:signalCardinal 引用(标注来源是转换后
        // 的 cardinal,不是 ordinal 直通)
        let definition = CriterionDefinition(
            id: "c", version: "v1", evaluatorKind: .weightedSum,
            inputReferences: [ref("signal-momentum-converted", "1", kind: .signalCardinal)],
            unit: .ratio
        )
        XCTAssertEqual(definition.inputReferences[0].kind, .signalCardinal)
        let score = CriterionEvaluator().evaluate(
            definition: definition,
            inputs: [CriterionInput(referenceID: "signal-momentum-converted", value: d("-0.023"))]
        )
        XCTAssertEqual(score.value, d("-0.023"))
    }

    // MARK: - 确定性 / Codable

    func testDeterministicAndCodable() throws {
        let definition = CriterionDefinition(
            id: "c", version: "v1", evaluatorKind: .weightedSum,
            inputReferences: [ref("f1", "0.6"), ref("f2", "0.4")],
            unit: .ratio
        )
        let evaluator = CriterionEvaluator()
        let inputs = [CriterionInput(referenceID: "f1", value: d("0.1")),
                      CriterionInput(referenceID: "f2", value: d("0.2"))]
        XCTAssertEqual(evaluator.evaluate(definition: definition, inputs: inputs),
                       evaluator.evaluate(definition: definition, inputs: inputs))

        let data = try JSONEncoder().encode(definition)
        let decodedDef = try JSONDecoder().decode(CriterionDefinition.self, from: data)
        XCTAssertEqual(decodedDef, definition)
        XCTAssertEqual(decodedDef.fingerprint, "c@v1")

        let score = evaluator.evaluate(definition: definition, inputs: inputs)
        let scoreData = try JSONEncoder().encode(score)
        let decodedScore = try JSONDecoder().decode(CriterionScore.self, from: scoreData)
        XCTAssertEqual(decodedScore, score)
    }
}
