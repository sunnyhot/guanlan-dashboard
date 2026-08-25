import Foundation

// MARK: - Research Workspace（RES-2，V3.1 §100 Research 链入口）
//
// 一次研究任务的冻结输入（ResearchTask）与结构化产出（ResearchNotes）。
// Workspace 是「研究上下文」的值形态：Harness 消费 task 驱动多轮研究，
// 模型经提交工具产出 notes；notes 是自由 reasoning 的**结构化落点**，
// 不直接进系统状态——转 InvestmentSignal 是 RES-4（Signal Extraction，
// versioned SignalPolicy 约束）的事，中间还隔着 RES-5 validation pipeline。
//
// 身份纪律（对照 D004 / SubmitTrendReportTool 先例）：**模型不产身份字段**
// ——提交 payload 只含内容（叙述、claims、证据引用、自评充分度标签），
// producedBy / producedAt / task 由 Harness 从运行时状态注入。模型自报
// 时间或来源在解码层就没有通道。

/// 一次研究任务（Workspace 的冻结输入；确定性指纹参与 job 幂等）。
struct ResearchTask: Sendable, Codable, Hashable {
    /// 研究对象（标的 / 组合 / 市场）。
    let subject: CanonicalRef
    /// 研究目标（自然语言指令，进 system/user prompt）。
    let objective: String
    /// 额外约束 / 关注点（可选，进 prompt）。
    let guidance: String?

    init(subject: CanonicalRef, objective: String, guidance: String? = nil) {
        self.subject = subject
        self.objective = objective
        self.guidance = guidance
    }

    /// 输入指纹（同任务重跑 = 同 job；AgentJob 幂等键成分）。
    var inputFingerprint: String {
        StableDigest.digest("\(subject.entityType)|\(subject.entityIDRawValue)|\(objective)|\(guidance ?? "")")
    }
}

/// 模型自评的证据充分度（ordinal 标签——**不是 cardinal 置信数字**；
/// 铁律「LLM 不生成 Confidence 数字」在类型层的表现：没有数值通道）。
enum ResearchConfidenceLabel: String, Sendable, Codable, Hashable, CaseIterable {
    case high = "HIGH"
    case medium = "MEDIUM"
    case low = "LOW"
}

/// 研究笔记中的单条 claim（结构化事实陈述 + 证据引用 + 方向判断）。
struct ResearchClaim: Sendable, Codable, Hashable {
    /// 事实陈述（一句话）。
    let statement: String
    /// 支撑本 claim 的 evidence IDs（引用研究过程中工具登记的证据；
    /// 提交时经 Harness 校验必须全部在登记簿内——RES-8 Evidence Matcher
    /// 落地前的最低完整性门禁）。
    let evidenceReferences: [EvidenceID]
    /// 模型自评证据充分度。
    let confidenceLabel: ResearchConfidenceLabel
    /// 声明所属的信号维度（可选；RES-4 转 Signal 时的线索）。
    let dimension: SignalDimension?
    /// 研究方向判断（ordinal——非数值置信度；铁律允许 LLM 做 Event
    /// Interpretation / Thesis Formation，direction 是其结论形态）。
    /// 落地成 InvestmentSignal 前必须过 SignalExtractionPolicy 的证据
    /// 门槛（RES-4）：无证据方向强制 uncertain。
    let direction: SignalDirection?

    init(
        statement: String,
        evidenceReferences: [EvidenceID],
        confidenceLabel: ResearchConfidenceLabel,
        dimension: SignalDimension? = nil,
        direction: SignalDirection? = nil
    ) {
        self.statement = statement
        self.evidenceReferences = evidenceReferences
        self.confidenceLabel = confidenceLabel
        self.dimension = dimension
        self.direction = direction
    }
}

/// 研究笔记（Harness 的最终产出；RES-4 Signal Extraction 的输入）。
struct ResearchNotes: Sendable, Codable, Hashable {
    let task: ResearchTask
    /// 自由叙述（Thesis / Narrative 素材；不进 cardinal 运算）。
    let notes: String
    let claims: [ResearchClaim]
    /// 产出模型（Harness 注入，模型无法自报）。
    let producedBy: ModelProviderDescriptor
    /// 产出时间（Harness 注入）。
    let producedAt: Date

