import XCTest
@testable import QiemanDashboard

// RES-7：Structured Generation 契约——LLM 输出只经 tool call arguments 的
// Codable 解码；纯文本 / Markdown 路径不存在。

/// 模拟真实输出形状的 fixture：snake_case 键 + 可选字段 + 嵌套数组 + 日期。
private struct ResearchNoteDraft: Codable, Equatable, Sendable {
    struct Claim: Codable, Equatable, Sendable {
        let statement: String
        let confidenceLabel: String
        let sourceHint: String?
    }

    let subject: String
    let noteId: String
    let observedAt: Date
    let claims: [Claim]
    let summary: String?
}

private func makeSchema() -> StructuredGenerationSchema {
    StructuredGenerationSchema(
        functionName: "submit_research_notes",
        description: "提交结构化研究笔记。",
        parameters: [
            "type": "object",
            "properties": [
                "subject": ["type": "string"],
                "note_id": ["type": "string"],
                "observed_at": ["type": "string", "format": "date-time"],
                "claims": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "statement": ["type": "string"],
                            "confidence_label": ["type": "string"],
                            "source_hint": ["type": "string"]
                        ],
                        "required": ["statement", "confidence_label"]
                    ]
                ],
                "summary": ["type": "string"]
            ],
            "required": ["subject", "note_id", "observed_at", "claims"]
        ]
    )
}

private func toolCallResponse(_ arguments: String) -> ModelCompletionResponse {
    ModelCompletionResponse(
        assistantMessage: ModelChatMessage(
            role: .assistant,
            content: nil,
            toolCalls: [ModelToolCall(id: "call-1", name: "submit_research_notes", argumentsJSON: arguments)]
        ),
        toolCalls: [ModelToolCall(id: "call-1", name: "submit_research_notes", argumentsJSON: arguments)],
        stopReason: .toolCalls,
        usage: nil
    )
}

final class StructuredGenerationTests: XCTestCase {

    func testRequestForcesFunctionToolChoice() {
        let request = StructuredGeneration.request(
            messages: [ModelChatMessage(role: .user, content: "提取研究笔记")],
            schema: makeSchema(),
            maxOutputTokens: 4096,
            purpose: "signalExtraction"
        )
        XCTAssertEqual(request.tools.map(\.name), ["submit_research_notes"])
        guard case .function(let name) = request.toolChoice else {
            return XCTFail("必须强制指定函数")
        }
        XCTAssertEqual(name, "submit_research_notes")
        XCTAssertEqual(request.maxOutputTokens, 4096)
        XCTAssertEqual(request.purpose, "signalExtraction")
    }

    func testDecodeSnakeCaseAndMillisecondDates() throws {
        let response = toolCallResponse("""
            {
              "subject": "513100",
              "note_id": "note-42",
              "observed_at": "2026-08-25T10:30:00.123Z",
              "claims": [
                {"statement": "溢价收窄", "confidence_label": "medium", "source_hint": "公告"},
                {"statement": "规模扩大", "confidence_label": "high"}
              ],
              "summary": null
            }
            """)
        let decoded = try StructuredGeneration.decode(response, as: ResearchNoteDraft.self, schema: makeSchema())
        XCTAssertEqual(decoded.subject, "513100")
        XCTAssertEqual(decoded.claims.count, 2)
        XCTAssertNil(decoded.claims[1].sourceHint)
        XCTAssertNil(decoded.summary)
        // 毫秒 ISO8601 解出的时间精确（UTC）
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 25
        components.hour = 10; components.minute = 30; components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        let expected = Calendar(identifier: .gregorian).date(from: components)!
        let delta: Double = decoded.observedAt.timeIntervalSince(expected)
        XCTAssertEqual(delta, 0.123, accuracy: 0.001)
    }

    func testDecodeAcceptsSecondPrecisionDates() throws {
        let response = toolCallResponse("""
            {"subject": "s", "note_id": "n", "observed_at": "2026-08-25T10:30:00Z", "claims": []}
            """)
        let decoded = try StructuredGeneration.decode(response, as: ResearchNoteDraft.self, schema: makeSchema())
        XCTAssertEqual(decoded.subject, "s")
        XCTAssertTrue(decoded.claims.isEmpty)
    }

