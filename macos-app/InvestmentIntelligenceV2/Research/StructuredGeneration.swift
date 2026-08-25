import Foundation

// MARK: - Structured Generation 契约（RES-7）
//
// 所有 LLM 结构化输出走「工具调用承载 JSON」：期望输出声明为一个提交工具
// 的参数 schema + `tool_choice` 强制该函数；模型返回的 tool call arguments
// 即结构化 payload，直接按 Codable 解码。
//
// **禁止 Markdown 再 parse**（rollout RES-7 验收）：本类型是 V2 内唯一的
// 「模型输出 → 领域对象」入口，只认 toolCalls 的 argumentsJSON——纯文本
// 响应（无 toolCalls）直接类型化失败（missingStructuredOutput），不存在
// 「从 content 里抠 JSON / 正则猜结构」的路径。解码失败的修复回灌由
// Harness 层（RES-2）承担，不属于本层。
//
// schema 显式手写（与输出 Codable 类型成对维护），不搞运行时反射生成：
// 反射对 enum 关联值 / Decimal / Date 的形状猜测会引入静默漂移，显式
// schema + golden test（RES-9）锁定「schema 声明与 Codable 字段一致」。
//
// **输出类型命名约定**：decoder 用 `convertFromSnakeCase`——连续大写缩写
// 会被坑（JSON `note_id` 转换为 `noteId`，不是 `noteID`）。输出类型的
// 属性名必须满足「蛇形键转换后与本属性同名」，缩写词一律首字母大写
//（noteId / observedAt / apiUrl）。

/// 一个结构化输出契约：提交工具名 + 参数 JSON Schema。
struct StructuredGenerationSchema: Sendable, Hashable, Codable {
    /// 提交工具名（如 "submit_research_notes"）。
    let functionName: String
    /// 提交动作的语义说明（进工具 description，模型据此理解输出要求）。
    let description: String
    /// 输出 payload 的 JSON Schema（object）。
    let parameters: ModelJSONValue

    init(functionName: String, description: String, parameters: ModelJSONValue) {
        self.functionName = functionName
        self.description = description
        self.parameters = parameters
    }

    var toolSpec: ModelToolSpec {
        ModelToolSpec(name: functionName, description: description, parameters: parameters)
    }
}

enum StructuredGenerationError: Error, Equatable, Sendable {
    /// 响应是纯文本（无 toolCalls）——不尝试从文本内容解析结构。
    case missingStructuredOutput(expectedFunction: String, contentPreview: String?)
    /// 模型调了别的工具（不是期望的提交函数）。
    case unexpectedFunction(expected: String, actual: String)
    /// tool call arguments 不是合法 JSON。
    case malformedJSON(functionName: String, detail: String)
    /// arguments 是合法 JSON 但不符合输出类型的 Codable 形状。
    case decodingFailed(functionName: String, detail: String)
}

enum StructuredGeneration {

    /// 构造结构化生成请求（强制指定函数的 tool_choice）。
    static func request(
        messages: [ModelChatMessage],
        schema: StructuredGenerationSchema,
        temperature: Double = 0.2,
        maxOutputTokens: Int? = nil,
        purpose: String
    ) -> ModelCompletionRequest {
        ModelCompletionRequest(
            messages: messages,
            tools: [schema.toolSpec],
            toolChoice: .function(name: schema.functionName),
            temperature: temperature,
            maxOutputTokens: maxOutputTokens,
            purpose: purpose
        )
    }

    /// 解码结构化响应：定位期望函数的 tool call → arguments JSON → Codable。
    /// 只认 toolCalls；content 文本永不参与解析。
    static func decode<Output: Decodable>(
        _ response: ModelCompletionResponse,
        as outputType: Output.Type,
        schema: StructuredGenerationSchema
    ) throws -> Output {
        guard let call = response.toolCalls.first else {
            throw StructuredGenerationError.missingStructuredOutput(
                expectedFunction: schema.functionName,
                contentPreview: response.assistantMessage.content.map { String($0.prefix(120)) }
            )
        }
        guard call.name == schema.functionName else {
            throw StructuredGenerationError.unexpectedFunction(
                expected: schema.functionName,
                actual: call.name
            )
        }
        guard let data = call.argumentsJSON.data(using: .utf8) else {
            throw StructuredGenerationError.malformedJSON(
                functionName: schema.functionName,
                detail: "arguments 不是有效 UTF-8"
            )
        }
        // 先验 JSON 合法性，再走 Codable——两类失败分别类型化
        //（malformedJSON 可回灌「输出合法 JSON」，decodingFailed 可回灌字段级错误）。
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw StructuredGenerationError.malformedJSON(
                functionName: schema.functionName,
                detail: "arguments 不是合法 JSON"
            )
        }
        do {
            return try decoder.decode(Output.self, from: data)
        } catch let error as DecodingError {
            throw StructuredGenerationError.decodingFailed(
                functionName: schema.functionName,
                detail: Self.describe(error)
            )
        } catch {
            throw StructuredGenerationError.decodingFailed(
                functionName: schema.functionName,
                detail: error.localizedDescription
            )
        }
    }

    /// 解码（用第一个工具调用；自动版，省 Output.self 样板）。
    static func decode<Output: Decodable>(
        _ response: ModelCompletionResponse,
        schema: StructuredGenerationSchema
    ) throws -> Output {
        try decode(response, as: Output.self, schema: schema)
    }

    /// 结构化输出的解码器：snake_case 键（与模型输出约定一致）+ 弹性
    /// ISO8601 日期（秒 / 毫秒都接受）。
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = Self.flexibleISO8601.date(from: raw)
                ?? Self.secondsISO8601.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "无法解析 ISO8601 日期：\(raw)"
            )
        }
        return decoder
    }()

    /// 秒 / 毫秒两种 ISO8601 形态。
    private static let flexibleISO8601: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static let secondsISO8601: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

}

extension StructuredGeneration {
    /// 解码错误的可读描述（复用 Core 的 AgentDecodingErrorFormatter——
    /// 字段级提示格式与三条旧 Agent 链一致，模型修复行为不因工作流漂移）。
    static func describe(_ error: DecodingError) -> String {
        AgentDecodingErrorFormatter.describe(error)
    }
}
