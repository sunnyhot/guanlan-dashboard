import XCTest
@testable import QiemanDashboard

// WF-1：Portfolio Research Workflow 全链路测试。
//
// 脚本化模型（工具调用 → 提交）驱动完整链：Research → evidence 落库 →
// 校验 → Signal 提取落库 → Thesis 合成落库 → Decision 组装（过
// DecisionValidator）→ artifact 落库。锁定：
// - 全链确定性（同输入重跑 → 同 artifact ID，全 store 幂等 no-op）
// - 各 store 的跨运行可查性（evidence / signals / theses / artifact）
// - 失败路径（研究失败 / 校验拒绝）不落半截状态
// - GRDB 与 InMemory store parity

private let wfClock: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_900_000_000) }

private let wfAssetSubject = try! CanonicalRef(
    entityType: "fundShareClass", entityIDRawValue: "sc_wf_asset"
)
private let wfPortfolioSubject = try! CanonicalRef(
    entityType: "fundShareClass", entityIDRawValue: "sc_wf_portfolio"
)

/// 两个任务的标准提交（引用工具产 evidence EV-WF-1 / EV-WF-2）。
private let wfSubmission = """
{"notes": "动量改善，估值中性。", "claims": [
  {"statement": "净值连续回升", "evidence_ids": ["EV-WF-1"], "confidence_label": "HIGH",
   "dimension": "MOMENTUM", "direction": "BULLISH"},
  {"statement": "估值处于中位区间", "evidence_ids": ["EV-WF-2"], "confidence_label": "MEDIUM",
   "dimension": "VALUE", "direction": "NEUTRAL"}
]}
"""

/// artifact 落库收集器（替代 GRDB sink 的轻量形态）。
private final class ArtifactSinkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [PortfolioDecisionArtifact] = []

    func sink(_ artifact: PortfolioDecisionArtifact) throws {
        lock.lock()
        defer { lock.unlock() }
        collected.append(artifact)
    }

    var artifacts: [PortfolioDecisionArtifact] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}

/// 决策材料 mock：costIntensity(plan.turnover，低者优先)+ 两方案
/// userDirective（A Δw=0.05 / B Δw=−0.15 → cost 差 0.1 超带 → A 胜）。
private struct MockDecisionMaterialsProvider: PortfolioDecisionMaterialsProviding {
    let day = wfClock()

    private func d(_ s: String) -> Decimal { Decimal(string: s)! }

    func materials(asOf: Date) throws -> PortfolioDecisionMaterials {
        let definition = CriterionDefinition(
            id: "costIntensity", version: "v1", evaluatorKind: .weightedSum,
            inputReferences: [CriterionDefinition.InputReference(
                kind: .planMetric, referenceID: PlanMetrics.turnover, weight: 1)],
            unit: .ratio,
            higherIsBetter: false
        )
        let band = IndifferenceBand(
            policyID: "wf-band", version: "v1", defaultBand: d("0.01"),
            rationale: "WF-1 测试带"
        )
        let portfolio = PortfolioSnapshot(asOf: day, positions: [
            PortfolioPosition(
                subjectKey: "listing|A", assetClass: .equity,
                weight: Ratio(value: d("0.5"))
            ),
        ])
        func run(delta: String, directiveID: String) -> DecisionReplayer.PlannerRun {
            DecisionReplayer.PlannerRun(
                portfolio: portfolio,
                target: nil,
                remediationTargets: [],
                userDirectives: [
                    UserDirectiveInput(
                        subjectKey: "listing|A", deltaWeight: Ratio(value: d(delta)),
                        directiveID: directiveID, note: nil
                    )
                ],
                actionDomain: ActionDomain(
                    perSubjectBounds: [
                        "listing|A": .init(
                            lower: Ratio(value: d("-1")), upper: Ratio(value: d("1"))
                        )
                    ],
                    eligibleNewSubjects: [:],
                    builderVersion: "wf-test",
                    newSubjectBuyUpper: Ratio(value: d("1"))
                ),
                plannerParameters: TargetRebalancePlanner.Parameters()
            )
        }
        return PortfolioDecisionMaterials(
            replayerMaterials: DecisionReplayer.ReplayMaterials(
                criterionDefinitions: [definition.fingerprint: definition],
                factorSnapshots: [:],
                observations: [:],
                band: band
            ),
            plannerRuns: [
                "A": run(delta: "0.05", directiveID: "u-A"),
                "B": run(delta: "-0.15", directiveID: "u-B"),
            ],
            target: nil,
            knowledgeContextSummary: "economicKnowledge(\(Int(day.timeIntervalSince1970)))"
        )
    }
}

