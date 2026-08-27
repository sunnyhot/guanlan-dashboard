import XCTest
@testable import QiemanDashboard

// ModelGateway 测试共享基建（自 V2 ResearchTestSupport 抽取的网关相关 fake /
// 响应构造；其余 Research 专用 helper 留在 V2 侧）。

// MARK: - 可编程模型 provider（RES-1 起共用）

/// 可编程 provider：按脚本依次返回响应或错误，记录每次调用。
final class ScriptedModelProvider: ModelProvider, @unchecked Sendable {
    enum Step {
        case response(ModelCompletionResponse)
        case error(ModelProviderError)
    }

    let descriptor: ModelProviderDescriptor
    private let steps: [Step]
    private let lock = NSLock()
    private var index = 0
    private var recordedCalls: [RecordedCall] = []

    struct RecordedCall {
        let purpose: String
        let timeout: TimeInterval
    }

    init(providerID: String, model: String = "test-model", steps: [Step]) {
        self.descriptor = ModelProviderDescriptor(
            providerID: providerID,
            model: model,
            fingerprint: "fp-\(providerID)"
        )
        self.steps = steps
    }

    var calls: [RecordedCall] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    func complete(
        _ request: ModelCompletionRequest,
        timeout: TimeInterval
    ) async throws -> ModelCompletionResponse {
        lock.lock()
        let step: Step = steps.isEmpty
            ? .error(.invalidResponse(providerID: descriptor.providerID, detail: "空脚本"))
            : steps[min(index, steps.count - 1)]
        index += 1
        recordedCalls.append(RecordedCall(purpose: request.purpose, timeout: timeout))
        lock.unlock()
        switch step {
        case .response(let response):
            return response
        case .error(let error):
            throw error
        }
    }
}

/// trace 收集器（线程安全；断言用）。
final class TraceCollector: ModelTraceSink, @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [ModelCallTrace] = []

    func record(_ trace: ModelCallTrace) async {
        lock.lock()
        defer { lock.unlock() }
        collected.append(trace)
    }

    var traces: [ModelCallTrace] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}

// MARK: - 响应构造

/// 工具调用响应（calls 为 (name, args) 列表；id 随机——对行为断言无意义）。
func toolCallResponse(_ calls: [(name: String, args: String)]) -> ModelCompletionResponse {
    let modelCalls = calls.map {
        ModelToolCall(id: UUID().uuidString, name: $0.name, argumentsJSON: $0.args)
    }
    return ModelCompletionResponse(
        assistantMessage: ModelChatMessage(role: .assistant, content: nil, toolCalls: modelCalls),
        toolCalls: modelCalls,
        stopReason: .toolCalls,
        usage: nil
    )
}

/// 纯文本响应（无工具调用；可选携带 usage）。
func textResponse(_ content: String, usage: ModelTokenUsage? = nil) -> ModelCompletionResponse {
    ModelCompletionResponse(
        assistantMessage: ModelChatMessage(role: .assistant, content: content),
        toolCalls: [],
        stopReason: .stop,
        usage: usage
    )
}

