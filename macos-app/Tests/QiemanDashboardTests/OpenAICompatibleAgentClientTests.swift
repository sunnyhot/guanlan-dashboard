import XCTest
@testable import QiemanDashboard

// 阶段一：OpenAICompatibleAgentClient 传输层单元测试。
//
// 使用自定义 URLProtocol，禁止单元测试访问真实模型。
final class OpenAICompatibleAgentClientTests: XCTestCase {
    override func tearDown() {
        MockAgentURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testAgentDecodingErrorFormatterUsesStableFieldPath() throws {
        do {
            _ = try JSONDecoder().decode(
                DecodingFormatterFixture.self,
                from: Data(#"{"required":"wrong-type"}"#.utf8)
            )
            XCTFail("预期解码失败")
        } catch {
            XCTAssertEqual(
                AgentDecodingErrorFormatter.describe(error),
                "字段类型不匹配（路径：required）"
            )
            XCTAssertEqual(
                AgentDecodingErrorFormatter.describe(error, trailingPeriod: true),
                "字段类型不匹配（路径：required）。"
            )
        }
    }

    func testClientEncodesToolsAndToolChoice() async throws {
        let tool = AgentToolDefinition.function(
            name: "get_portfolio_overview",
            description: "取得组合基线。",
            parameters: ["type": "object", "properties": [:], "additionalProperties": false]
        )

        MockAgentURLProtocol.requestHandler = { request in
            let body = try Self.requestBodyData(request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "glm-5.2")
            XCTAssertEqual(json["temperature"] as? Double, 0.2)
            XCTAssertEqual(json["tool_choice"] as? String, "auto")
            XCTAssertEqual(json["stream"] as? Bool, true)
            let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
            XCTAssertEqual(tools.count, 1)
            let function = try XCTUnwrap(tools.first?["function"] as? [String: Any])
            XCTAssertEqual(function["name"] as? String, "get_portfolio_overview")

            return (Self.okResponse(for: request), Self.textMessageResponse(content: "ok"))
        }

        let client = OpenAICompatibleAgentClient(session: Self.mockSession())
        let result = try await client.complete(
            messages: [AgentChatMessage(role: .system, content: "s"), AgentChatMessage(role: .user, content: "u")],
            tools: [tool],
            toolChoice: .auto,
            temperature: 0.2,
            settings: providerSettings()
        )

        XCTAssertTrue(result.toolCalls.isEmpty)
        XCTAssertEqual(result.stopReason, .stop)
    }

    func testClientWritesCompleteModelRequestAndResponseToTaskLocalDiagnosticLog() async throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-client-log-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let recorder = try AIAgentDiagnosticRecorder(
            directoryURL: directoryURL,
            metadata: AIAgentDiagnosticRunMetadata(
                runID: UUID(),
                agentKind: "trend-research",
                scope: "closeReview",
                trigger: "manual",
                providerName: "Test",
                baseURL: "https://api.example.com/v1",
                model: "glm-5.2",
                privacyMode: "sanitized",
                startedAt: "2026-08-10 18:00:00"
            )
        )
        MockAgentURLProtocol.requestHandler = { request in
            (
                Self.okResponse(for: request),
                Self.textMessageResponse(content: "完整模型响应")
            )
        }

        let client = OpenAICompatibleAgentClient(session: Self.mockSession())
        _ = try await AIAgentDiagnosticLog.$recorder.withValue(recorder) {
            try await client.complete(
                messages: [
                    AgentChatMessage(role: .system, content: "完整系统提示词"),
                    AgentChatMessage(role: .user, content: "完整用户提示词"),
                    AgentChatMessage(
                        role: .assistant,
                        toolCalls: [
                            AgentToolCall(
                                id: "prior-call",
                                function: AgentToolFunctionCall(
                                    name: "web_search",
                                    arguments: #"{"api_key":"plain-secret-value","query":"测试"}"#
                                )
                            )
                        ]
                    ),
                ],
                tools: [],
                settings: providerSettings()
            )
        }

        let content = try String(contentsOf: recorder.fileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("model_request"))
        XCTAssertTrue(content.contains("model_response"))
        XCTAssertTrue(content.contains("完整系统提示词"))
        XCTAssertTrue(content.contains("完整用户提示词"))
        XCTAssertTrue(content.contains("完整模型响应"))
        XCTAssertFalse(content.contains("sk-test"))
        XCTAssertFalse(content.contains("plain-secret-value"))
    }

    func testClientDecodesContentNullWithToolCalls() async throws {
        let responseData = try JSONSerialization.data(withJSONObject: [
            "choices": [
                [
                    "finish_reason": "tool_calls",
                    "message": [
                        "role": "assistant",
                        "content": NSNull(),
                        "tool_calls": [
                            [
                                "id": "call_1",
                                "type": "function",
                                "function": ["name": "get_portfolio_assets", "arguments": "{\"limit\":20}"]
                            ]
                        ]
                    ]
                ]
            ]
        ])

        MockAgentURLProtocol.requestHandler = { request in
            (Self.okResponse(for: request), responseData)
        }

        let client = OpenAICompatibleAgentClient(session: Self.mockSession())
        let result = try await client.complete(
            messages: [AgentChatMessage(role: .user, content: "u")],
            tools: [],
            toolChoice: .auto,
            settings: providerSettings()
        )

        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.id, "call_1")
        XCTAssertEqual(result.toolCalls.first?.function.name, "get_portfolio_assets")
        XCTAssertEqual(result.toolCalls.first?.function.arguments, "{\"limit\":20}")
        XCTAssertEqual(result.stopReason, .toolCalls)
        XCTAssertEqual(result.finishReason, "tool_calls")
        XCTAssertNil(result.assistantMessage.content)
    }

