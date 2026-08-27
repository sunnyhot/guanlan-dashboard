import XCTest
@testable import QiemanDashboard

// GatewayAgentClient（旧链路 → LLM 网关接线）的行为测试：
// - 请求/响应双向映射保持旧协议语义（含 finishReason / usage 还原）
// - 网关错误映射回 OpenAICompatibleAgentClientError（调用方 catch 分支不变）
// - 重试 / trace 在适配层可见

final class GatewayAgentClientTests: XCTestCase {

    private func settings() -> TrendAIProviderSettings {
        TrendAIProviderSettings(
            providerName: "智谱",
            baseURL: "https://api.example.com/v1",
            model: "glm-test",
            apiKey: "sk-test-key",
            timeoutSeconds: 120
        )
    }

    private func unconfiguredSettings() -> TrendAIProviderSettings {
        TrendAIProviderSettings.empty
    }

    private func makeClient(
        provider: ScriptedModelProvider,
        policy: ModelGatewayPolicy = ModelGatewayPolicy(retryInterval: 0),
        trace: TraceCollector = TraceCollector()
    ) -> GatewayAgentClient {
        GatewayAgentClient(
            purpose: "unit-test",
            policy: policy,
            providerFactory: { _ in provider },
            traceSink: trace
        )
    }

    func testUnconfiguredSettingsThrowsMissingConfiguration() async {
        let provider = ScriptedModelProvider(providerID: "p", steps: [.response(textResponse("ok"))])
        let client = makeClient(provider: provider)

        await XCTAssertThrowsErrorAsync {
            try await client.complete(
                messages: [AgentChatMessage(role: .user, content: "hi", toolCalls: nil, toolCallID: nil)],
                tools: [],
                toolChoice: .auto,
                temperature: 0.2,
                settings: self.unconfiguredSettings(),
                timeout: nil,
                streamProgress: nil
            )
        } errorHandler: { error in
            guard case OpenAICompatibleAgentClientError.missingConfiguration = error else {
                return XCTFail("期望 missingConfiguration，实际 \(error)")
            }
        }
        XCTAssertTrue(provider.calls.isEmpty, "未配置时不应发起真实调用")
    }

    func testSuccessMapsResponseBackToAgentResult() async throws {
        let usage = ModelTokenUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15)
        let provider = ScriptedModelProvider(
            providerID: "p",
            steps: [.response(textResponse("答案", usage: usage))]
        )
        let client = makeClient(provider: provider)

        let result = try await client.complete(
            messages: [AgentChatMessage(role: .user, content: "问题", toolCalls: nil, toolCallID: nil)],
            tools: [],
            toolChoice: .auto,
            temperature: 0.2,
            settings: self.settings(),
            timeout: nil,
            streamProgress: nil
        )

        XCTAssertEqual(result.assistantMessage.content, "答案")
        XCTAssertEqual(result.stopReason, .stop)
        XCTAssertEqual(result.finishReason, "stop")
        XCTAssertEqual(result.usage?.totalTokens, 15)
        XCTAssertEqual(result.usage?.promptTokens, 10)
        XCTAssertTrue(result.toolCalls.isEmpty)