    func testPlainTextResponseFailsClosedWithoutTextParsing() {
        // 模型无视工具要求返回了「看起来像 JSON」的纯文本——必须拒绝，
        // 不允许从 content 抠结构。
        let content = "{\"subject\": \"smuggled\"}"
        let response = ModelCompletionResponse(
            assistantMessage: ModelChatMessage(role: .assistant, content: content),
            toolCalls: [],
            stopReason: .stop,
            usage: nil
        )
        do {
            _ = try StructuredGeneration.decode(response, as: ResearchNoteDraft.self, schema: makeSchema())
            XCTFail("纯文本响应必须失败")
        } catch let error as StructuredGenerationError {
            guard case .missingStructuredOutput(let expected, let preview) = error else {
                return XCTFail("错误类型不对: \(error)")
            }
            XCTAssertEqual(expected, "submit_research_notes")
            XCTAssertEqual(preview, content)
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }

    func testUnexpectedFunctionRejected() {
        let response = ModelCompletionResponse(
            assistantMessage: ModelChatMessage(role: .assistant, content: nil, toolCalls: [
                ModelToolCall(id: "call-1", name: "web_search", argumentsJSON: "{}")
            ]),
            toolCalls: [ModelToolCall(id: "call-1", name: "web_search", argumentsJSON: "{}")],
            stopReason: .toolCalls,
            usage: nil
        )
        XCTAssertThrowsError(try StructuredGeneration.decode(response, as: ResearchNoteDraft.self, schema: makeSchema())) { error in
            guard case .unexpectedFunction(let expected, let actual) = error as? StructuredGenerationError else {
                return XCTFail("错误类型不对: \(error)")
            }
            XCTAssertEqual(expected, "submit_research_notes")
            XCTAssertEqual(actual, "web_search")
        }
    }

    func testMalformedJSONAndSchemaMismatchAreTypedErrors() {
        let malformed = toolCallResponse("not-json-at-all")
        XCTAssertThrowsError(try StructuredGeneration.decode(malformed, as: ResearchNoteDraft.self, schema: makeSchema())) { error in
            guard case .malformedJSON = error as? StructuredGenerationError else {
                return XCTFail("应是 malformedJSON: \(error)")
            }
        }

        // 合法 JSON 但缺 required 字段（claims）→ decodingFailed，detail 提到字段名。
        let missingField = toolCallResponse("""
            {"subject": "s", "note_id": "n", "observed_at": "2026-08-25T10:30:00Z"}
            """)
        XCTAssertThrowsError(try StructuredGeneration.decode(missingField, as: ResearchNoteDraft.self, schema: makeSchema())) { error in
            guard case .decodingFailed(_, let detail) = error as? StructuredGenerationError else {
                return XCTFail("应是 decodingFailed: \(error)")
            }
            XCTAssertTrue(detail.contains("claims"), "错误说明应点名缺失字段: \(detail)")
        }

        // 类型不匹配 → decodingFailed。
        let typeMismatch = toolCallResponse("""
            {"subject": "s", "note_id": "n", "observed_at": "2026-08-25T10:30:00Z", "claims": "not-an-array"}
            """)
        XCTAssertThrowsError(try StructuredGeneration.decode(typeMismatch, as: ResearchNoteDraft.self, schema: makeSchema())) { error in
            guard case .decodingFailed = error as? StructuredGenerationError else {
                return XCTFail("应是 decodingFailed: \(error)")
            }
        }

        // 非法日期 → decodingFailed（dataCorrupted 描述）。
        let badDate = toolCallResponse("""
            {"subject": "s", "note_id": "n", "observed_at": "yesterday", "claims": []}
            """)
        XCTAssertThrowsError(try StructuredGeneration.decode(badDate, as: ResearchNoteDraft.self, schema: makeSchema())) { error in
            guard case .decodingFailed(_, let detail) = error as? StructuredGenerationError else {
                return XCTFail("应是 decodingFailed: \(error)")
            }
            XCTAssertTrue(detail.contains("无法解析 ISO8601"), "detail: \(detail)")
        }
    }

    func testSchemaRoundTripsThroughCodable() throws {
        // schema 值自身 Codable 往返稳定（会被嵌进 Research Workspace 的
        // 配置持久化）。
        let schema = makeSchema()
        let encoder = JSONEncoder()
        let data = try encoder.encode(schema)
        let decoded = try JSONDecoder().decode(StructuredGenerationSchema.self, from: data)
        XCTAssertEqual(decoded, schema)
    }
}
