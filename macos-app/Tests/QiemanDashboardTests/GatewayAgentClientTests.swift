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
        provider: any ModelProvider,
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

    func testStreamEventsFlowThroughAdapterIncludingContentDeltas() async throws {
        let provider = EventEmittingProvider(events: [
            .firstChunk(elapsed: 0.4),
            .contentDelta("正在"),
            .contentDelta("分析"),
            .active(chunkCount: 5, elapsed: 1.2),
            .finished(chunkCount: 9, elapsed: 2.0, finishReason: "stop"),
        ])
        let client = makeClient(provider: provider)
        let collector = AgentStreamProgressCollector()

        let result = try await client.complete(
            messages: [AgentChatMessage(role: .user, content: "q", toolCalls: nil, toolCallID: nil)],
            tools: [],
            toolChoice: .auto,
            temperature: 0.2,
            settings: self.settings(),
            timeout: nil,
            streamProgress: { progress in collector.append(progress) }
        )

        XCTAssertEqual(result.assistantMessage.content, "done")
        let events = collector.progress
        guard events.count == 5 else {
            return XCTFail("期望 5 个事件，实际 \(events)")
        }
        XCTAssertEqual(events[0], .firstChunk(elapsed: 0.4))
        XCTAssertEqual(events[1], .contentDelta("正在"))
        XCTAssertEqual(events[2], .contentDelta("分析"))
        XCTAssertEqual(events[3], .active(chunkCount: 5, elapsed: 1.2))
        XCTAssertEqual(events[4], .finished(chunkCount: 9, elapsed: 2.0, finishReason: "stop"))
    }

    func testNoStreamCallbackMeansNoEventWiring() async throws {
        // streamProgress 为 nil（盘中研判/专项研究路径）：不接线事件，行为不变。
        let provider = EventEmittingProvider(events: [.contentDelta("不应被消费")])
        let client = makeClient(provider: provider)

        let result = try await client.complete(
            messages: [AgentChatMessage(role: .user, content: "q", toolCalls: nil, toolCallID: nil)],
            tools: [],
            toolChoice: .auto,
            temperature: 0.2,
            settings: self.settings(),
            timeout: nil,
            streamProgress: nil
        )
        XCTAssertEqual(result.assistantMessage.content, "done")
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

/// 依次发事件再返回响应的 provider（网关/适配器事件透传测试）。
final class EventEmittingProvider: ModelProvider, @unchecked Sendable {
    let descriptor = ModelProviderDescriptor(providerID: "event-provider", model: "m", fingerprint: "fp")
    private let events: [ModelStreamEvent]

    init(events: [ModelStreamEvent]) {
        self.events = events
    }

    func complete(
        _ request: ModelCompletionRequest,
        timeout: TimeInterval
    ) async throws -> ModelCompletionResponse {
        textResponse("未发事件")
    }

    func complete(
        _ request: ModelCompletionRequest,
        timeout: TimeInterval,
        onEvent: @escaping @Sendable (ModelStreamEvent) async -> Void
    ) async throws -> ModelCompletionResponse {
        for event in events {
            await onEvent(event)
        }
        return textResponse("done")
    }
}

/// 线程安全的流式进度收集器（streamProgress 断言用）。
final class AgentStreamProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AgentStreamProgress] = []

    func append(_ progress: AgentStreamProgress) {
        lock.lock()
        items.append(progress)
        lock.unlock()
    }

    var progress: [AgentStreamProgress] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

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
