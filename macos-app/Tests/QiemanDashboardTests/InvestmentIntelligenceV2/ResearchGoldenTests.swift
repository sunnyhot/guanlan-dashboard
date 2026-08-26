import XCTest
@testable import QiemanDashboard

// RES-9：Research golden test 套件——固定 LLM mock 输出 → 固定 Signal。
//
// 锁定整条 Research 链的确定性：脚本化模型（工具调用 → 提交）→ Harness →
// EvidenceMatcher → ValidationPipeline → SignalExtractor → SignalStore，
// 同输入（含注入的 clock/now）必须产出字节级相同的 notes 指纹与 SignalID。
// golden 值写死字面量：任何输入细节或语义映射的变化都会在这里爆出来。
// 同时覆盖 Schema / EvidenceBinding / Freshness 三层校验的失败路径 golden。

private let goldenSubject = try! CanonicalRef(
    entityType: "fundShareClass", entityIDRawValue: "sc_513100"
)

private let goldenTask = ResearchTask(
    subject: goldenSubject,
    objective: "评估该标的动量与估值状态"
)

/// golden 提交 payload（工具产出 evidence EV-NAV-1 / EV-NAV-2）。
private let goldenSubmission = """
{"notes": "净值连续回升，动量改善，估值处于合理区间。", "claims": [
  {"statement": "净值连续三日回升", "evidence_ids": ["EV-NAV-1"], "confidence_label": "HIGH",
   "dimension": "MOMENTUM", "direction": "BULLISH"},
  {"statement": "估值处于近三年中位区间", "evidence_ids": ["EV-NAV-2"], "confidence_label": "MEDIUM",
   "dimension": "VALUE", "direction": "NEUTRAL"}
]}
"""

private func goldenHarnessInputs(
    evidence: [EvidenceID]
) -> (provider: ScriptedModelProvider, tool: StubResearchTool, gateway: ModelGateway) {
    let submitCall = ModelToolCall(
        id: "call-submit", name: "submit_research_notes", argumentsJSON: goldenSubmission
    )
    let dataCall = ModelToolCall(
        id: "call-data", name: "get_local_data", argumentsJSON: "{}"
    )
    let provider = ScriptedModelProvider(providerID: "golden-provider", model: "golden-model", steps: [
        .response(ModelCompletionResponse(
            assistantMessage: ModelChatMessage(role: .assistant, content: nil, toolCalls: [dataCall]),
            toolCalls: [dataCall], stopReason: .toolCalls, usage: nil
        )),
        .response(ModelCompletionResponse(
            assistantMessage: ModelChatMessage(role: .assistant, content: nil, toolCalls: [submitCall]),
            toolCalls: [submitCall], stopReason: .toolCalls, usage: nil
        )),
    ])
    let tool = StubResearchTool(
        name: "get_local_data",
        content: ["series": "nav"],
        evidence: evidence
    )
    var gatewayPolicy = ModelGatewayPolicy()
    gatewayPolicy.maxRetriesPerProvider = 0
    return (provider, tool, ModelGateway(providers: [provider], policy: gatewayPolicy))
}

final class ResearchGoldenTests: XCTestCase {