final class PortfolioResearchWorkflowTests: XCTestCase {

    private var evidence: [EvidenceID] {
        [EvidenceID(rawValue: "EV-WF-1"), EvidenceID(rawValue: "EV-WF-2")]
    }

    /// 标准两任务输入（asset + portfolio，提交脚本相同——evidence 相同，
    /// 但任务主体不同 → 两个 notes、两个 thesis）。
    private func makeInput() throws -> PortfolioResearchWorkflow.Input {
        PortfolioResearchWorkflow.Input(
            portfolioSubject: wfPortfolioSubject,
            assetTasks: [
                ResearchTask(subject: wfAssetSubject, objective: "资产级研究")
            ],
            portfolioTask: ResearchTask(subject: wfPortfolioSubject, objective: "组合级研究")
        )
    }

    /// 脚本化 provider：两任务按序消费 4 步（每任务：工具 → 提交）。
    private func makeProvider() -> ScriptedModelProvider {
        let submitCall = ModelToolCall(
            id: "call-submit", name: "submit_research_notes", argumentsJSON: wfSubmission
        )
        func scriptedTurns() -> [ScriptedModelProvider.Step] {
            [.response(toolCallResponse([(name: "get_local_data", args: "{}")])),
             .response(ModelCompletionResponse(
                assistantMessage: ModelChatMessage(role: .assistant, content: nil, toolCalls: [submitCall]),
                toolCalls: [submitCall], stopReason: .toolCalls, usage: nil))]
        }
        return ScriptedModelProvider(
            providerID: "wf-provider", model: "wf-model",
            steps: scriptedTurns() + scriptedTurns()
        )
    }

    /// 完整 workflow（harness 复用同一脚本 provider：两任务按序消费 4 步）。
    private func makeWorkflow(
        repository: GRDBRepository, sink: ArtifactSinkCollector
    ) -> PortfolioResearchWorkflow {
        let harness = ResearchHarness(
            gateway: ModelGateway(
                providers: [makeProvider()],
                policy: {
                    var policy = ModelGatewayPolicy()
                    policy.maxRetriesPerProvider = 0
                    return policy
                }()
            ),
            tools: [StubResearchTool(
                name: "get_local_data", content: ["series": "nav"], evidence: evidence
            )],
            clock: wfClock
        )
        return PortfolioResearchWorkflow(
            dependencies: PortfolioResearchWorkflow.Dependencies(
                harness: harness,
                signalStore: repository,
                thesisStore: repository,
                evidenceStore: repository,
                decisionMaterials: MockDecisionMaterialsProvider(),
                artifactSink: { artifact in try sink.sink(artifact) }
            ),
            clock: wfClock
        )
    }

    // MARK: - 全链 happy path

