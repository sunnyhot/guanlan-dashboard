import XCTest
@testable import QiemanDashboard

// RES-5：Research Validation 管道——Schema / EvidenceBinding / Freshness
// 三层验证的 error/warning 分流。

private func makeNotes(
    claims: [ResearchClaim],
    producedAt: Date = Date(timeIntervalSince1970: 1000)
) throws -> ResearchNotes {
    ResearchNotes(
        task: ResearchTask(
            subject: try CanonicalRef(entityType: "fundShareClass", entityIDRawValue: "sc_513100"),
            objective: "test"
        ),
        notes: "n",
        claims: claims,
        producedBy: ModelProviderDescriptor(providerID: "p", model: "m", fingerprint: "f"),
        producedAt: producedAt
    )
}

private let now = Date(timeIntervalSince1970: 10_000)

final class ResearchValidationTests: XCTestCase {

    func testValidNotesPassWithNoIssues() throws {
        let notes = try makeNotes(claims: [
            ResearchClaim(
                statement: "动量占优", evidenceReferences: [EvidenceID(rawValue: "EV-1")],
                confidenceLabel: .high, dimension: .momentum, direction: .bullish
            )
        ])
        let result = ResearchValidationPipeline().validate(
            notes, now: now, knownEvidence: ["EV-1"]
        )
        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    // MARK: Schema 层

    func testSchemaLayerRejectsStructuralProblems() throws {
        var notes = try makeNotes(claims: [])
        var result = ResearchValidationPipeline().validate(notes, now: now, knownEvidence: [])
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.errors.first?.code, "empty_claims")

        notes = try makeNotes(claims: [
            ResearchClaim(
                statement: "  ", evidenceReferences: [EvidenceID(rawValue: "EV-1")],
                confidenceLabel: .high, dimension: .momentum, direction: nil
            )
        ])
        result = ResearchValidationPipeline().validate(notes, now: now, knownEvidence: ["EV-1"])
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.code == "empty_statement" })

        notes = try makeNotes(claims: [
            ResearchClaim(
                statement: "无维度", evidenceReferences: [EvidenceID(rawValue: "EV-1")],
                confidenceLabel: .high, dimension: nil, direction: nil
            )
        ])
        result = ResearchValidationPipeline().validate(notes, now: now, knownEvidence: ["EV-1"])
        XCTAssertFalse(result.isValid, "missing_dimension 是 error（claim 无法归入信号维度）")
    }

    func testSchemaLayerRejectsCardinalityExplosions() throws {
        var config = ResearchSchemaValidationConfig()
        config.maxClaims = 2
        var pipeline = ResearchValidationPipeline()
        pipeline.schema.config = config
        let claims = (0..<3).map { index in
            ResearchClaim(
                statement: "claim \(index)", evidenceReferences: [EvidenceID(rawValue: "EV-1")],
                confidenceLabel: .low, dimension: .momentum, direction: nil
            )
        }
        let result = pipeline.validate(try makeNotes(claims: claims), now: now, knownEvidence: ["EV-1"])
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.code == "too_many_claims" })
    }

    // MARK: EvidenceBinding 层

    func testEvidenceBindingRejectsUnknownReferences() throws {
        let notes = try makeNotes(claims: [
            ResearchClaim(
                statement: "s", evidenceReferences: [EvidenceID(rawValue: "EV-1"), EvidenceID(rawValue: "EV-X")],
                confidenceLabel: .high, dimension: .value, direction: .bearish
            )
        ])
        let result = ResearchValidationPipeline().validate(notes, now: now, knownEvidence: ["EV-1"])
        XCTAssertFalse(result.isValid)
        let unresolved = result.errors.first { $0.code == "unresolved_evidence_reference" }
        XCTAssertNotNil(unresolved)
        XCTAssertTrue(unresolved?.detail.contains("EV-X") ?? false, "详情点名未知 ID")
        XCTAssertEqual(unresolved?.claimIndex, 0)
    }

    func testMissingEvidenceDefaultsToWarningButConfigurable() throws {
        let notes = try makeNotes(claims: [
            ResearchClaim(
                statement: "无证据判断", evidenceReferences: [],
                confidenceLabel: .medium, dimension: .sentiment, direction: .bullish
            )
        ])
        // 默认：warning（RES-4 提取层强制 uncertain，不必在验证层再拒）
        var result = ResearchValidationPipeline().validate(notes, now: now, knownEvidence: [])
        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.warnings.contains { $0.code == "missing_evidence" })

        // 配置为 error：严格模式
        var pipeline = ResearchValidationPipeline()
        pipeline.evidenceBinding.config.treatMissingEvidenceAsError = true
        result = pipeline.validate(notes, now: now, knownEvidence: [])
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.code == "missing_evidence" })
    }

    // MARK: Freshness 层

    func testFreshnessRejectsStaleNotesAndWarnsOnStaleEvidence() throws {
        // notes 超龄 25h → error
        var config = ResearchFreshnessConfig()
        config.maxNotesAge = 24 * 3600
        config.evidenceStalenessWarning = 30 * 24 * 3600
        var pipeline = ResearchValidationPipeline()
        pipeline.freshness.config = config
        let staleNotes = try makeNotes(
            claims: [
                ResearchClaim(
                    statement: "s", evidenceReferences: [EvidenceID(rawValue: "EV-OLD"), EvidenceID(rawValue: "EV-NEW")],
                    confidenceLabel: .high, dimension: .macro, direction: .neutral
                )
            ],
            producedAt: now.addingTimeInterval(-25 * 3600)
        )
        let evidenceDates = [
            "EV-OLD": now.addingTimeInterval(-31 * 24 * 3600),
            "EV-NEW": now.addingTimeInterval(-3600),
        ]
        let result = pipeline.validate(staleNotes, now: now, knownEvidence: ["EV-OLD", "EV-NEW"], evidenceDates: evidenceDates)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.code == "notes_stale" })
        XCTAssertTrue(result.warnings.contains { $0.code == "evidence_stale" }, "陈旧证据是 warning（提取层已降级）")

        // 新鲜 notes + 新鲜 evidence → 干净通过
        let fresh = try makeNotes(
            claims: [
                ResearchClaim(
                    statement: "s", evidenceReferences: [EvidenceID(rawValue: "EV-NEW")],
                    confidenceLabel: .high, dimension: .macro, direction: .neutral
                )
            ],
            producedAt: now.addingTimeInterval(-3600)
        )
        let clean = pipeline.validate(fresh, now: now, knownEvidence: ["EV-NEW"], evidenceDates: evidenceDates)
        XCTAssertTrue(clean.isValid)
        XCTAssertTrue(clean.warnings.isEmpty)
    }

    func testMissingEvidenceDatesSkipStalenessCheck() throws {
        // 没有证据时间信息：不产生 stale 误报（不猜）。
        let notes = try makeNotes(
            claims: [
                ResearchClaim(
                    statement: "s", evidenceReferences: [EvidenceID(rawValue: "EV-1")],
                    confidenceLabel: .high, dimension: .macro, direction: .neutral
                )
            ],
            producedAt: now.addingTimeInterval(-3600)
        )
        let result = ResearchValidationPipeline().validate(notes, now: now, knownEvidence: ["EV-1"])
        XCTAssertTrue(result.warnings.isEmpty)
    }

    // MARK: 管道组合

    func testPipelineAggregatesAcrossLayers() throws {
        // 同时触发：空陈述（schema error）+ 未知引用（binding error）+ 无证据（warning）。
        let notes = try makeNotes(claims: [
            ResearchClaim(
                statement: "", evidenceReferences: [EvidenceID(rawValue: "EV-X")],
                confidenceLabel: .high, dimension: .momentum, direction: .bullish
            ),
            ResearchClaim(
                statement: "ok", evidenceReferences: [],
                confidenceLabel: .low, dimension: .value, direction: nil
            ),
        ])
        let result = ResearchValidationPipeline().validate(notes, now: now, knownEvidence: [])
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.errors.count, 2, "empty_statement + unresolved_evidence_reference")
        XCTAssertEqual(result.warnings.count, 1, "missing_evidence（claim 1 无引用）")
        XCTAssertEqual(Set(result.errors.map(\.validator)), [.schema, .evidenceBinding])
    }
}
