import XCTest
@testable import QiemanDashboard

// RES-4：Signal Extraction——ResearchNotes → InvestmentSignal 的确定性转换
// 与 versioned 证据门槛。

private let ev1 = EvidenceID(rawValue: "EV-1")
private let ev2 = EvidenceID(rawValue: "EV-2")

final class SignalExtractionTests: XCTestCase {

    func testWellEvidenceBullishClaimProducesStrongSignal() throws {
        let notes = try makeResearchNotes([
            ResearchClaim(
                statement: "动量占优", evidenceReferences: [ev1, ev2],
                confidenceLabel: .high, dimension: .momentum, direction: .bullish
            )
        ])
        let signals = SignalExtractor().extract(from: notes, now: Date(timeIntervalSince1970: 5000))
        XCTAssertEqual(signals.count, 1)
        let signal = signals[0]
        XCTAssertEqual(signal.direction, .bullish)
        XCTAssertEqual(signal.strength, .strong)
        XCTAssertEqual(signal.dimension, .momentum)
        XCTAssertEqual(signal.derivedFromEvidenceIDs, [ev1, ev2])
        XCTAssertEqual(signal.producer.kind, .llm)
        XCTAssertEqual(signal.producer.modelIdentifier, "test-model")
        XCTAssertTrue(signal.id.rawValue.hasPrefix("sig_"))
        XCTAssertTrue(signal.rationale?.contains("policy=research-signal-extraction@v1") ?? false)
        XCTAssertFalse(signal.rationale?.contains("降级") ?? true, "无降级发生")
    }

