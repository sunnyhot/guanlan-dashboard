import XCTest
@testable import QiemanDashboard

// RES-8：Evidence Matcher——ID 引用拦截 + 内容匹配重绑定（确定性）。

final class EvidenceMatcherTests: XCTestCase {

    // MARK: 相似度

    func testSimilarityExtremesAndDeterminism() {
        let matcher = EvidenceMatcher()
        XCTAssertEqual(matcher.similarity("茅台Q2营收450亿", "茅台Q2营收450亿"), 1.0)
        XCTAssertEqual(matcher.similarity("茅台Q2营收450亿", "完全无关的句子"), 0.0, accuracy: 0.15)
        let mid = matcher.similarity("动量策略近期占优", "动量策略持续占优")
        XCTAssertGreaterThan(mid, 0.3)
        XCTAssertLessThan(mid, 1.0)
        // 空与单字符无 bigram
        XCTAssertEqual(matcher.similarity("", "anything"), 0)
        XCTAssertEqual(matcher.similarity("a", "a"), 0)
        // 跨语言/大小写规范化
        XCTAssertEqual(matcher.similarity("Apple Revenue", "apple revenue"), 1.0)
        // 确定性
        XCTAssertEqual(
            matcher.similarity("动量策略近期占优", "动量策略持续占优"),
            matcher.similarity("动量策略近期占优", "动量策略持续占优")
        )
    }

    // MARK: 内容匹配

    func testMatchSelectsMostSimilarEvidenceAndCapsTopN() {
        var matcher = EvidenceMatcher()
        matcher.config.maxMatchesPerClaim = 2
        let corpus = [
            EvidenceID(rawValue: "EV-A"): "基金季报披露前十大持仓变化",
            EvidenceID(rawValue: "EV-B"): "基金季报披露前十大重仓股调整",
            EvidenceID(rawValue: "EV-C"): "美联储议息会议纪要公布",
        ]
        let outcome = matcher.match(
            claims: ["基金季报披露的前十大重仓股有什么变化"],
            corpus: corpus
        )
        XCTAssertEqual(outcome.count, 1)
        let top = outcome[0].matched
        XCTAssertEqual(top.count, 2, "topN 截断")
        XCTAssertTrue(top.contains(EvidenceID(rawValue: "EV-A")))
        XCTAssertTrue(top.contains(EvidenceID(rawValue: "EV-B")))
        XCTAssertFalse(top.contains(EvidenceID(rawValue: "EV-C")), "无关证据不匹配")
        XCTAssertNil(outcome[0].unmatchedReason)
        // 最相似的排第一（query 含「重仓股」，与 EV-B 重叠更大）
        XCTAssertEqual(top.first, EvidenceID(rawValue: "EV-B"))
    }

    func testMatchBelowThresholdReportsUnmatched() {
        var matcher = EvidenceMatcher()
        matcher.config.similarityThreshold = 0.99
        let corpus = [EvidenceID(rawValue: "EV-A"): "基金季报披露前十大持仓变化"]
        let outcome = matcher.match(claims: ["基金季报持仓"], corpus: corpus)
        XCTAssertTrue(outcome[0].matched.isEmpty)
        XCTAssertEqual(outcome[0].unmatchedReason, .noCandidateAboveThreshold)

        // 空证据集 → emptyCorpus
        let empty = EvidenceMatcher().match(claims: ["x"], corpus: [:])
        XCTAssertEqual(empty[0].unmatchedReason, .emptyCorpus)
    }

    func testEqualScoresBreakTieByIDForDeterminism() {
        let corpus = [
            EvidenceID(rawValue: "EV-2"): "相同内容",
            EvidenceID(rawValue: "EV-1"): "相同内容",
        ]
        let outcome = EvidenceMatcher().match(claims: ["相同内容"], corpus: corpus)
        XCTAssertEqual(outcome[0].matched.first, EvidenceID(rawValue: "EV-1"), "同分按 ID 序")
        // 重复调用同结果
        let again = EvidenceMatcher().match(claims: ["相同内容"], corpus: corpus)
        XCTAssertEqual(outcome, again)
    }

    // MARK: ID 引用拦截（M8 验收）