    func testFullChainProducesArtifactAndPersistsAllStores() async throws {
        let repository = GRDBRepository(
            database: try CanonicalDatabase(), calendarBackend: TestWeekdayCalendar()
        )
        let sink = ArtifactSinkCollector()
        let workflow = makeWorkflow(repository: repository, sink: sink)

        let outcome = try await workflow.run(input: makeInput())

        XCTAssertTrue(outcome.succeeded, outcome.errorDetail ?? "")
        XCTAssertEqual(outcome.job.state, .completed)

        // Research：两任务两 notes → 4 signals（每任务 MOMENTUM + VALUE）
        XCTAssertEqual(outcome.signals.count, 4)
        // Thesis：1 asset + 1 portfolio
        XCTAssertEqual(outcome.theses.count, 2)
        let assetThesis = outcome.theses.first { $0.kind == .asset }
        let portfolioThesis = outcome.theses.first { $0.kind == .portfolio }
        XCTAssertEqual(assetThesis?.subject, wfAssetSubject)
        XCTAssertEqual(portfolioThesis?.subject, wfPortfolioSubject)
        XCTAssertEqual(
            Set(assetThesis?.supportingEvidenceIDs ?? []),
            Set(evidence)
        )

        // Decision：A 方案 cost 更低 → singlePreferred A
        XCTAssertEqual(outcome.artifact?.decision.status, .singlePreferred)
        XCTAssertEqual(outcome.artifact?.decision.admissiblePlans, ["A"])
        // artifact 引用的 signals = 本次研究产出（真实 Research 喂 Decision）
        XCTAssertEqual(
            Set(outcome.artifact?.signalIDs ?? []),
            Set(outcome.signals.map(\.id))
        )
        XCTAssertEqual(sink.artifacts.count, 1)

        // ---- 跨运行可查（GRDB store 层）----

        // evidence：两个 EvidenceID 各一条本体，主体锚定到任务主体
        let knownEvidence = try repository.knownEvidenceIDs()
        XCTAssertEqual(knownEvidence, Set(evidence.map(\.rawValue)))
        for (evidenceID, subject) in [
            (EvidenceID(rawValue: "EV-WF-1"), wfAssetSubject),
            (EvidenceID(rawValue: "EV-WF-2"), wfAssetSubject),
        ] {
            let observations = try repository.observations(evidenceID: evidenceID)
            // 同 evidence 被两个任务各登记一次 → 同 ID 幂等 no-op
            XCTAssertEqual(observations.count, 1)
            XCTAssertEqual(observations.first?.subjectCanonical, subject)
        }

        // signals：按主体可查（每主体 2 条）
        let assetSignals = try repository.signals(subject: wfAssetSubject)
        XCTAssertEqual(
            Set(assetSignals.map(\.id)),
            Set(outcome.signals.filter { $0.subjectCanonical == wfAssetSubject }.map(\.id))
        )

        // theses：kind + subject 查询
        let storedAsset = try repository.theses(kind: .asset, subject: wfAssetSubject)
        XCTAssertEqual(storedAsset.map(\.id), [assetThesis?.id])
        XCTAssertEqual(storedAsset.first?.linkedSignalIDs.count, 2)
        let storedPortfolio = try repository.theses(kind: .portfolio, subject: wfPortfolioSubject)
        XCTAssertEqual(storedPortfolio.map(\.id), [portfolioThesis?.id])
        // portfolio thesis 聚合 asset thesis 的证据与信号
        XCTAssertEqual(
            Set(storedPortfolio.first?.supportingEvidenceIDs ?? []),
            Set(evidence)
        )
        XCTAssertEqual(storedPortfolio.first?.linkedSignalIDs.count, 4)

        // artifact 落库读回全等
        let artifact = try XCTUnwrap(outcome.artifact)
        try repository.writeArtifact(artifact) // 已写过的语义重复（幂等验证）
        let readBack = try repository.portfolioDecision(id: artifact.id.rawValue)
        XCTAssertEqual(readBack, artifact)
    }

    // MARK: - 确定性与幂等