        // 请求侧映射：purpose 传给网关，timeout 采用 settings 默认
        XCTAssertEqual(provider.calls.single?.purpose, "unit-test")
        XCTAssertEqual(provider.calls.single?.timeout, 120)
    }

    func testTimeoutOverrideBeatsSettingsDefault() async throws {
        let provider = ScriptedModelProvider(providerID: "p", steps: [.response(textResponse("ok"))])
        let client = makeClient(provider: provider)

        _ = try await client.complete(
            messages: [AgentChatMessage(role: .user, content: "q", toolCalls: nil, toolCallID: nil)],
            tools: [],
            toolChoice: .auto,
            temperature: 0.2,
            settings: self.settings(),
            timeout: 33,
            streamProgress: nil
        )
        XCTAssertEqual(provider.calls.single?.timeout, 33)
    }

    func testRetryableErrorRetriesThenSucceeds() async throws {
        let provider = ScriptedModelProvider(providerID: "p", steps: [
            .error(.requestFailed(providerID: "p", statusCode: 500, detail: nil)),
            .response(textResponse("恢复")),
        ])
        let trace = TraceCollector()
        let client = makeClient(provider: provider, trace: trace)

        let result = try await client.complete(
            messages: [AgentChatMessage(role: .user, content: "q", toolCalls: nil, toolCallID: nil)],
            tools: [],
            toolChoice: .auto,
            temperature: 0.2,
            settings: self.settings(),
            timeout: nil,
            streamProgress: nil
        )
        XCTAssertEqual(result.assistantMessage.content, "恢复")
        XCTAssertEqual(provider.calls.count, 2)
        XCTAssertEqual(trace.traces.count, 2, "失败 + 成功各一条 trace")
        XCTAssertEqual(trace.traces.first?.outcome, .failed)
        XCTAssertEqual(trace.traces.last?.outcome, .succeeded)
    }

    func testRetryDisabledSurfacesClientTimeoutError() async {
        let provider = ScriptedModelProvider(providerID: "p", steps: [
            .error(.timedOut(providerID: "p", seconds: 30)),
        ])
        // 趋势研究同款策略：网关不重试
        let client = makeClient(provider: provider, policy: ModelGatewayPolicy(maxRetriesPerProvider: 0))

        await XCTAssertThrowsErrorAsync {
            try await client.complete(
                messages: [AgentChatMessage(role: .user, content: "q", toolCalls: nil, toolCallID: nil)],
                tools: [],
                toolChoice: .auto,
                temperature: 0.2,
                settings: self.settings(),
                timeout: nil,
                streamProgress: nil
            )
        } errorHandler: { error in
            guard case OpenAICompatibleAgentClientError.timedOut(let seconds) = error else {
                return XCTFail("期望 timedOut，实际 \(error)")
            }
            XCTAssertEqual(seconds, 30)
        }
        XCTAssertEqual(provider.calls.count, 1, "maxRetriesPerProvider=0 时只尝试一次")
    }

    func testNonRetryableConfigErrorFailsFastAsClientError() async {
        let provider = ScriptedModelProvider(providerID: "p", steps: [
            .error(.invalidConfiguration(providerID: "p", detail: "base URL 无效")),
        ])
        let client = makeClient(provider: provider)

        await XCTAssertThrowsErrorAsync {
            try await client.complete(
                messages: [AgentChatMessage(role: .user, content: "q", toolCalls: nil, toolCallID: nil)],
                tools: [],
                toolChoice: .auto,
                temperature: 0.2,
                settings: self.settings(),
                timeout: nil,
                streamProgress: nil
            )
        } errorHandler: { error in
            guard case OpenAICompatibleAgentClientError.invalidBaseURL = error else {
                return XCTFail("期望 invalidBaseURL，实际 \(error)")
            }
        }
        XCTAssertEqual(provider.calls.count, 1, "配置类错误不重试")
    }

    func testToolSpecMapsRoundtrip() {
        let tool = AgentToolDefinition.function(
            name: "submit",
            description: "提交",
            parameters: .object(["type": .string("object")])
        )
        let domain = GatewayAgentClient.domainTool(tool)
        XCTAssertEqual(domain.name, "submit")
        XCTAssertEqual(domain.description, "提交")

        let back = OpenAICompatibleModelProvider.transportTool(domain)
        XCTAssertEqual(back.function.name, tool.function.name)
        XCTAssertEqual(back.function.description, tool.function.description)
    }
}

// MARK: - 辅助

private extension Array {
    var single: Element? {
        count == 1 ? first : nil
    }
}

/// async 抛错断言（XCTest 原生 async XCTAssertThrowsError 尚不可用）。
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @escaping () async throws -> T,
    errorHandler: @escaping (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("期望抛错但正常返回")
    } catch {
        errorHandler(error)
    }
}
