import XCTest
import GRDB
@testable import QiemanDashboard

/// GRDB-6 测试：Intelligence / Decision / Agent 域 schema（10 表）——
/// 表结构、evidence 双 ID 语义、signal 溯源 JSON、artifact 依赖规范化、
/// agent job 生命周期约束（idempotency / 事件流 / checkpoint）、fail-closed。
final class IntelligenceSchemaTests: XCTestCase {

    private var db: CanonicalDatabase!

    override func setUpWithError() throws {
        db = try CanonicalDatabase()
    }

    // MARK: - 迁移与表结构

    func testV6Migration_RegistersLast() throws {
        let migrations = CanonicalDatabase.makeMigrations().migrations
        XCTAssertEqual(migrations.prefix(5).last, "v5_fundamental_macro")
        XCTAssertEqual(migrations.suffix(1), ["v6_intelligence"])
        XCTAssertEqual(CanonicalDatabase.schemaVersion, migrations.count)
        XCTAssertEqual(try db.appliedMigrations().suffix(1), ["v6_intelligence"])
    }

    func testAllTenTablesExist() throws {
        try db.queue.read { d in
            for table in [
                "evidence", "evidence_facts", "signals", "theses", "artifacts",
                "artifact_dependencies", "decisions", "agent_jobs",
                "agent_job_events", "agent_checkpoints",
            ] {
                XCTAssertTrue(try d.tableExists(table), "表 \(table) 应存在")
            }
        }
    }

    // MARK: - Evidence（双 ID 语义）

    func testRoundTrip_evidence() throws {
        let evidence = Self.evidence()
        try db.queue.write { d in try EvidenceRow.from(evidence).insert(d) }
        try db.queue.read { d in
            let fetched = try EvidenceRow.fetchOne(d, key: evidence.id.rawValue)!.toDomain()
            XCTAssertEqual(fetched, evidence)
        }
    }

    /// EvidenceID 是 UNIQUE 逻辑身份：不同 ObservationID 但同 EvidenceID 拒收。
    func testEvidence_uniqueEvidenceID() throws {
        try db.queue.write { d in try EvidenceRow.from(Self.evidence()).insert(d) }
        var row = EvidenceRow.from(Self.evidence())
        row = EvidenceRow(
            id: "obs_ev-2", evidenceID: row.evidenceID, envelope: row.envelope,
            content: row.content, source: row.source,
            subjectEntityType: row.subjectEntityType, subjectEntityID: row.subjectEntityID
        )
        XCTAssertThrowsError(try db.queue.write { d in try row.insert(d) })
    }

    // MARK: - EvidenceFact

    func testRoundTrip_evidenceFact_numericVariants() throws {
        try seedEvidence()
        try db.queue.write { d in
            try EvidenceFactRow.from(Self.fact(numericValue: Decimal(string: "17.2")!,
                                                numericUnit: "PERCENT")).insert(d)
            try EvidenceFactRow.from(Self.fact(numericValue: nil, numericUnit: nil,
                                               idSuffix: "-text")).insert(d)
        }
        try db.queue.read { d in
            let numeric = try EvidenceFactRow.fetchOne(d, key: "fact-1")!.toDomain()
            XCTAssertEqual(numeric.numericValue, Decimal(string: "17.2"))
            XCTAssertEqual(numeric.numericUnit, "PERCENT")
            let textual = try EvidenceFactRow.fetchOne(d, key: "fact-1-text")!.toDomain()
            XCTAssertNil(textual.numericValue)
            XCTAssertNil(textual.numericUnit)
        }
    }

    /// evidence_facts 外键：引用不存在的 EvidenceID 拒收。
    func testEvidenceFact_foreignKeyToEvidence() throws {
        try seedEvidence()
        var row = EvidenceFactRow.from(Self.fact(numericValue: nil, numericUnit: nil))
        row = EvidenceFactRow(
            id: "fact-dangling", evidenceID: "ev_no_such", statement: row.statement,
            extractionMethod: row.extractionMethod, verificationStatus: row.verificationStatus,
            subjectEntityType: row.subjectEntityType, subjectEntityID: row.subjectEntityID,
            numericValue: nil, numericUnit: nil
        )
        XCTAssertThrowsError(try db.queue.write { d in try row.insert(d) }) { error in
            XCTAssertEqual(
                (error as? DatabaseError)?.extendedResultCode,
                .SQLITE_CONSTRAINT_FOREIGNKEY
            )
        }
    }

    // MARK: - Signal