    /// 内容指纹（同内容同指纹；审计 / 幂等比对用，不含 producedAt）。
    var contentFingerprint: String {
        var payload: [String: String] = [
            "subject": "\(task.subject.entityType)|\(task.subject.entityIDRawValue)",
            "objective": task.objective,
            "guidance": task.guidance ?? "",
            "notes": notes,
        ]
        payload["claims"] = claims
            .map { claim in
                let refs = claim.evidenceReferences.map(\.rawValue).sorted().joined(separator: ",")
                return "\(claim.statement)|\(refs)|\(claim.confidenceLabel.rawValue)|\(claim.dimension?.rawValue ?? "")|\(claim.direction?.rawValue ?? "")"
            }
            .joined(separator: ";")
        payload["producer"] = "\(producedBy.providerID)|\(producedBy.model)|\(producedBy.fingerprint)"
        return StableDigest.digest(StableDigest.jsonPayloadOrString(payload))
    }
}

// MARK: - 提交契约（模型输出形状；身份字段不在其中）

/// 模型经提交工具返回的 payload 形状（RES-7 契约：snake_case 键）。
/// **只含内容字段**——task / producedBy / producedAt 由 Harness 注入。
/// 属性名必须满足「蛇形键转换后同名」：evidence_ids → evidenceIds。
struct ResearchNotesSubmission: Decodable, Sendable, Hashable {
    struct SubmittedClaim: Decodable, Sendable, Hashable {
        let statement: String
        let evidenceIds: [String]
        let confidenceLabel: String
        let dimension: String?
        let direction: String?
    }

    let notes: String
    let claims: [SubmittedClaim]

    /// ResearchNotes 提交 schema（显式手写，与 SubmittedClaim 字段成对维护；
    /// 命名遵守 convertFromSnakeCase 约定——evidenceReferences 不是 evidenceReferencesID 之类）。
    static let schema = StructuredGenerationSchema(
        functionName: "submit_research_notes",
        description: """
        提交结构化研究笔记。只能引用研究过程中工具结果里出现过的 evidence_id；\
        每条 claim 必须给出一到多个 evidence_id 与证据充分度自评。
        """,
        parameters: [
            "type": "object",
            "properties": [
                "notes": [
                    "type": "string",
                    "description": "整体研究叙述：核心发现、逻辑链与保留意见。"
                ],
                "claims": [
                    "type": "array",
                    "description": "结构化事实清单。",
                    "items": [
                        "type": "object",
                        "properties": [
                            "statement": ["type": "string", "description": "一句话事实陈述。"],
                            "evidence_ids": [
                                "type": "array",
                                "items": ["type": "string"],
                                "description": "支撑该陈述的 evidence_id 列表（只能用工具结果中出现过的）。"
                            ],
                            "confidence_label": [
                                "type": "string",
                                "enum": ["HIGH", "MEDIUM", "LOW"],
                                "description": "证据充分度自评。"
                            ],
                            "direction": [
                                "type": "string",
                                "enum": ["BULLISH", "BEARISH", "NEUTRAL", "UNCERTAIN"],
                                "description": "该陈述支持的研究方向判断（可选；无足够证据时给 UNCERTAIN）。"
                            ],
                            "dimension": [
                                "type": "string",
                                "enum": .array(SignalDimension.allCases.map { .string($0.rawValue) }),
                                "description": "所属信号维度（可选）。"
                            ]
                        ],
                        "required": ["statement", "evidence_ids", "confidence_label"]
                    ]
                ]
            ],
            "required": ["notes", "claims"]
        ]
    )
}

// MARK: - Harness 事件（研究过程可观察）

/// Harness 运行事件（进度 / 审计入口；App 层订阅展示）。
enum ResearchHarnessEvent: Sendable, Hashable {
    case started(task: ResearchTask, limits: String)
    case turnStarted(turn: Int)
    case toolExecuted(name: String, evidenceCount: Int, isError: Bool)
    case submissionRejected(detail: String, remainingAttempts: Int)
    case notesAccepted(claimCount: Int, evidenceCount: Int)
    case failed(detail: String)
    case cancelled
}

/// Harness 运行结果（job 状态机 + 产出 + 完整 transcript 供审计）。
struct ResearchRunOutcome: Sendable, Hashable {
    let job: AgentJob
    /// 成功时的研究笔记。
    let notes: ResearchNotes?
    /// 完整消息时间线（审计 / 复盘）。
    let transcript: [ModelChatMessage]
    /// failed 时的错误摘要。
    let errorDetail: String?

    var succeeded: Bool { job.state == .completed }
}

// MARK: - StableDigest 辅助

extension StableDigest {
    /// 便捷形态：编码失败退回扁平串（ResearchNotes 内容指纹的字典 payload
    /// 全是 String，理论上不会失败；保留显式行为）。
    static func jsonPayloadOrString(_ payload: [String: String]) -> String {
        (try? jsonPayload(payload)) ?? payload.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ";")
    }
}
