import XCTest
@testable import QiemanDashboard

// RES-1：LLM Model Gateway——provider selection / failover / retry /
// token budget / tracing / usage 记账的行为锁定。

final class ModelGatewayTests: XCTestCase {

    private func makeRequest(purpose: String = "test", maxOutputTokens: Int? = nil) -> ModelCompletionRequest {
        ModelCompletionRequest(
            messages: [ModelChatMessage(role: .user, content: "你好")],
            maxOutputTokens: maxOutputTokens,
            purpose: purpose
        )
    }

    private func zeroSleeper() -> ( @Sendable (TimeInterval) async -> Void, @Sendable () -> Int ) {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() {
                lock.lock()
                count += 1
                lock.unlock()
            }
            var value: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }
        }
        let counter = Counter()
        return ({ _ in counter.increment() }, { counter.value })
    }

    // MARK: selection / failover / retry

    func testFirstHealthyProviderWins() async throws {
        let primary = ScriptedModelProvider(providerID: "primary", steps: [
            .response(textResponse("ok"))
        ])
        let secondary = ScriptedModelProvider(providerID: "secondary", steps: [
            .response(textResponse("should-not-run"))
        ])
        let traces = TraceCollector()
        let gateway = ModelGateway(
            providers: [primary, secondary],
            traceSink: traces
        )

        let response = try await gateway.complete(makeRequest())
        XCTAssertEqual(response.assistantMessage.content, "ok")
        XCTAssertEqual(primary.calls.count, 1)
        XCTAssertEqual(secondary.calls.count, 0)
        XCTAssertEqual(traces.traces.count, 1)
        XCTAssertEqual(traces.traces.first?.providerID, "primary")
        XCTAssertEqual(traces.traces.first?.outcome, .succeeded)
    }

    func testRetryableErrorRetriesThenFailsOver() async throws {
        // maxRetriesPerProvider = 1：primary 超时两次后换 secondary 一次成功。
        let primary = ScriptedModelProvider(providerID: "primary", steps: [
            .error(.timedOut(providerID: "primary", seconds: 5)),
            .error(.timedOut(providerID: "primary", seconds: 5)),
        ])
        let secondary = ScriptedModelProvider(providerID: "secondary", steps: [
            .response(textResponse("recovered"))
        ])
        let (sleep, sleepCount) = zeroSleeper()
        let traces = TraceCollector()
        var policy = ModelGatewayPolicy()
        policy.maxRetriesPerProvider = 1
        policy.retryInterval = 0
        let gateway = ModelGateway(
            providers: [primary, secondary],
            policy: policy,
            traceSink: traces,
            sleeper: sleep
        )

        let response = try await gateway.complete(makeRequest())
        XCTAssertEqual(response.assistantMessage.content, "recovered")
        XCTAssertEqual(primary.calls.count, 2, "maxRetries=1 → primary 共 1+1 次尝试")
        XCTAssertEqual(secondary.calls.count, 1)
        XCTAssertEqual(sleepCount(), 1, "只有 primary 第一次失败后睡了一次")
        XCTAssertEqual(traces.traces.map(\.outcome), [.failed, .failed, .succeeded])
        XCTAssertEqual(traces.traces.last?.providerIndex, 1)
        XCTAssertEqual(traces.traces.last?.attempt, 1)
    }

    func testNonRetryableErrorSkipsToNextProviderImmediately() async throws {
        let primary = ScriptedModelProvider(providerID: "primary", steps: [
            .error(.invalidResponse(providerID: "primary", detail: "bad"))
        ])
        let secondary = ScriptedModelProvider(providerID: "secondary", steps: [
            .response(textResponse("ok"))
        ])
        let (sleep, sleepCount) = zeroSleeper()
        var policy = ModelGatewayPolicy()
        policy.maxRetriesPerProvider = 2
        let gateway = ModelGateway(
            providers: [primary, secondary],
            policy: policy,
            sleeper: sleep
        )

        let response = try await gateway.complete(makeRequest())
        XCTAssertEqual(response.assistantMessage.content, "ok")
        XCTAssertEqual(primary.calls.count, 1, "不可重试错误不重试")
        XCTAssertEqual(sleepCount(), 0)
    }

    func testAllProvidersFailedAggregatesLastError() async {
        let primary = ScriptedModelProvider(providerID: "primary", steps: [
            .error(.requestFailed(providerID: "primary", statusCode: 500, detail: nil))
        ])
        let secondary = ScriptedModelProvider(providerID: "secondary", steps: [
            .error(.invalidConfiguration(providerID: "secondary", detail: "bad url"))
        ])
        var policy = ModelGatewayPolicy()
        policy.maxRetriesPerProvider = 0
        let gateway = ModelGateway(providers: [primary, secondary], policy: policy)

        do {
            _ = try await gateway.complete(makeRequest())
            XCTFail("应抛 allProvidersFailed")
        } catch let error as ModelGatewayError {
            guard case .allProvidersFailed(let last, let attempts) = error else {
                return XCTFail("错误类型不对: \(error)")
            }
            XCTAssertEqual(last, .invalidConfiguration(providerID: "secondary", detail: "bad url"))
            XCTAssertEqual(attempts, 2)
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }

    func testFailoverDisabledSticksToFirstProvider() async {
        let primary = ScriptedModelProvider(providerID: "primary", steps: [
            .error(.timedOut(providerID: "primary", seconds: 5))
        ])
        let secondary = ScriptedModelProvider(providerID: "secondary", steps: [
            .response(textResponse("never"))
        ])
        var policy = ModelGatewayPolicy()
        policy.failoverEnabled = false
        policy.maxRetriesPerProvider = 0
        let gateway = ModelGateway(providers: [primary, secondary], policy: policy)

        do {
            _ = try await gateway.complete(makeRequest())
            XCTFail("应抛 allProvidersFailed")
        } catch let error as ModelGatewayError {
            guard case .allProvidersFailed = error else {
                return XCTFail("错误类型不对: \(error)")
            }
            XCTAssertEqual(secondary.calls.count, 0, "failover 关闭时不触碰次选")
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }

    // MARK: 未配置 provider

    func testMissingConfigurationProviderIsSkippedWithoutTrace() async throws {
        let unconfigured = ScriptedModelProvider(providerID: "unconfigured", steps: [
            .error(.missingConfiguration(providerID: "unconfigured"))
        ])
        let configured = ScriptedModelProvider(providerID: "configured", steps: [
            .response(textResponse("ok"))
        ])
        let traces = TraceCollector()
        let gateway = ModelGateway(providers: [unconfigured, configured], traceSink: traces)

        let response = try await gateway.complete(makeRequest())
        XCTAssertEqual(response.assistantMessage.content, "ok")
        XCTAssertEqual(
            traces.traces.map(\.providerID), ["configured"],
            "未配置 provider 没有发生真实调用，不产失败 trace"
        )
    }

    func testAllMissingConfigurationThrowsNoProviders() async {
        let unconfigured = ScriptedModelProvider(providerID: "a", steps: [
            .error(.missingConfiguration(providerID: "a"))
        ])
        let gateway = ModelGateway(providers: [unconfigured])

        do {
            _ = try await gateway.complete(makeRequest())
            XCTFail("应抛 noProvidersConfigured")
        } catch let error as ModelGatewayError {
            guard case .noProvidersConfigured = error else {
                return XCTFail("错误类型不对: \(error)")
            }
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }

    // MARK: token budget

    func testTokenBudgetFailClosedBeforeRequest() async {
        let provider = ScriptedModelProvider(providerID: "primary", steps: [
            .response(textResponse("never"))
        ])
        let ledger = ModelUsageLedger()
        await ledger.record(usage: ModelTokenUsage(promptTokens: 400, completionTokens: 500, totalTokens: 900))
        var policy = ModelGatewayPolicy()
        policy.tokenBudget = 1000
        let gateway = ModelGateway(providers: [provider], policy: policy, ledger: ledger)

        do {
            _ = try await gateway.complete(makeRequest(maxOutputTokens: 200))
            XCTFail("900 + 200 > 1000 应拒绝")
        } catch let error as ModelGatewayError {
            guard case .tokenBudgetExhausted(let consumed, let requested, let budget) = error else {
                return XCTFail("错误类型不对: \(error)")
            }
            XCTAssertEqual(consumed, 900)
            XCTAssertEqual(requested, 200)
            XCTAssertEqual(budget, 1000)
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
        XCTAssertTrue(provider.calls.isEmpty, "预算拒绝发生在真实调用之前")
    }

    func testTokenBudgetUsesReportedTotalThenFallsBackToParts() async {
        // total 缺失时退 prompt + completion。
        let ledger = ModelUsageLedger()
        await ledger.record(usage: ModelTokenUsage(promptTokens: 30, completionTokens: 12, totalTokens: nil))
        let consumed = await ledger.consumedTokens()
        XCTAssertEqual(consumed, 42)
        // 上报 total 的请求按 total 记。
        await ledger.record(usage: ModelTokenUsage(promptTokens: 100, completionTokens: 100, totalTokens: 150))
        let consumed2 = await ledger.consumedTokens()
        XCTAssertEqual(consumed2, 192)
    }

    // MARK: usage 记账

    func testUsageLedgerCountsReportedAndUnreported() async throws {
        let provider = ScriptedModelProvider(providerID: "primary", steps: [
            .response(textResponse("a", usage: ModelTokenUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15))),
            .response(textResponse("b", usage: nil)),
        ])
        let gateway = ModelGateway(providers: [provider])

        _ = try await gateway.complete(makeRequest())
        _ = try await gateway.complete(makeRequest())

        let snapshot = await gateway.usageSnapshot()
        XCTAssertEqual(snapshot.reportedTotalTokens, 15)
        XCTAssertEqual(snapshot.requestsWithReportedUsage, 1)
        XCTAssertEqual(snapshot.requestsWithoutReportedUsage, 1)
    }

    // MARK: 错误可重试分类

    func testRetryableClassification() {
        XCTAssertTrue(ModelProviderError.timedOut(providerID: "p", seconds: 1).isRetryable)
        XCTAssertTrue(ModelProviderError.requestFailed(providerID: "p", statusCode: 429, detail: nil).isRetryable)
        XCTAssertTrue(ModelProviderError.requestFailed(providerID: "p", statusCode: 503, detail: nil).isRetryable)
        XCTAssertTrue(ModelProviderError.requestFailed(providerID: "p", statusCode: nil, detail: "network").isRetryable)
        XCTAssertFalse(ModelProviderError.requestFailed(providerID: "p", statusCode: 400, detail: nil).isRetryable)
        XCTAssertFalse(ModelProviderError.requestFailed(providerID: "p", statusCode: 401, detail: nil).isRetryable)
        XCTAssertFalse(ModelProviderError.missingConfiguration(providerID: "p").isRetryable)
        XCTAssertFalse(ModelProviderError.invalidConfiguration(providerID: "p", detail: "x").isRetryable)
        XCTAssertFalse(ModelProviderError.invalidResponse(providerID: "p", detail: "x").isRetryable)
    }

    // MARK: 桥接映射（OpenAICompatibleModelProvider）

    func testBridgeMessageRoundTrip() {
        let original = ModelChatMessage(
            role: .assistant,
            content: nil,
            toolCalls: [
                ModelToolCall(id: "call-1", name: "web_search", argumentsJSON: "{\"q\":\"a\"}")
            ],
            toolCallID: nil
        )
        let transported = OpenAICompatibleModelProvider.transportMessage(original)
        XCTAssertEqual(transported.role, .assistant)
        XCTAssertEqual(transported.toolCalls?.first?.function.name, "web_search")
        XCTAssertEqual(transported.toolCalls?.first?.function.arguments, "{\"q\":\"a\"}")
        let back = OpenAICompatibleModelProvider.domainMessage(transported)
        XCTAssertEqual(back, original)
    }

    func testBridgeJSONRoundTrip() {
        let schema: ModelJSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "limit": .object(["type": .string("number")]),
                "tags": .array([.string("a"), .bool(true), .null])
            ])
        ])
        let transported = OpenAICompatibleModelProvider.transportJSON(schema)
        let back = OpenAICompatibleModelProvider.domainJSON(transported)
        XCTAssertEqual(back, schema)
    }

    func testBridgeErrorMapping() {
        XCTAssertEqual(
            OpenAICompatibleModelProvider.domainError(
                .timedOut(30), providerID: "p"
            ),
            .timedOut(providerID: "p", seconds: 30)
        )
        XCTAssertEqual(
            OpenAICompatibleModelProvider.domainError(
                .requestFailed(statusCode: 429, detail: "limit"), providerID: "p"
            ),
            .requestFailed(providerID: "p", statusCode: 429, detail: "limit")
        )
        XCTAssertEqual(
            OpenAICompatibleModelProvider.domainError(.invalidBaseURL, providerID: "p"),
            .invalidConfiguration(providerID: "p", detail: "base URL 无效")
        )
    }

    func testConfigurationFingerprintStableAndKeySensitive() {
        let a = LLMProviderConfiguration(providerID: "p", baseURL: "https://x", model: "m", apiKey: "k1")
        let b = LLMProviderConfiguration(providerID: "p", baseURL: "https://x", model: "m", apiKey: "k1")
        let c = LLMProviderConfiguration(providerID: "p", baseURL: "https://x", model: "m", apiKey: "k2")
        XCTAssertEqual(a.fingerprint, b.fingerprint, "同配置同指纹")
        XCTAssertNotEqual(a.fingerprint, c.fingerprint, "换 key 指纹必须变")
        XCTAssertFalse(a.fingerprint.contains("k1"), "指纹不含明文 key")
        XCTAssertTrue(a.isConfigured)
        XCTAssertFalse(
            LLMProviderConfiguration(providerID: "p", baseURL: "", model: "m", apiKey: "k").isConfigured
        )
    }
}