    func testRoundTrip_signalWithEvidenceDerivation() throws {
        try db.queue.write { d in
            try SignalRow.from(Self.signal()).insert(d)
        }
        try db.queue.read { d in
            let fetched = try SignalRow.fetchOne(d, key: "sig-1")!.toDomain()
            XCTAssertEqual(fetched, Self.signal())
            XCTAssertEqual(
                fetched.derivedFromEvidenceIDs,
                [EvidenceID(rawValue: "ev-1"), EvidenceID(rawValue: "ev-2")],
                "derivedFrom EvidenceID 数组应无损往返"
            )
        }
    }

    func testDecode_unknownSignalDirectionRejected() throws {
        try db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO signals (id, subject_entity_type, subject_entity_id, dimension,
                    direction, strength, derived_from_evidence_ids, effective_at,
                    producer_kind, producer_model_identifier, rationale)
                VALUES ('sig-bad', 'instrument', 'inst_600519', 'MOMENTUM',
                    'UP_AND_TO_THE_RIGHT', 'STRONG', '[]', '2026-08-24T00:00:00.000Z',
                    'FACTOR_ENGINE', NULL, NULL)
                """)
        }
        XCTAssertThrowsError(
            try db.queue.read { d in try SignalRow.fetchOne(d, key: "sig-bad")!.toDomain() }
        ) { error in
            XCTAssertEqual(
                error as? CanonicalColumnCodecError,
                .unknownEnumValue(column: "direction", rawValue: "UP_AND_TO_THE_RIGHT")
            )
        }
    }

    // MARK: - Artifact + 依赖规范化

    func testRoundTrip_artifactWithNormalizedDependencies() throws {
        let artifact = Self.artifact()
        try db.queue.write { d in
            try ArtifactRow.from(artifact).insert(d)
            for (index, dep) in artifact.dependencies.enumerated() {
                try ArtifactDependencyRow.from(dep, artifactID: artifact.id, index: index).insert(d)
            }
        }
        try db.queue.read { d in
            let skeleton = try ArtifactRow.fetchOne(d, key: artifact.id.rawValue)!.toPlaceholderDomain()
            let deps = try ArtifactDependencyRow
                .fetchAll(d, sql: "SELECT * FROM artifact_dependencies WHERE artifact_id = ? ORDER BY dep_index",
                          arguments: [artifact.id.rawValue])
                .map { try $0.toDomain() }
            var reassembled = skeleton
            reassembled = PlaceholderArtifact(
                id: skeleton.id, producedAt: skeleton.producedAt,
                validityPolicy: skeleton.validityPolicy,
                dependencies: deps, payload: skeleton.payload
            )
            XCTAssertEqual(reassembled, artifact)
        }
    }

    /// 失效传播查询：按 (kind, reference_id) 找受影响 artifacts。
    func testArtifactDependencies_invalidationLookup() throws {
        let artifact = Self.artifact()
        try db.queue.write { d in
            try ArtifactRow.from(artifact).insert(d)
            for (index, dep) in artifact.dependencies.enumerated() {
                try ArtifactDependencyRow.from(dep, artifactID: artifact.id, index: index).insert(d)
            }
        }
        let affected = try db.queue.read { d in
            try String.fetchAll(
                d,
                sql: """
                SELECT DISTINCT artifact_id FROM artifact_dependencies
                WHERE kind = 'OBSERVATION' AND reference_id = ?
                """,
                arguments: ["obs_bar-1"]
            )
        }
        XCTAssertEqual(affected, [artifact.id.rawValue], "依赖该 observation 的 artifact 应可查出")
    }

    /// 依赖行外键 + 主键：不存在的 artifact / 重复 dep_index 拒收。
    func testArtifactDependencies_constraints() throws {
        let orphan = ArtifactDependencyRow(
            artifactID: "art_no_such", depIndex: 0, kind: "SIGNAL",
            referenceID: "sig-1", version: nil
        )
        XCTAssertThrowsError(try db.queue.write { d in try orphan.insert(d) })

        let artifact = Self.artifact()
        try db.queue.write { d in
            try ArtifactRow.from(artifact).insert(d)
            try ArtifactDependencyRow.from(
                artifact.dependencies[0], artifactID: artifact.id, index: 0
            ).insert(d)
        }
        let duplicate = ArtifactDependencyRow(
            artifactID: artifact.id.rawValue, depIndex: 0, kind: "SIGNAL",
            referenceID: "sig-1", version: nil
        )
        XCTAssertThrowsError(try db.queue.write { d in try duplicate.insert(d) })
    }

    // MARK: - Agent Job 生命周期

    /// idempotency_key UNIQUE：同 key 二号 job 拒收；NULL key 可多个共存。
    func testAgentJobs_idempotencyKeyUnique_nullableCoexist() throws {
        let base = Self.job(id: "job-1", key: "daily-attribution-2026-08-24")
        try db.queue.write { d in try base.insert(d) }
        XCTAssertThrowsError(
            try db.queue.write { d in try Self.job(id: "job-2", key: base.idempotencyKey!).insert(d) },
            "同 idempotency key 的第二个 job 必须拒收"
        )
        // 无 key 的手工运行不受唯一约束限制
        try db.queue.write { d in
            try Self.job(id: "job-3", key: nil).insert(d)
            try Self.job(id: "job-4", key: nil).insert(d)
        }
    }

    /// 事件流 + checkpoint：(job_id, seq) 主键、FK、按序读回。
    func testAgentJobEventsAndCheckpoints_orderedAndConstrained() throws {
        try db.queue.write { d in try Self.job(id: "job-1", key: nil).insert(d) }

        // FK：不存在的 job 拒收
        let orphan = AgentJobEventRow(
            jobID: "job_no_such", seq: 0,
            occurredAt: "2026-08-24T09:00:00.000Z", kind: "STARTED", payloadJSON: "{}"
        )
        XCTAssertThrowsError(try db.queue.write { d in try orphan.insert(d) })

        try db.queue.write { d in
            for (seq, kind) in [(0, "QUEUED"), (1, "STARTED"), (2, "TOOL_CALL"), (3, "COMPLETED")] {
                try AgentJobEventRow(
                    jobID: "job-1", seq: seq,
                    occurredAt: "2026-08-24T09:00:0\(seq).000Z", kind: kind, payloadJSON: "{}"
                ).insert(d)
            }
            try AgentCheckpointRow(
                jobID: "job-1", seq: 0,
                createdAt: "2026-08-24T09:00:02.000Z", stateJSON: #"{"phase":"research"}"#
            ).insert(d)
        }
        // 同 seq 重复拒收
        XCTAssertThrowsError(try db.queue.write { d in
            try AgentJobEventRow(
                jobID: "job-1", seq: 2,
                occurredAt: "2026-08-24T09:00:09.000Z", kind: "REPLAY", payloadJSON: "{}"
            ).insert(d)
        })

        let events = try db.queue.read { d in
            try String.fetchAll(
                d, sql: "SELECT kind FROM agent_job_events WHERE job_id = 'job-1' ORDER BY seq"
            )
        }
        XCTAssertEqual(events, ["QUEUED", "STARTED", "TOOL_CALL", "COMPLETED"])
    }

    /// status 列 fail-closed。
    func testAgentJobStatus_unknownRejected() throws {
        try db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO agent_jobs (id, workflow, status, input_json, created_at)
                VALUES ('job-bad', 'daily-attribution', 'ZOMBIE', '{}', '2026-08-24T09:00:00.000Z')
                """)
        }
        XCTAssertThrowsError(
            try db.queue.read { d in try AgentJobRow.fetchOne(d, key: "job-bad")!.decodedStatus() }
        ) { error in
            XCTAssertEqual(
                error as? CanonicalColumnCodecError,
                .unknownEnumValue(column: "status", rawValue: "ZOMBIE")
            )
        }
    }

    // MARK: - 通用形状表（theses / decisions 原始读写）

    func testThesesAndDecisions_rawRoundTrip() throws {
        let ts = CanonicalColumnCodec.encodeTimestamp(Self.day0)
        try db.queue.write { d in
            try ThesisRow(
                id: "th-1", kind: "ASSET", subjectEntityType: "instrument",
                subjectEntityID: "inst_600519", statement: "高端白酒需求韧性强于市场预期",
                supportingEvidenceIDsJSON: #"["ev-1","ev-2"]"#,
                linkedSignalIDsJSON: #"["sig-1"]"#, createdAt: ts, revisedAt: nil
            ).insert(d)
            try DecisionRow(
                id: "dec-1", decisionKind: "REBALANCE", producedAt: ts,
                actionPlanJSON: #"{"actions":[]}"#, referencedSignalIDsJSON: #"["sig-1"]"#,
                validityPolicyJSON: #"{"tradingSession":{"exchange":"SSE","sessionDate":"2026-08-24T00:00:00.000Z"}}"#
            ).insert(d)
        }
        try db.queue.read { d in
            let thesis = try ThesisRow.fetchOne(d, key: "th-1")
            XCTAssertEqual(thesis?.kind, "ASSET")
            let decision = try DecisionRow.fetchOne(d, key: "dec-1")
            XCTAssertEqual(decision?.referencedSignalIDsJSON, #"["sig-1"]"#)
        }
    }

    // MARK: - fixture

    private static let day0 = Date(timeIntervalSince1970: 1_756_000_000)

    private static let envelope = TemporalEnvelope(
        effectiveAt: day0, publishedAt: day0.addingTimeInterval(86_400),
        availableAt: day0.addingTimeInterval(2 * 86_400),
        ingestedAt: day0.addingTimeInterval(86_400)
    )

    private static func evidence() -> EvidenceObservation {
        EvidenceObservation(
            id: ObservationID(rawValue: "obs_ev-1"),
            evidenceID: EvidenceID(rawValue: "ev-1"),
            temporalEnvelope: envelope,
            availabilityProvenance: AvailabilityProvenance(
                policyID: "web_harvest", policyVersion: "v1", derivedAt: day0
            ),
            dataQuality: DataQuality(
                providerReliability: .documentFreeAPI, sourceProviderID: .tavily
            ),
            vintage: Vintage(announcementDate: day0, publisherVersion: 1),
            content: "茅台 Q2 营收 450.2 亿元，同比 +17.2%",
            source: .providerAnnouncement,
            subjectCanonical: .instrument(InstrumentID(rawValue: "inst_600519"))
        )
    }

    private static func evidence2() -> EvidenceObservation {
        var base = evidence()
        return EvidenceObservation(
            id: ObservationID(rawValue: "obs_ev-2"),
            evidenceID: EvidenceID(rawValue: "ev-2"),
            temporalEnvelope: base.temporalEnvelope,
            availabilityProvenance: base.availabilityProvenance,
            dataQuality: base.dataQuality,
            vintage: base.vintage,
            content: "iShare 持仓报告确认 AAPL 权重上调",
            source: .secFiling,
            subjectCanonical: .instrument(InstrumentID(rawValue: "inst_aapl"))
        )
    }

    private static func fact(numericValue: Decimal?, numericUnit: String?, idSuffix: String = "") -> EvidenceFact {
        EvidenceFact(
            id: DomainID(rawValue: "fact-1\(idSuffix)"),
            evidenceID: EvidenceID(rawValue: "ev-1"),
            statement: "茅台 Q2 营收同比 +17.2%",
            extractionMethod: .llmExtracted,
            verificationStatus: .singleSourced,
            subjectCanonical: .instrument(InstrumentID(rawValue: "inst_600519")),
            numericValue: numericValue,
            numericUnit: numericUnit
        )
    }

    private static func signal() -> InvestmentSignal {
        InvestmentSignal(
            id: SignalID(rawValue: "sig-1"),
            subjectCanonical: .instrument(InstrumentID(rawValue: "inst_600519")),
            dimension: .momentum,
            direction: .bullish,
            strength: .moderate,
            derivedFromEvidenceIDs: [EvidenceID(rawValue: "ev-1"), EvidenceID(rawValue: "ev-2")],
            effectiveAt: day0,
            producer: SignalProducer(kind: .llm, modelIdentifier: "test-model"),
            rationale: "业绩超预期 + 动量延续"
        )
    }

    private static func artifact() -> PlaceholderArtifact {
        PlaceholderArtifact(
            id: ArtifactID(rawValue: "art-1"),
            producedAt: day0,
            validityPolicy: .timeBound(validUntil: day0.addingTimeInterval(7 * 86_400)),
            dependencies: [
                ArtifactDependency(kind: .observation, referenceID: "obs_bar-1"),
                ArtifactDependency(kind: .signal, referenceID: "sig-1", version: "sp-v1"),
                ArtifactDependency(kind: .policy, referenceID: "indifference-band", version: "v2"),
            ],
            payload: "test payload"
        )
    }

    private static func job(id: String, key: String?) -> AgentJobRow {
        AgentJobRow(
            id: id, workflow: "daily-attribution", idempotencyKey: key,
            status: "QUEUED", inputJSON: #"{"asOf":"2026-08-24"}"#,
            createdAt: CanonicalColumnCodec.encodeTimestamp(day0),
            startedAt: nil, completedAt: nil, errorMessage: nil
        )
    }

    private func seedEvidence() throws {
        try db.queue.write { d in
            try EvidenceRow.from(Self.evidence()).insert(d)
            try EvidenceRow.from(Self.evidence2()).insert(d)
        }
    }
}