    private static let goldenClock: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }

    /// 全链路跑一遍（Harness → extractor → store）。
    private func runGoldenChain(
        evidence: [EvidenceID] = [EvidenceID(rawValue: "EV-NAV-1"), EvidenceID(rawValue: "EV-NAV-2")]
    ) async throws -> (outcome: ResearchRunOutcome, signals: [InvestmentSignal]) {
        let (provider, tool, gateway) = goldenHarnessInputs(evidence: evidence)
        let harness = ResearchHarness(
            gateway: gateway,
            tools: [tool],
            clock: Self.goldenClock
        )
        let outcome = try await harness.run(task: goldenTask)
        XCTAssertTrue(outcome.succeeded, outcome.errorDetail ?? "")
        let notes = try XCTUnwrap(outcome.notes)
        let signals = SignalExtractor().extract(from: notes, now: Self.goldenClock())
        return (outcome, signals)
    }

    // MARK: 主 golden：固定 mock → 固定 SignalID / 指纹

    func testGoldenHappyPathProducesFixedSignals() async throws {
        let (outcome, signals) = try await runGoldenChain()
        let notes = try XCTUnwrap(outcome.notes)

        // 固定的 notes 内容指纹（claims/direction/producer 全部参与）。
        XCTAssertEqual(notes.contentFingerprint, "1b5e93b6ee75b88f71a330fe68b5a6ef")

        // 两个维度两个信号；字段级 golden。
        XCTAssertEqual(signals.count, 2)
        let momentum = signals.first { $0.dimension == .momentum }
        let value = signals.first { $0.dimension == .value }
        XCTAssertNotNil(momentum)
        XCTAssertNotNil(value)
        XCTAssertEqual(momentum?.direction, .bullish)
        XCTAssertEqual(momentum?.strength, .strong)
        XCTAssertEqual(momentum?.derivedFromEvidenceIDs, [EvidenceID(rawValue: "EV-NAV-1")])
        XCTAssertEqual(value?.direction, .neutral)
        XCTAssertEqual(value?.strength, .moderate)
        XCTAssertEqual(value?.derivedFromEvidenceIDs, [EvidenceID(rawValue: "EV-NAV-2")])
        XCTAssertEqual(momentum?.producer.modelIdentifier, "golden-model")
        XCTAssertEqual(momentum?.effectiveAt, Date(timeIntervalSince1970: 1_800_000_000))

        // SignalID golden（确定性派生；任何身份成分变化在此爆出）。
        XCTAssertEqual(momentum?.id.rawValue, "sig_1a99a9c6c56c62c79ef2a5b56da89acb")
        XCTAssertEqual(value?.id.rawValue, "sig_1bddbbafaffa12437f899e307d0ab43b")
    }

    func testGoldenChainIsDeterministicAcrossRuns() async throws {
        // 同输入重跑：指纹、ID、方向、强度全等（RES 链端到端确定性）。
        let first = try await runGoldenChain()
        let second = try await runGoldenChain()
        XCTAssertEqual(first.outcome.notes?.contentFingerprint, second.outcome.notes?.contentFingerprint)
        XCTAssertEqual(first.signals.map(\.id), second.signals.map(\.id))
        XCTAssertEqual(first.signals.map(\.direction), second.signals.map(\.direction))
        XCTAssertEqual(first.signals.map(\.strength), second.signals.map(\.strength))
        XCTAssertEqual(first.signals.map(\.rationale), second.signals.map(\.rationale))
    }

    func testGoldenSignalsPersistAndQueryInSignalStore() async throws {
        let (_, signals) = try await runGoldenChain()
        let store = GRDBRepository(
            database: try CanonicalDatabase(),
            calendarBackend: TestWeekdayCalendar()
        )
        for signal in signals {
            try store.write(signal)
        }
        // subject 查询 + 溯源查询返回 golden 信号
        let bySubject = try store.signals(subject: goldenSubject)
        XCTAssertEqual(Set(bySubject.map(\.id)), Set(signals.map(\.id)))
        let viaEvidence = try store.signals(derivedFromEvidence: EvidenceID(rawValue: "EV-NAV-1"))
        XCTAssertEqual(viaEvidence.map(\.dimension), [.momentum])
    }

    // MARK: 校验失败路径 golden

    func testGoldenSchemaFailurePath() throws {
        // 空陈述 + 无 dimension：Schema 层 error 序列固定。
        let notes = try ResearchNotes(
            task: goldenTask,
            notes: "n",
            claims: [
                ResearchClaim(
                    statement: " ", evidenceReferences: [EvidenceID(rawValue: "EV-1")],
                    confidenceLabel: .high, dimension: nil, direction: nil
                )
            ],
            producedBy: ModelProviderDescriptor(providerID: "p", model: "m", fingerprint: "f"),
            producedAt: Self.goldenClock()
        )
        let result = ResearchValidationPipeline().validate(
            notes, now: Self.goldenClock(), knownEvidence: ["EV-1"]
        )
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.errors.map(\.code), ["empty_statement", "missing_dimension"])
        XCTAssertEqual(result.errors.map(\.validator), [.schema, .schema])
    }

    func testGoldenEvidenceBindingFailurePath() throws {
        // 引用未知 evidence（模型编造）：binding 层 error 详情固定。
        let notes = try ResearchNotes(
            task: goldenTask,
            notes: "n",
            claims: [
                ResearchClaim(
                    statement: "编造引用", evidenceReferences: [EvidenceID(rawValue: "EV-FORGED")],
                    confidenceLabel: .high, dimension: .momentum, direction: .bullish
                )
            ],
            producedBy: ModelProviderDescriptor(providerID: "p", model: "m", fingerprint: "f"),
            producedAt: Self.goldenClock()
        )
        // Matcher 拦截（M8 验收）
        XCTAssertEqual(
            EvidenceMatcher.unresolvedReferences(
                notes.claims.flatMap(\.evidenceReferences), corpus: ["EV-REAL"]
            ).map(\.rawValue),
            ["EV-FORGED"]
        )
        // 管道拒绝 + 详情点名
        let result = ResearchValidationPipeline().validate(
            notes, now: Self.goldenClock(), knownEvidence: ["EV-REAL"]
        )
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.errors.map(\.code), ["unresolved_evidence_reference"])
        XCTAssertTrue(result.errors[0].detail.contains("EV-FORGED"))
    }

    func testGoldenFreshnessFailurePath() throws {
        // producedAt 固定 25h 前：notes_stale error 详情固定。
        let staleTime = Self.goldenClock().addingTimeInterval(-25 * 3600)
        let notes = try ResearchNotes(
            task: goldenTask,
            notes: "n",
            claims: [
                ResearchClaim(
                    statement: "s", evidenceReferences: [EvidenceID(rawValue: "EV-1")],
                    confidenceLabel: .high, dimension: .momentum, direction: .bullish
                )
            ],
            producedBy: ModelProviderDescriptor(providerID: "p", model: "m", fingerprint: "f"),
            producedAt: staleTime
        )
        let result = ResearchValidationPipeline().validate(
            notes, now: Self.goldenClock(), knownEvidence: ["EV-1"]
        )
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.errors.map(\.code), ["notes_stale"])
        XCTAssertEqual(result.errors[0].validator, .freshness)
        XCTAssertEqual(result.errors[0].detail, "研究笔记产出已 25 小时，超过 24 小时上限")
    }

    // MARK: 提取降级路径 golden（策略语义锁定）

    func testGoldenExtractionDemotionPath() throws {
        // 无证据维度组不产信号（审查 P2-2：与 SignalStore 写入门禁对齐）。
        let notes = try ResearchNotes(
            task: goldenTask,
            notes: "n",
            claims: [
                ResearchClaim(
                    statement: "感觉要涨", evidenceReferences: [],
                    confidenceLabel: .high, dimension: .momentum, direction: .bullish
                )
            ],
            producedBy: ModelProviderDescriptor(providerID: "p", model: "m", fingerprint: "f"),
            producedAt: Self.goldenClock()
        )
        let signals = SignalExtractor().extract(from: notes, now: Self.goldenClock())
        XCTAssertTrue(signals.isEmpty, "无证据支撑的维度不产信号（不是信号，是叙述）")
    }
}

/// golden 套件自用的日历（SignalStore 测试里的同名实现是 private）。
