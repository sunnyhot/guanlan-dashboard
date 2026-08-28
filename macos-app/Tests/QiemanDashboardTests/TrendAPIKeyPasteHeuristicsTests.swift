import XCTest
@testable import QiemanDashboard

/// W1.4:剪贴板 Key 识别的纯函数测试——保守匹配,拒绝普通文本。
final class TrendAPIKeyPasteHeuristicsTests: XCTestCase {
    func testOpenAICompatiblePrefixKey() {
        XCTAssertEqual(
            TrendAPIKeyPasteHeuristics.classify("sk-abcdef1234567890abcdef"),
            .providerKey(suggestedPresetName: nil)
        )
    }

    func testTavilyPrefixKey() {
        XCTAssertEqual(
            TrendAPIKeyPasteHeuristics.classify("tvly-abcdef1234567890abcdef"),
            .tavilyKey
        )
    }

    func testZhipuShapedKeySuggestsPreset() {
        let key = String(repeating: "a1b2c3d4", count: 4) + "." + String(repeating: "e5f6a7b8", count: 2)
        XCTAssertEqual(
            TrendAPIKeyPasteHeuristics.classify(key),
            .providerKey(suggestedPresetName: "智谱")
        )
    }

    func testRejectsPlainTextAndMalformedInput() {
        XCTAssertNil(TrendAPIKeyPasteHeuristics.classify("去设置里配置模型"))
        XCTAssertNil(TrendAPIKeyPasteHeuristics.classify("hello world foo bar"))
        XCTAssertNil(TrendAPIKeyPasteHeuristics.classify(""))
        XCTAssertNil(TrendAPIKeyPasteHeuristics.classify("sk-"))
        // 多行文本(复制了整段说明)不应被当 Key。
        XCTAssertNil(TrendAPIKeyPasteHeuristics.classify("sk-abcdef1234567890\n第二行"))
    }
}