    func testClientDecodesStreamingContentAndFragmentedToolCalls() async throws {
        let stream = """
        : keep-alive

        data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"先读取"},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{"content":"数据","tool_calls":[{"index":0,"id":"call_stream_1","type":"function","function":{"name":"web_","arguments":"{\\\"query\\\":"}}]},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"name":"search","arguments":"\\\"最新政策\\\"}"}}]},"finish_reason":null}]}

        data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5}}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """

        MockAgentURLProtocol.requestHandler = { request in
            (
                Self.okResponse(for: request, contentType: "text/event-stream; charset=utf-8"),
                Data(stream.utf8)
            )
        }

        let client = OpenAICompatibleAgentClient(session: Self.mockSession())
        let result = try await client.complete(
            messages: [AgentChatMessage(role: .user, content: "u")],
            tools: [],
            toolChoice: .auto,
            settings: providerSettings()
        )

        XCTAssertEqual(result.assistantMessage.content, "先读取数据")
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.id, "call_stream_1")
        XCTAssertEqual(result.toolCalls.first?.function.name, "web_search")
        XCTAssertEqual(result.toolCalls.first?.function.arguments, #"{"query":"最新政策"}"#)
        XCTAssertEqual(result.stopReason, .toolCalls)
        XCTAssertEqual(result.finishReason, "tool_calls")
    }