    func testIdempotentRerunProducesSameArtifactAndNoConflicts() async throws {
        let repository = GRDBRepository(
            database: try CanonicalDatabase(), calendarBackend: TestWeekdayCalendar()
        )
        let sink = ArtifactSinkCollector()
        let input = try makeInput()

        let first = try await makeWorkflow(
            repository: repository, sink: sink
        ).run(input: input)
        XCTAssertTrue(first.succeeded, first.errorDetail ?? "")
        // 第二次跑（脚本 provider 是一次性的，重建 workflow；store 共享）：
        // evidence / signals / theses / artifact 全部幂等（信号 ID 由内容
        // 派生、不含时间；决策材料固定）——同 artifact ID、无 conflict
        let second = try await makeWorkflow(
            repository: repository, sink: sink
        ).run(input: input)
        XCTAssertTrue(second.succeeded, second.errorDetail ?? "")
        XCTAssertEqual(first.artifact?.id, second.artifact?.id)
        XCTAssertEqual(
            first.signals.map(\.id).sorted(by: { $0.rawValue < $1.rawValue }),
            second.signals.map(\.id).sorted(by: { $0.rawValue < $1.rawValue })
        )
        XCTAssertEqual(first.theses.map(\.id).sorted(), second.theses.map(\.id).sorted())
        XCTAssertEqual(sink.artifacts.count, 2) // sink 是收集器（每次都收）
        // store 层不重复：evidence 仍 2 条、signals 仍 4 条
        XCTAssertEqual(try repository.knownEvidenceIDs().count, 2)
        XCTAssertEqual(try repository.signals(subject: wfAssetSubject).count, 2)
        XCTAssertEqual(try repository.signals(subject: wfPortfolioSubject).count, 2)
        XCTAssertEqual(
            Set(try repository.theses(kind: .asset, subject: wfAssetSubject).map(\.id)),
            Set(first.theses.filter { $0.kind == .asset }.map(\.id))
        )
    }

    // MARK: - 失败路径

    func testResearchFailureFailsJobWithoutSideEffects() async throws {
        let repository = GRDBRepository(
            database: try CanonicalDatabase(), calendarBackend: TestWeekdayCalendar()
        )
        // 纯文本响应（不发起工具调用）超过容忍上限 → harness fail
        let provider = ScriptedModelProvider(
            providerID: "wf-lazy", model: "wf-model",
            steps: [.response(textResponse("我不研究"))]
        )
        var gatewayPolicy = ModelGatewayPolicy()
        gatewayPolicy.maxRetriesPerProvider = 0
        let harness = ResearchHarness(
            gateway: ModelGateway(providers: [provider], policy: gatewayPolicy),
            tools: [StubResearchTool(name: "get_local_data", evidence: evidence)],
            policy: {
                var policy = ResearchHarnessPolicy()
                policy.maxPlainTextResponses = 1
                return policy
            }(),
            clock: wfClock
        )
        let sink = ArtifactSinkCollector()
        let workflow = PortfolioResearchWorkflow(
            dependencies: PortfolioResearchWorkflow.Dependencies(
                harness: harness,
                signalStore: repository,
                thesisStore: repository,
                evidenceStore: repository,
                decisionMaterials: MockDecisionMaterialsProvider(),
                artifactSink: { artifact in try sink.sink(artifact) }
            ),
            clock: wfClock
        )
        let outcome = try await workflow.run(input: try makeInput())

        XCTAssertEqual(outcome.job.state, .failed)
        XCTAssertNotNil(outcome.errorDetail)
        XCTAssertTrue(outcome.signals.isEmpty)
        XCTAssertTrue(outcome.theses.isEmpty)
        XCTAssertNil(outcome.artifact)
        XCTAssertTrue(sink.artifacts.isEmpty)
        // 无半截状态：signal / thesis / evidence 全空
        XCTAssertTrue(try repository.signals(subject: wfAssetSubject).isEmpty)
        XCTAssertTrue(try repository.knownEvidenceIDs().isEmpty)
        XCTAssertTrue(try repository.theses(kind: .asset, subject: wfAssetSubject).isEmpty)
    }

