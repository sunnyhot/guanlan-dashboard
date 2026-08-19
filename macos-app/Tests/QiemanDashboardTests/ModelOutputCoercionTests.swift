import XCTest
@testable import QiemanDashboard

// MARK: - 模型输出规整测试
//
// 线上背景(v4.1.0 首晚):模型把 assetTrends[4].counterSignals[0] 输出成对象,
// 合成解码 typeMismatch,收盘复盘整个模块失败且自动修正救不回。
// 修复:提交入口解码前收敛字符串数组字段;单字段毛刺不再否决整份报告。

final class ModelOutputCoercionTests: XCTestCase {
    func testObjectElementsAreCoercedFromCommonTextFields() {
        let input: [String: Any] = [
            "counterSignals": [
                ["text": "跌破均线"],
                ["content": "放量滞涨"],
                ["reason": "外盘大跌"],
                ["unknown": "x"],  // 无正文字段 → 丢弃
            ]
        ]
        let output = ModelOutputCoercion.normalized(input)
        XCTAssertEqual(output["counterSignals"] as? [String], ["跌破均线", "放量滞涨", "外盘大跌"])
    }

    func testNumberAndEmptyElementsAreHandled() {
        let input: [String: Any] = [
            "triggerConditions": [42, "  ", "放量突破", true]
        ]
        let output = ModelOutputCoercion.normalized(input)
        XCTAssertEqual(output["triggerConditions"] as? [String], ["42", "放量突破", "1"])
    }

    func testNestedStructuresAreWalkedAndOtherKeysUntouched() {
        let input: [String: Any] = [
            "assetTrends": [
                [
                    "code": "000001",
                    "counterSignals": [["text": "反向信号"]],
                    "evidenceIDs": ["e1", ["value": "e2"], 3],
                ]
            ],
            "rationale": "原样保留",
            "confidence": ["score": 70, "label": "高"],
        ]
        let output = ModelOutputCoercion.normalized(input)
        let trend = (output["assetTrends"] as? [[String: Any]])?.first
        XCTAssertEqual(trend?["counterSignals"] as? [String], ["反向信号"])
        XCTAssertEqual(trend?["evidenceIDs"] as? [String], ["e1", "e2", "3"])
        XCTAssertEqual(output["rationale"] as? String, "原样保留")
        XCTAssertEqual((output["confidence"] as? [String: Any])?["score"] as? Int, 70)
    }

    /// 与线上故障同构:对象元素让 TrendHorizonView 解码失败,规整后应通过。
    func testHorizonDecodesAfterCoercionButFailsWithout() throws {
        let payload: [String: Any] = [
            "horizon": "medium",
            "direction": "bullish",
            "confidence": ["score": 70, "label": "高"],
            "rationale": "理由",
            "counterSignals": [["text": "若跌破前低则判断失效"]],
        ]
        let rawData = try JSONSerialization.data(withJSONObject: payload)

        XCTAssertThrowsError(
            try JSONDecoder().decode(TrendHorizonView.self, from: rawData),
            "规整前:对象元素触发 typeMismatch(线上故障形态)"
        )

        let coerced = ModelOutputCoercion.normalizedJSON(rawData)
        let decoded = try JSONDecoder().decode(TrendHorizonView.self, from: coerced)
        XCTAssertEqual(decoded.counterSignals, ["若跌破前低则判断失效"])
    }

    func testNormalizedJSONFallsBackToOriginalOnInvalidInput() {
        let invalid = Data("not json".utf8)
        XCTAssertEqual(ModelOutputCoercion.normalizedJSON(invalid), invalid)
    }
}
