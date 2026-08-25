import XCTest
@testable import QiemanDashboard

// Research 测试共享基建（RES-1..9 各套件共用的 fake / 响应构造 / fixture /
// 日历 stub）。原散落在各测试文件顶层或 private func，行为零变化集中归位。

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

// MARK: - 可编程研究工具（RES-2 起共用）

/// 可编程研究工具（记录调用）。
final class StubResearchTool: ResearchTool, @unchecked Sendable {
    let name: String
    let description: String
    let parameters: ModelJSONValue
    private let resultContent: ModelJSONValue
    private let resultEvidence: [EvidenceID]
    private let lock = NSLock()
    private var callCountValue = 0
    private var lastArgumentsValue: String?

    init(
        name: String = "get_market_snapshot",
        content: ModelJSONValue = ["snapshot": "ok"],
        evidence: [EvidenceID] = [EvidenceID(rawValue: "EV-1")]
    ) {
        self.name = name
        self.description = "测试工具"
        self.parameters = ["type": "object", "properties": [:]]
        self.resultContent = content
        self.resultEvidence = evidence
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCountValue
    }

    var lastArguments: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastArgumentsValue
    }

    func execute(argumentsJSON: String, context: ResearchToolContext) async -> ResearchToolResult {
        lock.lock()
        callCountValue += 1
        lastArgumentsValue = argumentsJSON
        lock.unlock()
        return ResearchToolResult(contentJSON: resultContent, isError: false, evidenceIDs: resultEvidence)
    }
}

// MARK: - 领域 fixture

/// 标准测试任务（fundShareClass sc_513100）。
func makeResearchTask() throws -> ResearchTask {
    try ResearchTask(
        subject: CanonicalRef(entityType: "fundShareClass", entityIDRawValue: "sc_513100"),
        objective: "评估该标的当前的市场环境",
        guidance: nil
    )
}

/// 标准测试笔记（默认 producer / producedAt；claims 由调用方给定）。
func makeResearchNotes(
    _ claims: [ResearchClaim],
    subject: CanonicalRef? = nil,
    producedAt: Date = Date(timeIntervalSince1970: 1000)
) throws -> ResearchNotes {
    try ResearchNotes(
        task: ResearchTask(
            subject: subject ?? CanonicalRef(entityType: "fundShareClass", entityIDRawValue: "sc_513100"),
            objective: "test"
        ),
        notes: "n",
        claims: claims,
        producedBy: ModelProviderDescriptor(providerID: "p", model: "test-model", fingerprint: "f"),
        producedAt: producedAt
    )
}

// MARK: - TradingCalendar stub（SignalStore / ResearchGolden 共用）

/// 周一至周五为交易日的极简日历（SignalStore 构造 GRDBRepository 用）。
struct TestWeekdayCalendar: TradingCalendar {
    func isTradingDay(_ date: Date, jurisdiction: Jurisdiction) -> Bool {
        let weekday = Calendar(identifier: .gregorian).component(.weekday, from: date)
        return weekday >= 2 && weekday <= 6
    }

    func tradingDay(after date: Date, offset: Int, jurisdiction: Jurisdiction) -> Date {
        var current = date
        var remaining = max(offset, 0)
        var safety = 0
        while remaining > 0 && safety < 14 {
            current = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: current)!
            if isTradingDay(current, jurisdiction: jurisdiction) { remaining -= 1 }
            safety += 1
        }
        return current
    }

    func tradingDayStart(_ date: Date, jurisdiction: Jurisdiction) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.startOfDay(for: date)
    }
}