    func testValidationRejectionFailsJob() async throws {
        let repository = GRDBRepository(
            database: try CanonicalDatabase(), calendarBackend: TestWeekdayCalendar()
        )
        // 空 claims：Harness 提交门禁不拒（形状合法），Workflow 的
        // SchemaValidator（empty_claims）拒绝 → job failed
        let emptyClaimsSubmission = """
        {"notes": "无结构化结论", "claims": []}
        """
        let submitCall = ModelToolCall(
            id: "call-submit", name: "submit_research_notes",
            argumentsJSON: emptyClaimsSubmission
        )
        let provider = ScriptedModelProvider(providerID: "wf-empty", model: "wf-model", steps: [
            .response(toolCallResponse([(name: "get_local_data", args: "{}")])),
            .response(ModelCompletionResponse(
                assistantMessage: ModelChatMessage(role: .assistant, content: nil, toolCalls: [submitCall]),
                toolCalls: [submitCall], stopReason: .toolCalls, usage: nil)),
            .response(toolCallResponse([(name: "get_local_data", args: "{}")])),
            .response(ModelCompletionResponse(
                assistantMessage: ModelChatMessage(role: .assistant, content: nil, toolCalls: [submitCall]),
                toolCalls: [submitCall], stopReason: .toolCalls, usage: nil)),
        ])
        var gatewayPolicy = ModelGatewayPolicy()
        gatewayPolicy.maxRetriesPerProvider = 0
        let harness = ResearchHarness(
            gateway: ModelGateway(providers: [provider], policy: gatewayPolicy),
            tools: [StubResearchTool(name: "get_local_data", evidence: evidence)],
            clock: wfClock
        )
        let sink = ArtifactSinkCollector()
        let workflow = PortfolioResearchWorkflow(
            dependencies: PortfolioResearchWorkflow.Dependencies(
                harness: harness,
                signalStore: repository,
                thesisStore: repository,
                evidenceStore: repository,
                decisionMaterials: MockDecisionMaterialsProvider(),
                artifactSink: { artifact in try sink.sink(artifact) }
            ),
            clock: wfClock
        )
        let outcome = try await workflow.run(input: try makeInput())

        XCTAssertEqual(outcome.job.state, .failed)
        XCTAssertTrue(outcome.errorDetail?.contains("empty_claims") ?? false)
        XCTAssertTrue(sink.artifacts.isEmpty)
        // evidence 已落（阶段先于校验）但 signals / theses / artifact 无
        XCTAssertEqual(try repository.knownEvidenceIDs().count, 2)
        XCTAssertTrue(try repository.signals(subject: wfAssetSubject).isEmpty)
    }

    // MARK: - Decision 材料预检

    func testEmptyPlannerRunsFailsWithReadableError() async throws {
        struct EmptyMaterialsProvider: PortfolioDecisionMaterialsProviding {
            func materials(asOf: Date) throws -> PortfolioDecisionMaterials {
                PortfolioDecisionMaterials(
                    replayerMaterials: DecisionReplayer.ReplayMaterials(
                        criterionDefinitions: [:], factorSnapshots: [:],
                        observations: [:],
                        band: IndifferenceBand(
                            policyID: "b", version: "v1",
                            defaultBand: Decimal(string: "0.01")!, rationale: "r"
                        )
                    ),
                    plannerRuns: [:],
                    target: nil,
                    knowledgeContextSummary: "k"
                )
            }
        }
        let repository = GRDBRepository(
            database: try CanonicalDatabase(), calendarBackend: TestWeekdayCalendar()
        )
        let provider = ScriptedModelProvider(providerID: "wf-ok", model: "wf-model", steps: [
            .response(toolCallResponse([(name: "get_local_data", args: "{}")])),
            .response(ModelCompletionResponse(
                assistantMessage: ModelChatMessage(role: .assistant, content: nil, toolCalls: [
                    ModelToolCall(
                        id: "call-submit", name: "submit_research_notes",
                        argumentsJSON: wfSubmission
                    )
                ]),
                toolCalls: [
                    ModelToolCall(
                        id: "call-submit", name: "submit_research_notes",
                        argumentsJSON: wfSubmission
                    )
                ],
                stopReason: .toolCalls, usage: nil)),
            .response(toolCallResponse([(name: "get_local_data", args: "{}")])),
            .response(ModelCompletionResponse(
                assistantMessage: ModelChatMessage(role: .assistant, content: nil, toolCalls: [
                    ModelToolCall(
                        id: "call-submit", name: "submit_research_notes",
                        argumentsJSON: wfSubmission
                    )
                ]),
                toolCalls: [
                    ModelToolCall(
                        id: "call-submit", name: "submit_research_notes",
                        argumentsJSON: wfSubmission
                    )
                ],
                stopReason: .toolCalls, usage: nil)),
        ])
        var gatewayPolicy = ModelGatewayPolicy()
        gatewayPolicy.maxRetriesPerProvider = 0
        let harness = ResearchHarness(
            gateway: ModelGateway(providers: [provider], policy: gatewayPolicy),
            tools: [StubResearchTool(name: "get_local_data", evidence: evidence)],
            clock: wfClock
        )
        let sink = ArtifactSinkCollector()
        let workflow = PortfolioResearchWorkflow(
            dependencies: PortfolioResearchWorkflow.Dependencies(
                harness: harness,
                signalStore: repository,
                thesisStore: repository,
                evidenceStore: repository,
                decisionMaterials: EmptyMaterialsProvider(),
                artifactSink: { artifact in try sink.sink(artifact) }
            ),
            clock: wfClock
        )
        let outcome = try await workflow.run(input: try makeInput())

        XCTAssertEqual(outcome.job.state, .failed)
        XCTAssertTrue(outcome.errorDetail?.contains("plannerRuns") ?? false)
    }
}