    func testDirectionlessEvidenceStillYieldsUncertainSignalWithEvidence() throws {
        // 有证据但模型未给方向：产出 uncertain 信号（证据仍溯源）。
        let notes = try makeResearchNotes([
            ResearchClaim(
                statement: "观察到溢价波动", evidenceReferences: [ev1],
                confidenceLabel: .medium, dimension: .sentiment, direction: nil
            )
        ])
        let signals = SignalExtractor().extract(from: notes, now: Date())
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals[0].direction, .uncertain)
        XCTAssertEqual(signals[0].strength, .weak, "方向不明强度固定 weak")
        XCTAssertEqual(signals[0].derivedFromEvidenceIDs, [ev1])
    }

    func testUnevidencedClaimProducesNoSignal() throws {
        // 无证据的 claim（维度组去重后 evidence 为空）不产信号——与
        // SignalStore 写入门禁对齐（审查 P2-2）：无证据支撑的不是信号，
        // 是叙述；方向降级逻辑只对「组内其他 claim 有证据」的场景生效。
        let notes = try makeResearchNotes([
            ResearchClaim(
                statement: "感觉要涨", evidenceReferences: [],
                confidenceLabel: .high, dimension: .momentum, direction: .bullish
            )
        ])
        XCTAssertTrue(SignalExtractor().extract(from: notes, now: Date()).isEmpty)
    }

    func testMixedEvidenceGroupStillExtractsWithDemotionRationale() throws {
        // 组内混合：有证据 claim 的方向保留，无证据 claim 的方向被拒——
        // 降级理由仍透明进 rationale。
        let notes = try makeResearchNotes([
            ResearchClaim(
                statement: "有据看多", evidenceReferences: [ev1],
                confidenceLabel: .high, dimension: .momentum, direction: .bullish
            ),
            ResearchClaim(
                statement: "无据看空", evidenceReferences: [],
                confidenceLabel: .high, dimension: .momentum, direction: .bearish
            ),
        ])
        let signals = SignalExtractor().extract(from: notes, now: Date())
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals[0].direction, .bullish, "有据方向不被无据 claim 冲突掉")
        XCTAssertTrue(signals[0].rationale?.contains("无证据引用") ?? false, "无据 claim 的降级说明保留")
    }

    func testEvidenceCountThresholdDemotesDirection() throws {
        // 策略要求非中性方向 ≥2 条证据；1 条 → 降级。
        var policy = SignalExtractionPolicy.defaultValue
        policy.minEvidenceCountForDirection = 2
        let notes = try makeResearchNotes([
            ResearchClaim(
                statement: "单一来源", evidenceReferences: [ev1],
                confidenceLabel: .medium, dimension: .value, direction: .bearish
            )
        ])
        let signals = SignalExtractor(policy: policy).extract(from: notes, now: Date())
        XCTAssertEqual(signals[0].direction, .uncertain)
        XCTAssertTrue(signals[0].rationale?.contains("证据数 < 2") ?? false)
        // 两条证据则方向保留
        let strong = try makeResearchNotes([
            ResearchClaim(
                statement: "双源确认", evidenceReferences: [ev1, ev2],
                confidenceLabel: .medium, dimension: .value, direction: .bearish
            )
        ])
        XCTAssertEqual(
            SignalExtractor(policy: policy).extract(from: strong, now: Date())[0].direction,
            .bearish
        )
    }

    func testLowConfidenceHandlingStrategies() throws {
        let notes = try makeResearchNotes([
            ResearchClaim(
                statement: "弱信号观察", evidenceReferences: [ev1],
                confidenceLabel: .low, dimension: .quality, direction: .bullish
            )
        ])
        // 默认：降级 uncertain
        let downgraded = SignalExtractor().extract(from: notes, now: Date())[0]
        XCTAssertEqual(downgraded.direction, .uncertain)
        XCTAssertTrue(downgraded.rationale?.contains("充分度 LOW") ?? false)
        // capStrengthAtWeak：方向保留、强度封顶 weak
        var policy = SignalExtractionPolicy.defaultValue
        policy.lowConfidenceHandling = .capStrengthAtWeak
        let capped = SignalExtractor(policy: policy).extract(from: notes, now: Date())[0]
        XCTAssertEqual(capped.direction, .bullish)
        XCTAssertEqual(capped.strength, .weak)
    }

    func testConflictingDirectionsInSameDimensionDemoteToUncertain() throws {
        let notes = try makeResearchNotes([
            ResearchClaim(
                statement: "多方论据", evidenceReferences: [ev1],
                confidenceLabel: .high, dimension: .macro, direction: .bullish
            ),
            ResearchClaim(
                statement: "空方论据", evidenceReferences: [ev2],
                confidenceLabel: .high, dimension: .macro, direction: .bearish
            ),
        ])
        let signals = SignalExtractor().extract(from: notes, now: Date())
        XCTAssertEqual(signals.count, 1, "同维度合并为一个信号")
        XCTAssertEqual(signals[0].direction, .uncertain)
        XCTAssertEqual(signals[0].derivedFromEvidenceIDs.sorted { $0.rawValue < $1.rawValue }, [ev1, ev2], "evidence 并集")
        XCTAssertTrue(signals[0].rationale?.contains("方向冲突") ?? false)
        XCTAssertTrue(signals[0].rationale?.contains("BEARISH vs BULLISH") ?? false)
    }

    func testStrengthMapsFromBestConfidenceInGroup() throws {
        let notes = try makeResearchNotes([
            ResearchClaim(
                statement: "中等确信", evidenceReferences: [ev1],
                confidenceLabel: .medium, dimension: .risk, direction: .neutral
            ),
            ResearchClaim(
                statement: "高确信", evidenceReferences: [ev2],
                confidenceLabel: .high, dimension: .risk, direction: .neutral
            ),
        ])
        let signals = SignalExtractor().extract(from: notes, now: Date())
        XCTAssertEqual(signals[0].strength, .strong, "组内最高充分度映射")
        XCTAssertEqual(signals[0].direction, .neutral)
    }

    func testClaimWithoutDimensionIsSkipped() throws {
        let notes = try makeResearchNotes([
            ResearchClaim(
                statement: "无维度事实", evidenceReferences: [ev1],
                confidenceLabel: .high, dimension: nil, direction: .bullish
            )
        ])
        XCTAssertTrue(SignalExtractor().extract(from: notes, now: Date()).isEmpty,
                      "无法归入信号维度的 claim 不产信号（叙述留在 notes）")
    }

    func testPolicyVersionParticipatesInSignalID() throws {
        let notes = try makeResearchNotes([
            ResearchClaim(
                statement: "s", evidenceReferences: [ev1],
                confidenceLabel: .high, dimension: .momentum, direction: .bullish
            )
        ])
        let v1 = SignalExtractor().extract(from: notes, now: Date())[0]
        let v2Policy = SignalExtractionPolicy(
            provenance: SignalPolicyProvenance(
                policyID: "research-signal-extraction", policyVersion: "v2",
                basis: .heuristic, rationale: "调整", quantileSampleWindow: nil
            )
        )
        let v2 = SignalExtractor(policy: v2Policy).extract(from: notes, now: Date())[0]
        XCTAssertNotEqual(v1.id, v2.id, "策略版本变更 → 不同 ID（历史可审计）")
        XCTAssertEqual(v1.direction, v2.direction, "内容相同只是身份不同")
    }

    // MARK: 十五轮审查 P1-3 回归：ID 身份域 == SignalStore 冲突比较域

    func testRephrasedNotesProduceDistinctSignalIDNoConflict() throws {
        // 同证据、同方向、同 producer，但 claims 措辞不同（或 failover 到
        // 另一模型）→ 不同 ID（不同信号），不再触发 SignalStore conflict。
        let store = InMemorySignalStore()
        func claim(_ statement: String) -> ResearchClaim {
            ResearchClaim(
                statement: statement,
                evidenceReferences: [ev1],
                confidenceLabel: .high,
                dimension: .momentum,
                direction: .bullish
            )
        }
        let first = SignalExtractor().extract(
            from: try makeResearchNotes([claim("净值连续回升，动量改善")]),
            now: Date(timeIntervalSince1970: 1000)
        )
        let second = SignalExtractor().extract(
            from: try makeResearchNotes([claim("近三日净值上行，趋势走强")]),
            now: Date(timeIntervalSince1970: 2000)
        )
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertNotEqual(
            first[0].id, second[0].id,
            "不同措辞（不同 notes contentFingerprint）是不同信号——ID 必须分叉"
        )
        // 两条信号都能落库（同 ID 才会撞 conflict，现在不会）
        XCTAssertNoThrow(try store.write(first[0]))
        XCTAssertNoThrow(try store.write(second[0]))
        XCTAssertEqual(try store.signals(subject: first[0].subjectCanonical).count, 2)
    }

    func testFailoverToDifferentModelProducesDistinctSignalID() throws {
        // producer（模型标识）不同 → ID 不同——failover 产新信号而非 conflict
        func extract(_ model: String) throws -> InvestmentSignal {
            let notes = ResearchNotes(
                task: try makeResearchNotes([
                    ResearchClaim(
                        statement: "动量改善",
                        evidenceReferences: [ev1],
                        confidenceLabel: .high,
                        dimension: .momentum,
                        direction: .bullish
                    )
                ]).task,
                notes: "n",
                claims: [
                    ResearchClaim(
                        statement: "动量改善",
                        evidenceReferences: [ev1],
                        confidenceLabel: .high,
                        dimension: .momentum,
                        direction: .bullish
                    )
                ],
                producedBy: ModelProviderDescriptor(
                    providerID: "p", model: model, fingerprint: "f-\(model)"
                ),
                producedAt: Date(timeIntervalSince1970: 1000)
            )
            return try XCTUnwrap(SignalExtractor().extract(from: notes, now: Date(timeIntervalSince1970: 1000)).first)
        }
        let fromPrimary = try extract("model-a")
        let fromFailover = try extract("model-b")
        XCTAssertNotEqual(fromPrimary.id, fromFailover.id)
    }

    func testExtractionIsIdempotentForSameNotesAndPolicy() throws {
        let notes = try makeResearchNotes([
            ResearchClaim(
                statement: "s", evidenceReferences: [ev1, ev2],
                confidenceLabel: .high, dimension: .momentum, direction: .bullish
            )
        ])
        let first = SignalExtractor().extract(from: notes, now: Date(timeIntervalSince1970: 111))
        let second = SignalExtractor().extract(from: notes, now: Date(timeIntervalSince1970: 999))
        XCTAssertEqual(first.map(\.id), second.map(\.id), "同 notes 同 policy 重提取幂等")
        XCTAssertEqual(first.map(\.direction), second.map(\.direction))
        XCTAssertEqual(first.map(\.strength), second.map(\.strength))
    }

    func testEvidenceOrderDoesNotAffectIdentity() throws {
        let a = try makeResearchNotes([
            ResearchClaim(
                statement: "s", evidenceReferences: [ev1, ev2],
                confidenceLabel: .medium, dimension: .value, direction: .bearish
            )
        ])
        let b = try makeResearchNotes([
            ResearchClaim(
                statement: "s", evidenceReferences: [ev2, ev1],
                confidenceLabel: .medium, dimension: .value, direction: .bearish
            )
        ])
        let signalA = SignalExtractor().extract(from: a, now: Date())[0]
        let signalB = SignalExtractor().extract(from: b, now: Date())[0]
        XCTAssertEqual(signalA.id, signalB.id, "evidence 顺序无关（规范化排序）")
    }

    func testClaimDirectionSurvivesHarnessSubmissionRoundTrip() async throws {
        // 端到端：提交 payload 带 direction，经 Harness 校验进 ResearchNotes，
        // 再由 extractor 落成 InvestmentSignal。
        let submission = """
        {"notes": "n", "claims": [
            {"statement": "动量转强", "evidence_ids": ["EV-1"], "confidence_label": "HIGH",
             "dimension": "MOMENTUM", "direction": "BULLISH"}
        ]}
        """
        let provider = ScriptedModelProvider(providerID: "p", steps: [
            .response(ModelCompletionResponse(
                assistantMessage: ModelChatMessage(role: .assistant),
                toolCalls: [ModelToolCall(id: "c1", name: "get_market_snapshot", argumentsJSON: "{}")],
                stopReason: .toolCalls, usage: nil
            )),
            .response(ModelCompletionResponse(
                assistantMessage: ModelChatMessage(role: .assistant),
                toolCalls: [ModelToolCall(id: "c2", name: "submit_research_notes", argumentsJSON: submission)],
                stopReason: .toolCalls, usage: nil
            )),
        ])
        var gatewayPolicy = ModelGatewayPolicy()
        gatewayPolicy.maxRetriesPerProvider = 0
        let harness = ResearchHarness(
            gateway: ModelGateway(providers: [provider], policy: gatewayPolicy),
            tools: [StubResearchTool(evidence: [ev1])]
        )
        let outcome = try await harness.run(
            task: ResearchTask(
                subject: try CanonicalRef(entityType: "fundShareClass", entityIDRawValue: "sc_513100"),
                objective: "test"
            )
        )
        XCTAssertTrue(outcome.succeeded)
        let notes = try XCTUnwrap(outcome.notes)
        XCTAssertEqual(notes.claims[0].direction, .bullish)
        let signals = SignalExtractor().extract(from: notes, now: Date())
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals[0].direction, .bullish)
        XCTAssertEqual(signals[0].strength, .strong)
    }
}
