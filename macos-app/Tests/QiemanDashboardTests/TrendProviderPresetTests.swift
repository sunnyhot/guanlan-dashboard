import XCTest
@testable import QiemanDashboard

// MARK: - 供应商预设测试(P2 配置向导化)
//
// 预设是普通用户绕过「Base URL 是什么」的第一入口:字段必须完整、
// 地址必须 https、应用只预填不改 Key,自定义配置不被误判为预设。

final class TrendProviderPresetTests: XCTestCase {
    func testAllPresetsHaveCompleteHTTPSFields() {
        XCTAssertGreaterThanOrEqual(TrendProviderPreset.allPresets.count, 3)
        let names = Set(TrendProviderPreset.allPresets.map(\.name))
        for preset in TrendProviderPreset.allPresets {
            XCTAssertFalse(preset.name.isEmpty)
            XCTAssertTrue(preset.baseURL.hasPrefix("https://"), "\(preset.name) baseURL 必须 https")
            XCTAssertFalse(preset.defaultModel.isEmpty, "\(preset.name) 缺默认模型")
            XCTAssertTrue(preset.consoleURL.hasPrefix("https://"), "\(preset.name) 控制台链接必须 https")
            XCTAssertTrue(preset.consoleURL.contains("/"), "\(preset.name) 控制台链接需带路径")
        }
        XCTAssertTrue(names.contains("智谱"), "智谱是项目自身使用的服务,必须在首发预设里")
    }

    func testApplyOnlyFillsConnectionFields() {
        var settings = TrendAIProviderSettings(
            providerName: "旧供应商",
            baseURL: "https://old.example.com/v1",
            model: "old-model",
            apiKey: "sk-keep",
            timeoutSeconds: 120
        )
        let preset = TrendProviderPreset.allPresets[0]
        preset.apply(to: &settings)

        XCTAssertEqual(settings.providerName, preset.name)
        XCTAssertEqual(settings.baseURL, preset.baseURL)
        XCTAssertEqual(settings.model, preset.defaultModel)
        XCTAssertEqual(settings.apiKey, "sk-keep", "应用预设不得动 API Key")
        XCTAssertEqual(settings.timeoutSeconds, 120, "应用预设不得动超时")
    }

    func testMatchingByBaseURL() {
        let preset = TrendProviderPreset.allPresets[0]
        let matched = TrendAIProviderSettings(
            providerName: "随便叫什么",
            baseURL: preset.baseURL,
            model: "别的模型",
            apiKey: "",
            timeoutSeconds: 300
        )
        XCTAssertEqual(TrendProviderPreset.matching(matched)?.name, preset.name)

        XCTAssertNil(TrendProviderPreset.matching(TrendAIProviderSettings.empty), "未配置不命中")
        let custom = TrendAIProviderSettings(
            providerName: "自建",
            baseURL: "https://my-proxy.example.com/v1",
            model: "m",
            apiKey: "",
            timeoutSeconds: 300
        )
        XCTAssertNil(TrendProviderPreset.matching(custom), "自定义地址不命中")
    }

    func testMatchingTrimsWhitespace() {
        let preset = TrendProviderPreset.allPresets[1]
        let settings = TrendAIProviderSettings(
            providerName: preset.name,
            baseURL: "  \(preset.baseURL)  ",
            model: preset.defaultModel,
            apiKey: "",
            timeoutSeconds: 300
        )
        XCTAssertEqual(TrendProviderPreset.matching(settings)?.name, preset.name)
    }
}