// MARK: - ThesisStore 单元测试（GRDB / InMemory parity）

final class ThesisStoreTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_900_000_100)

    private func makeThesis(
        kind: ResearchThesisKind = .asset,
        subject: CanonicalRef = try! CanonicalRef(
            entityType: "fundShareClass", entityIDRawValue: "sc_t"
        ),
        statement: String = "测试论点"
    ) -> ResearchThesis {
        ResearchThesis(
            id: "thesis_\(StableDigest.digest("\(kind.rawValue)|\(statement)"))",
            kind: kind,
            subject: subject,
            statement: statement,
            supportingEvidenceIDs: [EvidenceID(rawValue: "EV-T1")],
            linkedSignalIDs: [SignalID(rawValue: "sig_t1")],
            createdAt: day,
            revisedAt: nil,
            sourceNotesFingerprints: ["fp-1"]
        )
    }

    func testGRDBWriteReadRoundTripAndQueries() throws {
        let repository = GRDBRepository(
            database: try CanonicalDatabase(), calendarBackend: TestWeekdayCalendar()
        )
        let thesis = makeThesis()
        try repository.write(thesis)

        XCTAssertEqual(try repository.thesis(id: thesis.id), thesis)
        let byKind = try repository.theses(
            kind: .asset, subject: try! CanonicalRef(
                entityType: "fundShareClass", entityIDRawValue: "sc_t"
            )
        )
        XCTAssertEqual(byKind, [thesis])
        XCTAssertTrue(try repository.theses(
            kind: .portfolio, subject: thesis.subject
        ).isEmpty)

        // 幂等：同 ID 同语义（剥时间）重写 no-op
        let laterTime = day.addingTimeInterval(600)
        let rewritten = ResearchThesis(
            id: thesis.id, kind: thesis.kind, subject: thesis.subject,
            statement: thesis.statement,
            supportingEvidenceIDs: thesis.supportingEvidenceIDs,
            linkedSignalIDs: thesis.linkedSignalIDs,
            createdAt: laterTime, revisedAt: nil,
            sourceNotesFingerprints: thesis.sourceNotesFingerprints
        )
        XCTAssertNoThrow(try repository.write(rewritten))
        XCTAssertEqual(try repository.thesis(id: thesis.id)?.createdAt, day)

        // conflict：同 ID 异语义拒
        let divergent = ResearchThesis(
            id: thesis.id, kind: thesis.kind, subject: thesis.subject,
            statement: "篡改后的论点",
            supportingEvidenceIDs: thesis.supportingEvidenceIDs,
            linkedSignalIDs: thesis.linkedSignalIDs,
            createdAt: day, revisedAt: nil,
            sourceNotesFingerprints: thesis.sourceNotesFingerprints
        )
        XCTAssertThrowsError(try repository.write(divergent)) { error in
            XCTAssertEqual(
                error as? ThesisStoreError,
                .conflict(thesisID: thesis.id, field: "statement")
            )
        }
    }

    func testInMemoryParity() throws {
        let store = InMemoryThesisStore()
        let thesis = makeThesis()
        try store.write(thesis)
        XCTAssertEqual(try store.thesis(id: thesis.id), thesis)
        XCTAssertEqual(
            try store.theses(
                kind: .asset, subject: try! CanonicalRef(
                    entityType: "fundShareClass", entityIDRawValue: "sc_t"
                )
            ),
            [thesis]
        )
        // 空证据论点拒绝
        let evidenceless = ResearchThesis(
            id: "thesis_bad", kind: .asset, subject: thesis.subject,
            statement: "无证据论点", supportingEvidenceIDs: [],
            linkedSignalIDs: [], createdAt: day, revisedAt: nil,
            sourceNotesFingerprints: []
        )
        XCTAssertThrowsError(try store.write(evidenceless)) { error in
            XCTAssertEqual(
                error as? ThesisStoreError,
                .malformed(thesisID: "thesis_bad", detail: "supportingEvidenceIDs 为空——无证据支撑的不是论点")
            )
        }
    }

    func testThesisSynthesizerDeterminism() throws {
        let notes = try makeResearchNotes(
            [
                ResearchClaim(
                    statement: "s1",
                    evidenceReferences: [EvidenceID(rawValue: "EV-A")],
                    confidenceLabel: .high, dimension: .momentum, direction: .bullish
                ),
                ResearchClaim(
                    statement: "s2",
                    evidenceReferences: [EvidenceID(rawValue: "EV-A"), EvidenceID(rawValue: "EV-B")],
                    confidenceLabel: .medium, dimension: .value, direction: .neutral
                ),
            ],
            subject: try! CanonicalRef(entityType: "listing", entityIDRawValue: "list_x")
        )
        let signals = SignalExtractor().extract(from: notes, now: day)
        let first = ThesisSynthesizer().assetThesis(from: notes, signals: signals, now: day)
        let second = ThesisSynthesizer().assetThesis(from: notes, signals: signals, now: day)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.supportingEvidenceIDs.map(\.rawValue).sorted(), ["EV-A", "EV-B"])
        XCTAssertEqual(first.linkedSignalIDs.count, signals.count)
        XCTAssertTrue(first.statement.contains("s1"))
        XCTAssertTrue(first.statement.contains("s2"))
    }
}