    func testUnresolvedReferencesInterceptForgedIDs() {
        let forged = [
            EvidenceID(rawValue: "EV-1"),
            EvidenceID(rawValue: "EV-FORGED"),
            EvidenceID(rawValue: "web:tavily:madeup123"),
        ]
        let corpus: Set<String> = ["EV-1", "EV-2"]
        let unresolved = EvidenceMatcher.unresolvedReferences(forged, corpus: corpus)
        XCTAssertEqual(unresolved.map(\.rawValue), ["EV-FORGED", "web:tavily:madeup123"])
        // 全部可解析时返回空
        XCTAssertTrue(EvidenceMatcher.unresolvedReferences(
            [EvidenceID(rawValue: "EV-1"), EvidenceID(rawValue: "EV-2")], corpus: corpus
        ).isEmpty)
    }

    // MARK: 重绑定

    func testRebindFillsEmptyReferencesOnly() throws {
        let matcher = EvidenceMatcher()
        let corpus = [
            EvidenceID(rawValue: "EV-NAV"): "基金净值连续三日回升",
            EvidenceID(rawValue: "EV-IRRELEVANT"): "美联储议息会议纪要公布",
        ]
        let notes = try ResearchNotes(
            task: ResearchTask(
                subject: try CanonicalRef(entityType: "fundShareClass", entityIDRawValue: "sc_513100"),
                objective: "test"
            ),
            notes: "n",
            claims: [
                // 空引用：会被补绑
                ResearchClaim(
                    statement: "基金净值连续三日回升", evidenceReferences: [],
                    confidenceLabel: .medium, dimension: .momentum, direction: .bullish
                ),
                // 已有引用：原样保留（matcher 不越权改写）
                ResearchClaim(
                    statement: "其他事实", evidenceReferences: [EvidenceID(rawValue: "EV-KEPT")],
                    confidenceLabel: .high, dimension: .value, direction: nil
                ),
                // 内容不匹配：保持空引用（上层按 missing_evidence 语义处理）
                ResearchClaim(
                    statement: "完全无关的陈述内容", evidenceReferences: [],
                    confidenceLabel: .low, dimension: .sentiment, direction: nil
                ),
            ],
            producedBy: ModelProviderDescriptor(providerID: "p", model: "m", fingerprint: "f"),
            producedAt: Date(timeIntervalSince1970: 1000)
        )
        let rebound = matcher.rebind(notes, corpus: corpus)
        XCTAssertEqual(rebound.claims[0].evidenceReferences, [EvidenceID(rawValue: "EV-NAV")], "空引用经内容匹配补绑")
        XCTAssertEqual(rebound.claims[1].evidenceReferences, [EvidenceID(rawValue: "EV-KEPT")], "已有引用不动")
        XCTAssertTrue(rebound.claims[2].evidenceReferences.isEmpty, "不匹配的保持空")
        // 其他字段不变
        XCTAssertEqual(rebound.claims[0].statement, notes.claims[0].statement)
        XCTAssertEqual(rebound.claims[0].direction, .bullish)

        // 空证据集原样返回
        let untouched = matcher.rebind(notes, corpus: [:])
        XCTAssertEqual(untouched, notes)
    }

    func testReboundNotesPassEvidenceBinding() throws {
        // rebind 之后的 notes 在 RES-5 管道中应能过绑定层（knownEvidence = corpus keys）。
        let corpus = [EvidenceID(rawValue: "EV-NAV"): "基金净值连续三日回升"]
        let notes = try ResearchNotes(
            task: ResearchTask(
                subject: try CanonicalRef(entityType: "fundShareClass", entityIDRawValue: "sc_513100"),
                objective: "test"
            ),
            notes: "n",
            claims: [
                ResearchClaim(
                    statement: "基金净值连续三日回升", evidenceReferences: [],
                    confidenceLabel: .medium, dimension: .momentum, direction: .bullish
                )
            ],
            producedBy: ModelProviderDescriptor(providerID: "p", model: "m", fingerprint: "f"),
            producedAt: Date()
        )
        let rebound = EvidenceMatcher().rebind(notes, corpus: corpus)
        let result = ResearchValidationPipeline().validate(
            rebound, now: Date(), knownEvidence: Set(corpus.keys.map(\.rawValue))
        )
        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.warnings.isEmpty, "补绑后不再有 missing_evidence warning")
    }
}