    func testClientDetectsEventStreamWhenProxyOmitsSSEContentType() async throws {
        let stream = """
        data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"兼容成功"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        MockAgentURLProtocol.requestHandler = { request in
            (Self.okResponse(for: request), Data(stream.utf8))
        }

        let client = OpenAICompatibleAgentClient(session: Self.mockSession())
        let result = try await client.complete(
            messages: [AgentChatMessage(role: .user, content: "u")],
            tools: [],
            toolChoice: .auto,
            settings: providerSettings()
        )

        XCTAssertEqual(result.assistantMessage.content, "兼容成功")
        XCTAssertEqual(result.stopReason, .stop)
    }

    func testClientEncodesAssistantToolCallAndToolResultMessages() async throws {
        let assistantMessage = AgentChatMessage(
            role: .assistant,
            content: nil,
            toolCalls: [AgentToolCall(id: "call_1", function: AgentToolFunctionCall(name: "get_x", arguments: "{}"))]
        )
        let toolMessage = AgentChatMessage(role: .tool, content: "{\"ok\":true}", toolCallID: "call_1")

        MockAgentURLProtocol.requestHandler = { request in
            let body = try Self.requestBodyData(request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])

            let assistant = try XCTUnwrap(messages.first { $0["role"] as? String == "assistant" })
            let toolCalls = try XCTUnwrap(assistant["tool_calls"] as? [[String: Any]])
            XCTAssertEqual(toolCalls.count, 1)
            XCTAssertEqual(toolCalls.first?["id"] as? String, "call_1")

            let tool = try XCTUnwrap(messages.first { $0["role"] as? String == "tool" })
            XCTAssertEqual(tool["content"] as? String, "{\"ok\":true}")
            XCTAssertEqual(tool["tool_call_id"] as? String, "call_1")

            return (Self.okResponse(for: request), Self.textMessageResponse(content: "done"))
        }

        let client = OpenAICompatibleAgentClient(session: Self.mockSession())
        _ = try await client.complete(
            messages: [
                AgentChatMessage(role: .user, content: "u"),
                assistantMessage,
                toolMessage
            ],
            tools: [],
            toolChoice: .auto,
            settings: providerSettings()
        )
    }

    func testPlainTextResponseHasNoToolCalls() async throws {
        MockAgentURLProtocol.requestHandler = { request in
            (Self.okResponse(for: request), Self.textMessageResponse(content: "只是一段普通文本"))
        }

        let client = OpenAICompatibleAgentClient(session: Self.mockSession())
        let result = try await client.complete(
            messages: [AgentChatMessage(role: .user, content: "u")],
            tools: [],
            toolChoice: .auto,
            settings: providerSettings()
        )

        XCTAssertTrue(result.toolCalls.isEmpty)
        XCTAssertEqual(result.stopReason, .stop)
        XCTAssertEqual(result.assistantMessage.content, "只是一段普通文本")
    }

    func testHTTPAndTimeoutFailuresMapToReadableErrors() async throws {
        let client = OpenAICompatibleAgentClient(session: Self.mockSession())
        let settings = providerSettings()
        let messages = [AgentChatMessage(role: .user, content: "u")]

        // 429 余额不足
        MockAgentURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!,
             #"{"error":{"code":"1113","message":"余额不足或无可用资源包"}}"#.data(using: .utf8)!)
        }
        do {
            _ = try await client.complete(messages: messages, tools: [], toolChoice: .auto, settings: settings)
            XCTFail("Expected 429")
        } catch let error as OpenAICompatibleAgentClientError {
            XCTAssertTrue(error.localizedDescription.contains("余额不足"))
        }

        // 429 限流
        MockAgentURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!,
             #"{"error":{"code":"1302","message":"Rate limit reached"}}"#.data(using: .utf8)!)
        }
        do {
            _ = try await client.complete(messages: messages, tools: [], toolChoice: .auto, settings: settings)
            XCTFail("Expected 429")
        } catch let error as OpenAICompatibleAgentClientError {
            XCTAssertTrue(error.localizedDescription.contains("请求频率"))
        }

        // 500
        MockAgentURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
             Data())
        }
        do {
            _ = try await client.complete(messages: messages, tools: [], toolChoice: .auto, settings: settings)
            XCTFail("Expected 500")
        } catch let error as OpenAICompatibleAgentClientError {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 500"))
        }

        // 超时
        MockAgentURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }
        do {
            _ = try await client.complete(messages: messages, tools: [], toolChoice: .auto, settings: settings)
            XCTFail("Expected timeout")
        } catch let error as OpenAICompatibleAgentClientError {
            if case .timedOut = error {
                // expected
            } else {
                XCTFail("Expected timedOut, got \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("超时"))
        }

        // 非法响应体
        MockAgentURLProtocol.requestHandler = { request in
            (Self.okResponse(for: request), "not-json".data(using: .utf8)!)
        }
        do {
            _ = try await client.complete(messages: messages, tools: [], toolChoice: .auto, settings: settings)
            XCTFail("Expected invalid response")
        } catch let error as OpenAICompatibleAgentClientError {
            XCTAssertTrue(error.localizedDescription.contains("OpenAI-compatible"))
        }
    }

    func testCapabilityProbeSucceedsOnlyWithRealToolCall() async throws {
        let probeCall: [String: Any] = [
            "id": "probe_1",
            "type": "function",
            "function": ["name": "agent_capability_probe", "arguments": "{}"]
        ]

        // 场景 A：指定函数 tool_choice 直接命中探针工具调用。
        MockAgentURLProtocol.requestHandler = { request in
            (Self.okResponse(for: request), Self.toolCallResponse(toolCalls: [probeCall], finishReason: "tool_calls"))
        }
        let clientA = OpenAICompatibleAgentClient(session: Self.mockSession())
        let capsA = try await clientA.checkToolCallingCapability(settings: providerSettings())
        XCTAssertTrue(capsA.supportsToolCalls)
        XCTAssertTrue(capsA.supportsForcedToolChoice)

        // 场景 B：指定函数 tool_choice 被供应商拒绝（400），退回 auto 仍只返回普通文本。
        MockAgentURLProtocol.requestHandler = { request in
            let body = try Self.requestBodyData(request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            if json["tool_choice"] is String {
                // auto 退回：只返回普通文本
                return (Self.okResponse(for: request), Self.textMessageResponse(content: "我不调用工具"))
            }
            // 指定函数 tool_choice：供应商 400
            throw ResponseError(statusCode: 400, body: #"{"error":{"message":"tool_choice function not supported"}}"#.data(using: .utf8)!)
        }
        let clientB = OpenAICompatibleAgentClient(session: Self.mockSession())
        let capsB = try await clientB.checkToolCallingCapability(settings: providerSettings())
        XCTAssertFalse(capsB.supportsToolCalls)
        XCTAssertFalse(capsB.supportsForcedToolChoice)
        XCTAssertTrue(capsB.detail.contains("不支持内嵌 Agent"))
    }

    // MARK: - Helpers

    private func providerSettings() -> TrendAIProviderSettings {
        TrendAIProviderSettings(
            providerName: "Test",
            baseURL: "https://api.example.com/v1",
            model: "glm-5.2",
            apiKey: "sk-test",
            timeoutSeconds: 15
        )
    }

    private static func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockAgentURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func okResponse(
        for request: URLRequest,
        contentType: String = "application/json"
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]
        )!
    }

    private static func textMessageResponse(content: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": content]]]])
    }

    private static func toolCallResponse(toolCalls: [[String: Any]], finishReason: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "choices": [["finish_reason": finishReason, "message": ["role": "assistant", "content": NSNull(), "tool_calls": toolCalls]]]
        ])
    }

    private static func requestBodyData(_ request: URLRequest) throws -> Data {
        if let httpBody = request.httpBody {
            return httpBody
        }
        guard let stream = request.httpBodyStream else {
            XCTFail("Expected request body")
            return Data()
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 {
                throw stream.streamError ?? URLError(.cannotDecodeContentData)
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }
}

private struct DecodingFormatterFixture: Decodable {
    let required: [Int]
}

private struct ResponseError: Error {
    let statusCode: Int
    let body: Data
}

private final class MockAgentURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let result = try handler(request)
            switch result {
            case (let response, let data):
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch let responseError as ResponseError {
            // 用 HTTP 响应 + 非成功状态码模拟供应商错误，便于客户端读取 body。
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: responseError.statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseError.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            // 网络层错误（如超时）直接抛给 URLSession。
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