// MARK: - ResearchEvidenceFactory 单元测试

final class ResearchEvidenceFactoryTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_900_000_200)

    func testFactoryMapsKnownToolsAndFailsClosedOnUnknown() throws {
        let factory = ResearchEvidenceFactory()
        let subject = try CanonicalRef(entityType: "fundShareClass", entityIDRawValue: "sc_e")
        let observation = try factory.observation(
            evidenceID: EvidenceID(rawValue: "EV-F1"),
            toolName: "get_local_data",
            content: ["series": "nav"],
            subject: subject,
            at: day
        )
        XCTAssertEqual(observation.source, .research)
        XCTAssertEqual(
            observation.dataQuality.sourceProviderID,
            DataProviderID(rawValue: "get_local_data")
        )
        XCTAssertEqual(observation.subjectCanonical, subject)
        // 点观测四时间一致
        XCTAssertEqual(observation.temporalEnvelope.effectiveAt, day)
        XCTAssertEqual(observation.temporalEnvelope.availableAt, day)

        // SEC 工具映射
        let sec = try factory.observation(
            evidenceID: EvidenceID(rawValue: "EV-F2"),
            toolName: "official_sec_research",
            content: ["filing": "10-K"],
            subject: subject,
            at: day
        )
        XCTAssertEqual(sec.source, .secFiling)
        XCTAssertEqual(sec.dataQuality.providerReliability, .officialStable)

        // 未知工具 fail-closed
        XCTAssertThrowsError(
            try factory.observation(
                evidenceID: EvidenceID(rawValue: "EV-F3"),
                toolName: "mystery_tool",
                content: [:], subject: subject, at: day
            )
        ) { error in
            XCTAssertEqual(error as? ResearchEvidenceError, .unknownToolSource("mystery_tool"))
        }
    }

    // MARK: 十五轮审查 P1-4 回归：来源时间进 TemporalEnvelope

    func testFactoryUsesSourceDateForEvidenceLifetime() throws {
        let factory = ResearchEvidenceFactory()
        let subject = try CanonicalRef(entityType: "listing", entityIDRawValue: "lst_sd")
        let filedAt = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11 的历史申报
        let fetchedAt = Date(timeIntervalSince1970: 1_900_000_000) // 今天重抓

        let observation = try factory.observation(
            evidenceID: EvidenceID(rawValue: "EV-SD"),
            toolName: "official_sec_research",
            content: ["filed_at": "2023-11-14"],
            subject: subject,
            sourceDate: filedAt,
            at: fetchedAt
        )
        // effective = published = available = 来源时间;ingested = 抓取时间
        XCTAssertEqual(observation.temporalEnvelope.effectiveAt, filedAt)
        XCTAssertEqual(observation.temporalEnvelope.publishedAt, filedAt)
        XCTAssertEqual(observation.temporalEnvelope.availableAt, filedAt)
        XCTAssertEqual(observation.temporalEnvelope.ingestedAt, fetchedAt)
        XCTAssertEqual(observation.vintage.announcementDate, filedAt)

        // 无来源时间 → 回退执行时刻（实时查询结果语义）
        let realtime = try factory.observation(
            evidenceID: EvidenceID(rawValue: "EV-RT"),
            toolName: "get_local_data",
            content: [:], subject: subject, sourceDate: nil, at: fetchedAt
        )
        XCTAssertEqual(realtime.temporalEnvelope.effectiveAt, fetchedAt)
        XCTAssertEqual(realtime.temporalEnvelope.ingestedAt, fetchedAt)
    }

    func testFactoryIDIsContentDerived() throws {
        let factory = ResearchEvidenceFactory()
        let subject = try CanonicalRef(entityType: "listing", entityIDRawValue: "list_y")
        let first = try factory.observation(
            evidenceID: EvidenceID(rawValue: "EV-G"),
            toolName: "web_search",
            content: ["result": 1],
            subject: subject, at: day
        )
        let sameContent = try factory.observation(
            evidenceID: EvidenceID(rawValue: "EV-G"),
            toolName: "web_search",
            content: ["result": 1],
            subject: subject, at: day.addingTimeInterval(60)
        )
        let differentContent = try factory.observation(
            evidenceID: EvidenceID(rawValue: "EV-G"),
            toolName: "web_search",
            content: ["result": 2],
            subject: subject, at: day
        )
        XCTAssertEqual(first.id, sameContent.id) // 同内容幂等
        XCTAssertNotEqual(first.id, differentContent.id) // 异内容 = 新 vintage
    }

    func testInMemoryEvidenceStoreQueries() throws {
        let store = InMemoryResearchEvidenceStore()
        let factory = ResearchEvidenceFactory()
        let subject = try CanonicalRef(entityType: "listing", entityIDRawValue: "list_z")
        try store.write(
            factory.observation(
                evidenceID: EvidenceID(rawValue: "EV-H"),
                toolName: "web_search", content: ["q": 1],
                subject: subject, at: day
            )
        )
        XCTAssertEqual(try store.knownEvidenceIDs(), ["EV-H"])
        XCTAssertEqual(try store.evidenceDates()["EV-H"], day)
        XCTAssertEqual(try store.observations(evidenceID: EvidenceID(rawValue: "EV-H")).count, 1)
    }
}
